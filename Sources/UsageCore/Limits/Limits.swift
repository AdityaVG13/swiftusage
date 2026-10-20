import Foundation

/// One plan limit: how much of a window is used and when it resets.
public struct LimitMeter: Codable, Sendable, Equatable, Identifiable {
    public enum Unit: String, Codable, Sendable {
        case percent, dollars
        /// Requests or messages, counted against an allowance.
        case count
    }

    /// Stable within an account (`session`, `weekly`, `model-fable`), so the menu bar can pin it.
    public var id: String
    public var label: String
    public var used: Double
    public var limit: Double
    public var unit: Unit
    public var resetsAt: Date?
    /// The window's length, for working out the pace. Nil for limits that don't reset on a schedule.
    public var period: TimeInterval?

    public init(id: String, label: String, used: Double, limit: Double = 100, unit: Unit = .percent, resetsAt: Date? = nil, period: TimeInterval? = nil) {
        self.id = id
        self.label = label
        self.used = used
        self.limit = limit
        self.unit = unit
        self.resetsAt = resetsAt
        self.period = period
    }

    public static func percent(_ id: String, _ label: String, used: Double, resetsAt: Date?, period: TimeInterval?) -> LimitMeter {
        LimitMeter(id: id, label: label, used: min(max(used, 0), 100), resetsAt: resetsAt, period: period)
    }

    /// Used share of the limit, 0...1.
    public var fraction: Double { limit > 0 ? min(max(used / limit, 0), 1) : 0 }
}

/// A figure without a limit: a balance, credits left, a setting like pay-as-you-go.
public struct LimitNote: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// The limit resets an account holds: refills of its limits that Codex and Claude hand out now and then,
/// which the card can use.
public struct LimitResets: Codable, Sendable, Equatable {
    public var available: Int
    /// When the first of them lapses. Nil when none do.
    public var nextExpiry: Date?
    /// The meters one refills (`session`, `weekly`).
    public var refills: [String]
    /// Whether the app can use one. Claude's need a grant Anthropic names as the next to use.
    public var usable: Bool

    public init(available: Int, nextExpiry: Date? = nil, refills: [String] = [], usable: Bool = true) {
        self.available = available
        self.nextExpiry = nextExpiry
        self.refills = refills
        self.usable = usable
    }
}

/// Something the person can do about an account's `problem` from its card.
public enum LimitAction: String, Codable, Sendable {
    /// Let the app read the login Claude Desktop keeps, which macOS asks about once.
    case allowClaudeDesktop
}

/// One signed-in account's plan and limits, as its provider last reported them.
public struct AccountLimits: Codable, Sendable, Equatable, Identifiable {
    /// Stable for the login (`claude:<account>|<org>`), so values carry across launches.
    public var id: String
    public var provider: Provider
    /// Which login this is when a provider has several (`Tasteskill`, an email address).
    public var account: String?
    public var plan: String?
    public var meters: [LimitMeter]
    public var notes: [LimitNote]
    public var resets: LimitResets?
    /// Why the limits couldn't be read, worded as what to do about it.
    public var problem: String?
    public var action: LimitAction?
    /// Other tools signed in to the same account, such as Pi using a Claude subscription.
    public var sharedWith: [Provider] = []
    /// When `meters` and `notes` were read.
    public var updated: Date

    public init(id: String, provider: Provider, account: String? = nil, plan: String? = nil, meters: [LimitMeter] = [],
                notes: [LimitNote] = [], problem: String? = nil, action: LimitAction? = nil, updated: Date = Date()) {
        self.id = id
        self.provider = provider
        self.account = account
        self.plan = plan
        self.meters = meters
        self.notes = notes
        self.problem = problem
        self.action = action
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, account, plan, meters, notes, resets, problem, action, sharedWith, updated
    }

    // Saved before `sharedWith` and `resets` existed, readings still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(Provider.self, forKey: .provider)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        meters = try container.decode([LimitMeter].self, forKey: .meters)
        notes = try container.decode([LimitNote].self, forKey: .notes)
        resets = try container.decodeIfPresent(LimitResets.self, forKey: .resets)
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        action = try container.decodeIfPresent(LimitAction.self, forKey: .action)
        sharedWith = try container.decodeIfPresent([Provider].self, forKey: .sharedWith) ?? []
        updated = try container.decode(Date.self, forKey: .updated)
    }

    /// Whether the account belongs under `provider` in the picker: its own, or a tool that shares it.
    public func isUsed(by provider: Provider) -> Bool {
        self.provider == provider || sharedWith.contains(provider)
    }

    static func failed(_ id: String, _ provider: Provider, account: String? = nil, plan: String? = nil, _ problem: String) -> AccountLimits {
        AccountLimits(id: id, provider: provider, account: account, plan: plan, problem: problem)
    }

    public var hasValues: Bool { !meters.isEmpty || !notes.isEmpty || resets != nil }

    /// This reading, or when it failed, the last good one's values with this one's problem. Windows that
    /// have reset since read as unused.
    public func keepingValues(of previous: AccountLimits?, now: Date = Date()) -> AccountLimits {
        guard problem != nil, !hasValues, let previous, previous.hasValues else { return self }
        var kept = previous
        kept.problem = problem
        kept.action = action
        kept.sharedWith = sharedWith
        kept.plan = plan ?? previous.plan
        kept.meters = previous.meters.map { meter in
            guard let reset = meter.resetsAt, reset <= now else { return meter }
            var meter = meter
            meter.used = 0
            // A daily or weekly window rolls straight into the next one; a five-hour session only starts
            // with the next message.
            if let period = meter.period, period >= 86_400 {
                let missed = (now.timeIntervalSince(reset) / period).rounded(.down) + 1
                meter.resetsAt = reset.addingTimeInterval(period * missed)
            } else {
                meter.resetsAt = nil
            }
            return meter
        }
        return kept
    }
}

/// Where one provider's plan limits come from: the provider's own usage API, signed in with the login its
/// tool already keeps on this Mac. Logins are only read, never refreshed or changed, so the tools keep
/// working exactly as before.
public protocol LimitsSource: Sendable {
    var provider: Provider { get }
    /// Every signed-in account's limits. A provider with no login on this Mac returns none; one whose login
    /// can't be used returns its accounts with a `problem`.
    func fetch() async -> [AccountLimits]
}

public enum LimitsSources {
    /// In the provider picker's order. Pi comes after the tools whose logins it may share, so their cards win.
    public static func all() -> [any LimitsSource] {
        [CodexLimits(), ClaudeLimits(), CursorLimits(), GrokLimits(), OpenCodeLimits(), AntigravityLimits(), PiLimits(), DevinLimits()]
    }

    /// Every source's accounts, read side by side, in the provider picker's order. An account several
    /// tools are signed in to is one card, under the first source to find it.
    public static func fetch(_ sources: [any LimitsSource]) async -> [AccountLimits] {
        let found = await withTaskGroup(of: (Int, [AccountLimits]).self) { group in
            for (index, source) in sources.enumerated() { group.addTask { (index, await source.fetch()) } }
            var found: [Int: [AccountLimits]] = [:]
            for await (index, accounts) in group { found[index] = accounts }
            return found
        }
        return merged(sources.indices.flatMap { found[$0] ?? [] })
            .sorted { ($0.provider.order, $0.account ?? "") < ($1.provider.order, $1.account ?? "") }
    }

    /// One card per account id: the first reading wins, unless only a later one could be read.
    static func merged(_ accounts: [AccountLimits]) -> [AccountLimits] {
        var result: [AccountLimits] = []
        var positions: [String: Int] = [:]
        for account in accounts {
            guard let position = positions[account.id] else {
                positions[account.id] = result.count
                result.append(account)
                continue
            }
            var kept = result[position]
            if !kept.hasValues, account.hasValues {
                // The card stays where it is and keeps its name, with the readings that worked.
                let (provider, name, shared) = (kept.provider, kept.account, kept.sharedWith)
                kept = account
                kept.provider = provider
                kept.account = name ?? account.account
                kept.sharedWith = shared
            }
            if account.provider != kept.provider, !kept.sharedWith.contains(account.provider) {
                kept.sharedWith.append(account.provider)
            }
            result[position] = kept
        }
        return result
    }
}
