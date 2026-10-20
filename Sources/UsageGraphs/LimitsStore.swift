import AppKit
import Observation
import SwiftUI
import UsageCore

/// Every signed-in account's plan limits, read from the providers every five minutes and when the panel
/// opens. The last good reading is saved, so limits show at once after a relaunch, and kept when a
/// later reading fails.
@MainActor
@Observable
final class LimitsStore {
    /// In the provider picker's order, then by account.
    private(set) var accounts: [AccountLimits] = []
    private(set) var isLoading = false
    private(set) var lastFetched: Date?
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
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// An account shows under its own provider and any tool that shares it.
    func accounts(for provider: Provider?) -> [AccountLimits] {
        accounts.filter { (provider.map($0.isUsed(by:)) ?? true) && isShown($0) }
    }

    /// Every account of the providers that are on, including ones turned off, for Customize.
    var followedAccounts: [AccountLimits] {
        accounts.filter { preferences.isShown($0.provider) }
    }

    func isShown(_ account: AccountLimits) -> Bool {
        !hidden.contains(account.id) && preferences.isShown(account.provider)
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
    func perform(_ action: LimitAction) async {
        switch action {
        case .allowClaudeDesktop:
            // Shows macOS's keychain prompt and waits for the answer, so it runs off the main thread.
            _ = await Task.detached { ClaudeDesktop.requestAccess() }.value
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

    private static func name(_ account: AccountLimits) -> String {
        account.provider.rawValue + "|" + (account.account ?? "")
    }

    static func pin(_ account: AccountLimits, _ meter: LimitMeter) -> String {
        account.id + "/" + meter.id
    }

    /// Reads every provider again, unless that happened within the last minute and `force` isn't set.
    func refresh(force: Bool = false) async {
        if let running = inFlight {
            await running.value
            // A reading under way may have begun before what made the caller ask, such as a reset just used.
            guard force else { return }
            if let next = inFlight, next != running { return await next.value }
        }
        if !force, let lastFetched, Date().timeIntervalSince(lastFetched) < 60 { return }
        let task = Task { await fetch() }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private func fetch() async {
        isLoading = true
        let shown = Set(preferences.shownProviders)
        asked = shown
        let fresh = await LimitsSources.fetch(sources.filter { shown.contains($0.provider) })
        let previous = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let found = Set(fresh.map(\.id))
        // Accounts of providers that are off weren't asked for; they wait as they were, out of sight.
        let resting = accounts.filter { !found.contains($0.id) && !shown.contains($0.provider) }
        // A login that can't be found this time (a file mid-write, a locked database) keeps its card for a
        // day before it's taken as signed out. One whose account turned up under a new ID, after an update
        // changed how logins are told apart, is that account and goes at once.
        let names = Set(fresh.map(Self.name))
        let missing = accounts.filter {
            !found.contains($0.id) && shown.contains($0.provider) && !names.contains(Self.name($0))
                && $0.hasValues && Date().timeIntervalSince($0.updated) < 86_400
        }.map { account in
            var account = account
            account.problem = "Couldn't find this login. Sign in again if you signed out."
            return account
        }
        let merged = (fresh.map { $0.keepingValues(of: previous[$0.id]) } + missing + resting)
            .sorted { ($0.provider.order, $0.account ?? "") < ($1.provider.order, $1.account ?? "") }
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
