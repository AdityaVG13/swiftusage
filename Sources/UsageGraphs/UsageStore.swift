import AppKit
import Observation
import SwiftUI
import UsageCore

@MainActor
@Observable
final class UsageStore {
    /// Stats for each provider, and for all of them together under `nil`.
    private(set) var stats: [Provider?: [StatsRange: RangeStats]] = [:]
    /// Providers with any history on this Mac.
    private(set) var providersWithData: Set<Provider> = []
    private(set) var hasLoaded = false
    /// Set only while a scan has a meaningful amount of history left to read.
    private(set) var progress: ScanProgress?
    private(set) var lastUpdated: Date?
    /// Changes each time the panel closes, so the next opening shows another book comparison without
    /// the caption changing as the panel animates in.
    private(set) var comparisonIndex = 0
    /// Codex compresses older rollouts with zstd, which macOS can't read without Homebrew's `zstd`.
    private(set) var codexNeedsZstd = false

    @ObservationIgnored private let sources = UsageSources.all()
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var data: [Provider: UsageData] = [:]
    @ObservationIgnored private var scanProgress: [Provider: ScanProgress] = [:]
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activeScans = 0
    @ObservationIgnored private var prices = PriceList.bundled
    /// Counts stats builds, so one that finishes after a newer one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var applyGeneration = 0
    /// The local day the stats were last built on; they're rebuilt on a new day even if no history changed.
    @ObservationIgnored private var statsDay: Int?

    init(preferences: Preferences) {
        self.preferences = preferences
        comparisonIndex = Int.random(in: 0..<1000)
        Task {
            prices = await PriceUpdates.shared.current()
            await refresh()
            await updatePrices()
        }
        checkZstd()

        let watched: [(provider: Provider, path: String)] = sources.flatMap { source in source.watchedPaths.map { (source.provider, $0) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        watcher = DirectoryWatcher(paths: watched.map { $0.path }) { [weak self] changed in
            let providers = Set(watched.filter { entry in changed.contains { $0.hasPrefix(entry.path) } }.map { $0.provider })
            Task { @MainActor in await self?.refresh(providers) }
        }
        watcher?.start()

        // Catches day rollover, newly installed tools and anything FSEvents coalesced away.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkZstd()
                await self?.refresh()
                await self?.updatePrices()
            }
        }
        timer?.tolerance = 30

        // Quit, logout and shutdown all pass through here; give the indexes a moment to reach disk.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [sources] _ in
            let saved = DispatchSemaphore(value: 0)
            Task.detached {
                for source in sources { await source.save() }
                saved.signal()
            }
            _ = saved.wait(timeout: .now() + 2)
        }
    }

    var todayTokens: Int64 {
        guard let week = stats[nil]?[.days7] else { return 0 }
        return week.days[week.today]?.tokens ?? 0
    }

    /// Dollars at API rates today, yesterday and over the last 30 days, for one provider or all of them.
    func spend(for provider: Provider?) -> (today: Double, yesterday: Double, month: Double)? {
        guard let week = stats[provider]?[.days7], let month = stats[provider]?[.days30] else { return nil }
        return (week.days[week.today]?.cost ?? 0, week.days[week.today - 1]?.cost ?? 0, month.cost)
    }

    /// LiteLLM's price list is fetched once a day; new prices recount every provider's cost.
    private func updatePrices() async {
        guard let updated = await PriceUpdates.shared.refreshIfStale() else { return }
        prices = updated
        await apply()
    }

    /// Where a provider keeps its history, if that folder exists.
    func folder(for provider: Provider) -> URL? {
        sources.first { $0.provider == provider }?.watchedPaths
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Refreshes once the panel has settled, so new numbers never land mid-animation.
    func panelOpened() {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
        }
    }

    func panelClosed() {
        comparisonIndex += 1
    }

    /// Totals follow the providers that are on at once; one turned on is then read.
    func providersChanged() async {
        await apply()
        await refresh()
    }

    /// Re-reads the given providers' sources (all of them by default). Providers that are off aren't read.
    func refresh(_ providers: Set<Provider>? = nil) async {
        await scan(providers) { source, progress in await source.refresh(progress: progress) }
    }

    func rebuild() async {
        checkZstd()
        await scan(nil) { source, progress in await source.rebuild(progress: progress) }
    }

    /// Whether to suggest installing zstd, which is checked again until there's no need.
    private func checkZstd() {
        Task.detached(priority: .utility) {
            let needsZstd = UsageSources.codexHasUnreadableRollouts()
            await MainActor.run { if self.codexNeedsZstd != needsZstd { self.codexNeedsZstd = needsZstd } }
        }
    }

    private func scan(_ providers: Set<Provider>?, _ read: @escaping @Sendable (any UsageSource, (@Sendable (ScanProgress) -> Void)?) async -> UsageData) async {
        let chosen = sources.filter { (providers?.contains($0.provider) ?? true) && preferences.isShown($0.provider) }
        if chosen.isEmpty { return }
        activeScans += 1
        // Agents write to their history every few seconds while they run, and most of those reads add
        // nothing the stats show; only a read that changed some provider's history rebuilds them.
        var changed = false
        let previous = data
        await withTaskGroup(of: (Provider, UsageData, Bool).self) { group in
            for source in chosen {
                let handler = progressHandler(for: source.provider)
                let before = previous[source.provider]
                group.addTask {
                    let result = await read(source, handler)
                    return (source.provider, result, before.map { !$0.sameHistory(as: result) } ?? true)
                }
            }
            for await (provider, result, providerChanged) in group {
                data[provider] = result
                if providerChanged { changed = true }
            }
        }
        activeScans -= 1
        await apply(rebuildingStats: changed)
    }

    private func progressHandler(for provider: Provider) -> @Sendable (ScanProgress) -> Void {
        // Sources report every file; the bar only needs to move a few times a frame's worth.
        let throttle = Throttle(interval: 1.0 / 15)
        return { [weak self] progress in
            guard progress.filesDone == 0 || progress.filesDone == progress.filesTotal || throttle.allow() else { return }
            Task { @MainActor in
                guard let self, self.activeScans > 0 else { return }
                self.scanProgress[provider] = progress.filesDone < progress.filesTotal ? progress : nil
                let pending = Array(self.scanProgress.values)
                let total = ScanProgress(bytesRead: pending.reduce(0) { $0 + $1.bytesRead }, bytesTotal: pending.reduce(0) { $0 + $1.bytesTotal },
                                         filesDone: pending.reduce(0) { $0 + $1.filesDone }, filesTotal: pending.reduce(0) { $0 + $1.filesTotal })
                self.progress = total.bytesTotal > 64 << 20 ? total : nil
            }
        }
    }

    private func apply(rebuildingStats: Bool = true) async {
        applyGeneration += 1
        let applyID = applyGeneration
        let snapshot = data
        let today = DayClock().day(of: Date().timeIntervalSince1970)
        if rebuildingStats || today != statsDay {
            statsDay = today
            await buildStats(snapshot)
            guard applyID == applyGeneration else { return }
        }
        let withData = Set(snapshot.filter { !$0.value.isEmpty }.map(\.key))
        if withData != providersWithData { providersWithData = withData }
        if !hasLoaded { hasLoaded = true }
        if activeScans == 0 {
            if progress != nil { progress = nil }
            scanProgress = [:]
        }
        lastUpdated = snapshot.values.map(\.scannedAt).max()
    }

    private func buildStats(_ snapshot: [Provider: UsageData]) async {
        let shown = Set(preferences.shownProviders)
        let current = stats
        let prices = prices
        generation += 1
        let build = generation
        // Built and compared off the main thread; unchanged numbers don't touch the views at all.
        let built: [Provider?: [StatsRange: RangeStats]]? = await Task.detached(priority: .userInitiated) {
            let now = Date()
            let clock = DayClock()
            // "All" is the providers that are on, and those are the only ones shown on their own too.
            let parts = snapshot.filter { shown.contains($0.key) }
            var all: [Provider?: UsageData] = [nil: UsageData.merged(Array(parts.values))]
            for (provider, data) in parts { all[provider] = data }
            var result: [Provider?: [StatsRange: RangeStats]] = [:]
            for (provider, data) in all {
                for range in StatsRange.allCases {
                    result[provider, default: [:]][range] = StatsBuilder.build(data, range: range, now: now, clock: clock, prices: prices)
                }
            }
            return result == current ? nil : result
        }.value
        if let built, build == generation {
            withAnimation(Theme.Motion.data) { stats = built }
        }
    }
}

/// Lets a call through at most once per interval, from any thread.
private final class Throttle: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var last: TimeInterval = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func allow() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}
