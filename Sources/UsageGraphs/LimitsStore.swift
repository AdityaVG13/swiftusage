import AppKit
import Observation
import SwiftUI
import UsageCore

/// Every signed-in account's plan limits, read from the providers as often as Customize says (every five
/// minutes unless changed) and when the panel opens. The last good reading is saved, so limits show at
/// once after a relaunch, and kept when a later reading fails.
@MainActor
@Observable
final class LimitsStore {
    /// In the provider picker's order, then by account.
    private(set) var accounts: [AccountLimits] = []
    private(set) var isLoading = false
    private(set) var lastFetched: Date?
    /// When the timed reading is due.
    private(set) var nextReading: Date?
    /// Providers read at least once since the app started.
    private(set) var readProviders: Set<Provider> = []
    /// Limit resets being used, and what came of the last use, by account.
    private(set) var resetUses: [String: ResetUse] = [:]
    /// Meters shown in the menu bar, as `account id/meter id`.
    var pins: [String] {
        didSet { UserDefaults.standard.set(pins, forKey: "menuBarPins") }
    }
    /// Accounts the person turned off in Customize or hid from their card: out of the Limits tab and the
    /// menu bar, still read so Customize can turn them back on.
    var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden).sorted(), forKey: "hiddenLimits") }
    }

    @ObservationIgnored private let sources = LimitsSources.all()
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// The providers the last reading asked.
    @ObservationIgnored private var asked: Set<Provider> = []
    /// Readings in a row that reached no provider at all.
    @ObservationIgnored private var unanswered = 0
    /// When each account the readings stopped finding was first missed.
    @ObservationIgnored private var missingSince: [String: Date] = [:]
    @ObservationIgnored private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.tasteskill.UsageGraphs/limits.json")

    init(preferences: Preferences) {
        self.preferences = preferences
        pins = UserDefaults.standard.stringArray(forKey: "menuBarPins") ?? []
        hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenLimits") ?? [])
        if let data = try? Data(contentsOf: cacheURL), let saved = try? Self.decoder.decode([AccountLimits].self, from: data) {
            accounts = saved
        }
        Task { await refresh() }
        followInterval()
        // However a timer counted the time asleep, the next reading is worked out again from the clock, a
        // few seconds after waking so the network is back.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self?.schedule()
            }
        }
    }

    /// Arms the next timed reading, and again each time what it's set from changes: the interval chosen in
    /// Customize, when the last reading was made, and when the windows on show reset.
    private func followInterval() {
        withObservationTracking {
            schedule()
        } onChange: { [weak self] in
            // After the change has landed; observation reports it as it's about to happen.
            Task { @MainActor in self?.followInterval() }
        }
    }

    /// The next timed reading: one interval after the last reading of any kind, so a reading the panel's
    /// opening set off pushes the timed one back rather than doubling it, or just after a window on show
    /// resets. It's armed again once it has run, whatever the reading decided.
    private func schedule() {
        timer?.invalidate()
        let interval = preferences.limitsInterval
        let resets = accounts.filter(isShown).flatMap(\.meters).compactMap(\.resetsAt)
        let next = LimitsTimer.next(after: lastFetched, interval: interval, resets: resets, unanswered: unanswered)
        nextReading = next.at
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next.at.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(force: next.forReset)
                self?.schedule()
            }
        }
        timer?.tolerance = next.forReset ? 5 : min(30, interval / 10)
    }

    /// An account shows under its own provider and any tool that shares it.
    func accounts(for provider: Provider?) -> [AccountLimits] {
        accounts.filter { (provider.map($0.isUsed(by:)) ?? true) && isShown($0) }
    }

    /// The providers on that have limits to ask for, in the picker's order.
    var providersWithLimits: [Provider] {
        preferences.shownProviders.filter { provider in sources.contains { $0.provider == provider } }
    }

    /// Every account of the providers that are on, including ones turned off, for Customize.
    var followedAccounts: [AccountLimits] {
        accounts.filter(isFollowed)
    }

    /// Whether the person hid any of `provider`'s accounts (or any account, for nil) in Customize.
    func hasHiddenAccounts(for provider: Provider?) -> Bool {
        followedAccounts.contains { (provider.map($0.isUsed(by:)) ?? true) && hidden.contains($0.id) }
    }

    /// Whether a provider using the account is on: its own, or another tool signed in to it too, whose
    /// reading takes the card over at the next reading anyway.
    private func isFollowed(_ account: AccountLimits) -> Bool {
        ([account.provider] + account.sharedWith).contains(where: preferences.isShown)
    }

    func isShown(_ account: AccountLimits) -> Bool {
        !hidden.contains(account.id) && isFollowed(account)
    }

    func setShown(_ account: AccountLimits, _ shown: Bool) {
        if shown { hidden.remove(account.id) } else { hidden.insert(account.id) }
    }

    /// Reads a provider that was just turned on, after any reading already under way. Turning one off
    /// only hides its accounts.
    func providersChanged() async {
        if let inFlight { await inFlight.value }
        if !Set(preferences.shownProviders).isSubset(of: asked) { await refresh(force: true) }
    }

    /// Does what an account's card offers, then reads the limits again.
    func perform(_ action: LimitAction, for account: AccountLimits) async {
        // Each shows macOS's keychain prompt and waits for the answer, so it runs off the main thread.
        switch action {
        case .allowClaudeDesktop:
            _ = await Task.detached { ClaudeDesktop.requestAccess() }.value
        case .allowKeychain:
            let id = account.id
            _ = await Task.detached { Keychain.requestAccess(for: id) }.value
        }
        await refresh(force: true)
    }

    enum ResetUse: Equatable {
        case using
        case done(ResetOutcome)
    }

    /// Uses one of the account's limit resets, then reads the limits again so the card shows what changed.
    /// What came of it shows for a minute.
    func useReset(_ account: AccountLimits) async {
        guard resetUses[account.id] != .using else { return }
        resetUses[account.id] = .using
        let outcome = await ResetClaims.shared.use(account.id)
        await refresh(force: true)
        resetUses[account.id] = .done(outcome)
        try? await Task.sleep(for: .seconds(60))
        if resetUses[account.id] == .done(outcome) { resetUses[account.id] = nil }
    }

    func dismissResetUse(_ account: AccountLimits) {
        resetUses[account.id] = nil
    }

    func isPinned(_ account: AccountLimits, _ meter: LimitMeter) -> Bool {
        pins.contains(Self.pin(account, meter))
    }

    func togglePin(_ account: AccountLimits, _ meter: LimitMeter) {
        let pin = Self.pin(account, meter)
        if let index = pins.firstIndex(of: pin) {
            pins.remove(at: index)
        } else {
            pins.append(pin)
        }
    }

    /// Puts the menu bar's accounts in this order, each keeping its own limits in theirs. Pins of accounts
    /// out of sight keep their places.
    func orderPins(byAccount order: [String]) {
        let owners = Dictionary(pinned.map { (Self.pin($0.account, $0.meter), $0.account.id) }, uniquingKeysWith: { first, _ in first })
        let slots = pins.indices.filter { owners[pins[$0]] != nil }
        let moved = order.flatMap { id in slots.map { pins[$0] }.filter { owners[$0] == id } }
        guard moved.count == slots.count else { return }
        var reordered = pins
        for (slot, pin) in zip(slots, moved) { reordered[slot] = pin }
        pins = reordered
    }

    /// Pinned meters of the accounts on show, in the menu bar's order.
    var pinned: [(account: AccountLimits, meter: LimitMeter)] {
        let shown = accounts.filter(isShown)
        return pins.compactMap { pin in
            for account in shown {
                if let meter = account.meters.first(where: { Self.pin(account, $0) == pin }) { return (account, meter) }
            }
            return nil
        }
    }

    static func pin(_ account: AccountLimits, _ meter: LimitMeter) -> String {
        account.id + "/" + meter.id
    }

    /// Reads every provider again, unless that happened within the last minute (or half the interval, when
    /// that's shorter) and `force` isn't set.
    func refresh(force: Bool = false) async {
        if let running = inFlight {
            await running.value
            // A reading under way may have begun before what made the caller ask, such as a reset just used.
            guard force else { return }
            if let next = inFlight, next != running { return await next.value }
        }
        if !force, let lastFetched, Date().timeIntervalSince(lastFetched) < min(60, preferences.limitsInterval / 2) { return }
        let task = Task { await fetch() }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private func fetch() async {
        isLoading = true
        let shown = Set(preferences.shownProviders)
        asked = shown
        let started = Date()
        let fresh = await LimitsSources.fetch(sources.filter { shown.contains($0.provider) })
        unanswered = LimitsSources.reachedNothing(since: started) ? unanswered + 1 : 0
        let merged = LimitsSources.update(accounts, with: fresh, asked: shown, missingSince: &missingSince)
        if merged != accounts {
            withAnimation(Theme.Motion.data) { accounts = merged }
        }
        // Until the person picks their own, the menu bar shows what OpenUsage shows by default: each Claude
        // account's session and weekly limits.
        if UserDefaults.standard.object(forKey: "menuBarPins") == nil {
            let defaults = merged.filter { $0.provider == .claude }.flatMap { account in
                account.meters.filter { ["session", "weekly"].contains($0.id) }.map { Self.pin(account, $0) }
            }
            if !defaults.isEmpty { pins = defaults }
        }
        lastFetched = Date()
        readProviders.formUnion(shown)
        isLoading = false
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(accounts).write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("swiftusage: could not save limits: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
