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

    @ObservationIgnored private let sources = UsageSources.all()
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var data: [Provider: UsageData] = [:]
    @ObservationIgnored private var scanProgress: [Provider: ScanProgress] = [:]
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedPaths: [String] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activeScans = 0
    @ObservationIgnored private var prices = PriceList.bundled
    /// Counts stats builds, so one that finishes after a newer one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var applyGeneration = 0
    /// The local day and time zone the stats were last built on; they're rebuilt on a new day or zone even if no history changed.
    @ObservationIgnored private var statsDay: Int?
    @ObservationIgnored private var statsTimeZone: String?
    /// Stats are built at a lower priority while nobody is looking at them.
    @ObservationIgnored private var panelIsOpen = false
    /// Providers whose stats a build started on but didn't land, so the build that replaced it rebuilds
    /// them too; nil for all of them.
    @ObservationIgnored private var unbuilt: Set<Provider>? = []

    init(preferences: Preferences) {
        self.preferences = preferences
        comparisonIndex = Int.random(in: 0..<1000)
        Task {
            prices = await PriceUpdates.shared.current()
            await refresh()
            await updatePrices()
        }
        updateWatcher()

        // Catches day rollover, newly installed tools and anything FSEvents coalesced away.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateWatcher()
                await self?.refresh()
                await self?.updatePrices()
            }
        }
        timer?.tolerance = 30

        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            Task { @MainActor in await self?.apply() }
        }

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
        panelIsOpen = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
        }
    }

    func panelClosed() {
        panelIsOpen = false
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
        await scan(nil) { source, progress in await source.rebuild(progress: progress) }
    }

    /// Rebuilds the FSEvents stream when a provider's folder appears or disappears after launch.
    private func updateWatcher() {
        let watched: [(provider: Provider, path: String)] = sources.flatMap { source in source.watchedPaths.map { (source.provider, $0) } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let paths = watched.map(\.path)
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        watcher?.stop()
        watcher = DirectoryWatcher(paths: paths) { [weak self] changed in
            let providers = Set(watched.filter { entry in changed.contains { $0.hasPrefix(entry.path) } }.map(\.provider))
            Task { @MainActor in await self?.refresh(providers) }
        }
        watcher?.start()
    }

    private func scan(_ providers: Set<Provider>?, _ read: @escaping @Sendable (any UsageSource, (@Sendable (ScanProgress) -> Void)?) async -> UsageData) async {
        let chosen = sources.filter { (providers?.contains($0.provider) ?? true) && preferences.isShown($0.provider) }
        if chosen.isEmpty {
            // With every provider off there's nothing to read, but the panel still has to finish loading.
            // Changes in a provider that's off land here too, and those rebuild nothing.
            if !hasLoaded { await apply() }
            return
        }
        activeScans += 1
        // Agents write to their history every few seconds while they run, and most of those reads add
        // nothing the stats show; only a read that changed some provider's history rebuilds them.
        var changed: Set<Provider> = []
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
                if providerChanged { changed.insert(provider) }
            }
        }
        activeScans -= 1
        await apply(rebuilding: changed)
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

    /// Brings the stats up to date with what's been read. `rebuilding` names the providers whose history
    /// changed; nil rebuilds them all, as do a new day and a new time zone.
    private func apply(rebuilding changed: Set<Provider>? = nil) async {
        applyGeneration += 1
        let applyID = applyGeneration
        let snapshot = data
        let clock = DayClock()
        let today = clock.day(of: Date().timeIntervalSince1970)
        let timeZone = clock.timeZone.identifier
        let newDay = today != statsDay || timeZone != statsTimeZone
        if newDay || changed?.isEmpty != true {
            statsDay = today
            statsTimeZone = timeZone
            await buildStats(snapshot, rebuilding: newDay ? nil : changed)
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

    /// Builds the stats of the providers in `changed` (all of them when nil), keeps the rest, and merges
    /// them into "All".
    private func buildStats(_ snapshot: [Provider: UsageData], rebuilding changed: Set<Provider>?) async {
        let changed = changed.flatMap { changed in unbuilt.map { changed.union($0) } }
        unbuilt = changed
        let shown = Set(preferences.shownProviders)
        let current = stats
        let prices = prices
        generation += 1
        let build = generation
        // Built and compared off the main thread; unchanged numbers don't touch the views at all.
        let built: [Provider?: [StatsRange: RangeStats]]? = await Task.detached(priority: panelIsOpen ? .userInitiated : .utility) {
            let now = Date()
            let clock = DayClock()
            // "All" is the providers that are on, and those are the only ones shown on their own too.
            var result: [Provider?: [StatsRange: RangeStats]] = [:]
            for (provider, data) in snapshot where shown.contains(provider) {
                if let changed, !changed.contains(provider), let kept = current[provider] {
                    result[provider] = kept
                    continue
                }
                for range in StatsRange.allCases {
                    result[provider, default: [:]][range] = StatsBuilder.build(data, range: range, now: now, clock: clock, prices: prices)
                }
            }
            let today = clock.day(of: now.timeIntervalSince1970)
            for range in StatsRange.allCases {
                result[nil, default: [:]][range] = RangeStats.merged(Provider.allCases.compactMap { result[$0]?[range] }, range: range, today: today)
            }
            return result == current ? nil : result
        }.value
        guard build == generation else { return }
        unbuilt = []
        if let built {
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
