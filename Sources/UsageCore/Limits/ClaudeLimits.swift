import Foundation

/// Claude's session, weekly and per-model limits, for every Claude Code login on this Mac: the default
/// config folder (`~/.claude`), every folder `$CLAUDE_CONFIG_DIR` has named, and any other `~/.claude*` or
/// `~/.config/claude*` folder used as one, such as `~/.claude_personal` for a second account, then Claude
/// Desktop's login for an account none of them has.
///
/// Claude Code keeps each folder's login in the keychain as `Claude Code-credentials`, with
/// `-<first 8 hex digits of SHA-256(folder)>` appended for folders set through `CLAUDE_CONFIG_DIR`, or in
/// `<folder>/.credentials.json`. The account behind it is in the folder's `.claude.json`.
public struct ClaudeLimits: LimitsSource {
    public let provider = Provider.claude

    public init() {}

    struct Login {
        var folder: URL
        var isDefault: Bool
        var accountID: String
        var account: String?
        /// Nil while the keychain item it's in needs the person's permission: `waitingOn`.
        var token: String?
        var waitingOn: Keychain.Item?
        var expires: Date?
        var scopes: [String]?
        var subscription: String?
        var tier: String?

        /// `account|org`, as Anthropic names them.
        var id: String { "claude:" + accountID }
    }

    public func fetch() async -> [AccountLimits] {
        let logins = Self.logins(remembered: EnvironmentFolders.seen("CLAUDE_CONFIG_DIR"))
        let readings = await LimitsSources.readings(of: logins, id: \.id, read: Self.limits(for:))
        let served = Set(readings.filter(\.hasValues).map(\.id))
        let accounts = Set(logins.filter { served.contains($0.id) }.compactMap { $0.accountID.split(separator: "|").first.map(String.init) })
        return readings + (await ClaudeDesktop.limits(skippingAccounts: accounts, ids: served))
    }

    private static func limits(for login: Login) async -> AccountLimits {
        guard let token = login.token else {
            if let item = login.waitingOn { Keychain.wait(login.id, on: item) }
            return AccountLimits(id: login.id, provider: .claude, account: login.account,
                                 problem: "To see these limits, allow access to Claude Code's login and choose Always Allow.", action: .allowKeychain)
        }
        let renew = login.isDefault ? "Run `claude` to renew it." : "Run Claude Code with this account to renew it."
        let plan = plan(login.subscription, login.tier)
        if let expires = login.expires, expires < Date() {
            return .failed(login.id, .claude, account: login.account, plan: plan, "Login expired. \(renew)")
        }
        if let scopes = login.scopes, !scopes.isEmpty, !scopes.contains("user:profile") {
            return .failed(login.id, .claude, account: login.account, "This login can't read limits. Sign in again with `claude`.")
        }
        return await AnthropicUsage.shared.limits(id: login.id, provider: .claude, account: login.account, token: token, renew: renew, plan: plan)
    }

    // MARK: - Reading the response

    static func meters(_ body: [String: Any]) -> [LimitMeter] {
        var meters: [LimitMeter] = []
        if let limits = body["limits"] as? [[String: Any]], !limits.isEmpty {
            for limit in limits {
                guard let kind = limit["kind"] as? String, let percent = JSONValue.number(limit["percent"]) else { continue }
                let reset = JSONValue.date(limit["resets_at"])
                let group = limit["group"] as? String
                let period: TimeInterval? = switch group {
                case "session": 5 * .hour
                case "daily": .day
                case "weekly": .week
                default: nil
                }
                switch kind {
                case "session":
                    meters.append(.percent("session", "Session", used: percent, resetsAt: reset, period: period ?? 5 * .hour))
                case "weekly_all":
                    meters.append(.percent("weekly", "Weekly", used: percent, resetsAt: reset, period: period ?? .week))
                default:
                    if let model = limit[path: "scope", "model", "display_name"] as? String {
                        meters.append(.percent("model-" + model.lowercased(), model, used: percent, resetsAt: reset, period: period))
                    } else {
                        meters.append(.percent(kind, kind.titleCased, used: percent, resetsAt: reset, period: period))
                    }
                }
            }
            if !meters.isEmpty { return meters }
        }
        // Older answers only have the named windows, and a list without percentages may still have them.
        let windows: [(key: String, id: String, label: String, period: TimeInterval)] = [
            ("five_hour", "session", "Session", 5 * .hour), ("seven_day", "weekly", "Weekly", .week),
            ("seven_day_opus", "model-opus", "Opus", .week), ("seven_day_sonnet", "model-sonnet", "Sonnet", .week),
        ]
        for window in windows {
            guard let value = body[window.key] as? [String: Any], let used = JSONValue.number(value["utilization"]) else { continue }
            meters.append(.percent(window.id, window.label, used: used, resetsAt: JSONValue.date(value["resets_at"]), period: window.period))
        }
        return meters
    }

    /// Extra usage: credits spent past the plan's limits, in cents.
    static func notes(_ body: [String: Any]) -> [LimitNote] {
        guard let extra = body["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true else { return [] }
        let used = (JSONValue.number(extra["used_credits"]) ?? 0) / 100
        if let limit = JSONValue.number(extra["monthly_limit"]), limit > 0 {
            return [LimitNote(id: "extra", label: "Extra usage", value: "\(Format.dollars(used)) of \(Format.dollars(limit / 100))")]
        }
        return [LimitNote(id: "extra", label: "Extra usage", value: "\(Format.dollars(used)) spent")]
    }

    /// `claude_max` and `default_claude_max_20x` → `Max 20x`; `team` and `default_claude_max_5x` → `Team 5x`.
    static func plan(_ type: String?, _ tier: String?) -> String? {
        guard var type = type?.lowercased(), !type.isEmpty else { return nil }
        if type.hasPrefix("claude_") { type.removeFirst(7) }
        var plan = type.titleCased
        if let tier, let multiple = tier.range(of: "\\d+x", options: .regularExpression) {
            plan += " " + tier[multiple]
        }
        return plan
    }

    // MARK: - Finding the logins

    /// `remembered` are folders `CLAUDE_CONFIG_DIR` named before, as written, read even when it isn't set now.
    static func logins(home: URL = .home, environment: [String: String] = ProcessInfo.processInfo.environment, remembered: [String] = [],
                       keychain: (Keychain.Item) -> Keychain.Reading = Keychain.password) -> [Login] {
        var folders: [(url: URL, identity: URL, isDefault: Bool, service: [String])] = []
        let user = environment["USER"] ?? NSUserName()
        let custom = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        func add(_ written: String, isDefault: Bool = false) {
            let url = URL(fileURLWithPath: (written as NSString).expandingTildeInPath)
            let identity = url.appendingPathComponent(".claude.json")
            guard !folders.contains(where: { $0.identity.standardizedFileURL == identity.standardizedFileURL }) else { return }
            // `CLAUDE_CONFIG_DIR` is hashed as written, which is usually the expanded path.
            var spellings = [written, url.path, url.path + "/"]
            if url.path.hasPrefix(home.path + "/") { spellings.append("~" + url.path.dropFirst(home.path.count)) }
            var unique: Set<String> = []
            folders.append((url, identity, isDefault, spellings.filter { unique.insert($0).inserted }.map { "Claude Code-credentials-" + $0.sha256Prefix }))
        }
        if let custom { add(custom, isDefault: true) }
        // `claude` run without `CLAUDE_CONFIG_DIR` keeps its login here, whether or not the app was started with it.
        folders.append((home.appendingPathComponent(".claude"), home.appendingPathComponent(".claude.json"), custom == nil, ["Claude Code-credentials"]))
        remembered.forEach { add($0) }
        // Other config folders, named after the default one.
        for (parent, prefix) in [(home, ".claude"), (home.appendingPathComponent(".config"), "claude")] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            for name in names.sorted() where name.hasPrefix(prefix) && name != ".claude" {
                let url = parent.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(".claude.json").path) { add(url.path) }
            }
        }

        return folders.compactMap { folder in
            guard let account = JSONValue.object(file: folder.identity)?["oauthAccount"] as? [String: Any],
                  let accountID = account["accountUuid"] as? String else { return nil }
            func oauth(_ reading: String) -> [String: Any]? {
                JSONValue.object(Data(reading.utf8))?["claudeAiOauth"] as? [String: Any]
            }
            // Claude Code saves its login under the user's name; an item without one can hold other logins.
            var credentials: [String: Any]?
            var waitingOn: Keychain.Item?
            search: for service in folder.service {
                for name in [user, nil] {
                    let item = Keychain.Item(service: service, account: name)
                    switch keychain(item) {
                    case .password(let reading):
                        credentials = oauth(reading)
                        if credentials != nil { break search }
                    case .needsPermission:
                        waitingOn = item
                        break search
                    case .missing:
                        continue
                    }
                }
            }
            credentials = credentials ?? JSONValue.object(file: folder.url.appendingPathComponent(".credentials.json"))?["claudeAiOauth"] as? [String: Any]
            let token = (credentials?["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard token != nil || waitingOn != nil else { return nil }

            let organization = account["organizationUuid"] as? String
            return Login(folder: folder.url, isDefault: folder.isDefault,
                         accountID: [accountID, organization].compactMap { $0?.lowercased() }.joined(separator: "|"),
                         account: label(organization: account["organizationName"] as? String, email: account["emailAddress"] as? String),
                         token: token, waitingOn: token == nil ? waitingOn : nil, expires: JSONValue.date(credentials?["expiresAt"]),
                         scopes: credentials?["scopes"] as? [String],
                         subscription: credentials?["subscriptionType"] as? String, tier: credentials?["rateLimitTier"] as? String)
        }
    }

    /// The organization's name, or "Personal" for the one Anthropic makes for each person (`…'s Organization`).
    static func label(organization: String?, email: String?) -> String? {
        guard let organization, !organization.isEmpty else { return email }
        return organization.hasSuffix("'s Organization") ? "Personal" : organization
    }
}

/// Anthropic's usage API, for every Claude login whichever tool keeps it (Claude Code, Claude Desktop,
/// Pi), so one account shares one throttle and one profile lookup.
actor AnthropicUsage {
    static let shared = AnthropicUsage()
    private static let api = "https://api.anthropic.com/api/oauth"
    private static let baseHeaders = [
        "Accept": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        // The usage API answers some questions only for Claude Code itself.
        "User-Agent": "claude-cli/2.1.294 (external, cli)",
    ]

    /// Who a login belongs to and its plan, from the organization Anthropic has on file, which follows
    /// upgrades; the plan saved at sign-in doesn't.
    struct Profile: Sendable {
        var accountID: String
        var organizationID: String?
        var organizationName: String?
        var email: String?
        var plan: String?

        var id: String { "claude:" + [accountID, organizationID].compactMap { $0?.lowercased() }.joined(separator: "|") }
        var label: String? { ClaudeLimits.label(organization: organizationName, email: email) }
    }

    /// Looked up once per access token.
    private var profiles: [String: Profile] = [:]
    /// After a 429 each account waits as long as it's asked to.
    private var coolingUntil: [String: Date] = [:]
    /// Usage-limit reset grants, checked at most hourly as Anthropic throttles it when polled.
    private var grantChecks: [String: (checked: Date, grants: ResetGrants?)] = [:]

    static func headers(_ token: String) -> [String: String] {
        var headers = baseHeaders
        headers["Authorization"] = "Bearer " + token
        return headers
    }

    func profile(token: String) async -> Profile? {
        if let profile = profiles[token] { return profile }
        guard let body = await HTTP.get(Self.api + "/profile", headers: Self.headers(token))?.json,
              let account = body["account"] as? [String: Any], let accountID = account["uuid"] as? String else { return nil }
        let organization = body["organization"] as? [String: Any]
        let profile = Profile(accountID: accountID, organizationID: organization?["uuid"] as? String,
                              organizationName: organization?["name"] as? String, email: account["email"] as? String,
                              plan: ClaudeLimits.plan(organization?["organization_type"] as? String, organization?["rate_limit_tier"] as? String))
        profiles[token] = profile
        return profile
    }

    func limits(id: String, provider: Provider, account: String?, token: String, renew: String, plan fallback: String?) async -> AccountLimits {
        let now = Date()
        let known = profiles[token]?.plan ?? fallback
        if let until = coolingUntil[id], until > now {
            return .failed(id, provider, account: account, plan: known,
                           "Anthropic is limiting requests. Trying again \(until.formatted(.relative(presentation: .named))).")
        }
        guard let response = await HTTP.get(Self.api + "/usage", headers: Self.headers(token)) else {
            return .failed(id, provider, account: account, plan: known, "Couldn't reach Anthropic.")
        }
        switch response.status {
        case 200..<300: break
        case 401, 403:
            return .failed(id, provider, account: account, plan: known, "Login expired. \(renew)")
        case 429:
            coolingUntil[id] = now.addingTimeInterval(max(response.retryAfter ?? 300, 60))
            return .failed(id, provider, account: account, plan: known, "Anthropic is limiting requests. Trying again in a few minutes.")
        default:
            return .failed(id, provider, account: account, plan: known, "Anthropic's usage API answered HTTP \(response.status).")
        }
        guard let body = response.json else {
            return .failed(id, provider, account: account, plan: known, "Anthropic's usage API sent something unexpected.")
        }
        var result = AccountLimits(id: id, provider: provider, account: account, meters: ClaudeLimits.meters(body), notes: ClaudeLimits.notes(body))
        let profile = await self.profile(token: token)
        result.plan = profile?.plan ?? fallback
        let grants = await resetGrants(id: id, token: token)
        result.resets = grants?.resets()
        // A grant is used through the organization it belongs to.
        var login: ResetClaims.Login?
        if let grant = grants?.usable(), let organization = profile?.organizationID {
            login = .anthropic(token: token, organization: organization, grant: grant, renew: renew)
        }
        result.resets?.usable = login != nil
        await ResetClaims.shared.offer(login, for: id)
        guard result.hasValues else {
            return .failed(id, provider, account: account, plan: result.plan, "Anthropic's usage API sent no limits the app knows.")
        }
        return result
    }

    private func resetGrants(id: String, token: String) async -> ResetGrants? {
        if let cached = grantChecks[id], Date().timeIntervalSince(cached.checked) < .hour { return cached.grants }
        // Unanswered, the last answer stands and the next reading asks again. Answered at all (a 429 from the
        // throttling the hour is for included), it isn't asked again for an hour.
        guard let response = await HTTP.get(Self.api + "/usage?cedar_ember=1&skip_spend=1", headers: Self.headers(token)) else {
            return grantChecks[id]?.grants
        }
        var found = grantChecks[id]?.grants
        if response.ok, let body = response.json { found = ResetGrants(body["cedar_ember"]) }
        grantChecks[id] = (Date(), found)
        return found
    }

    /// After a reset is used, the next reading asks again rather than showing it for an hour.
    func forgetResetGrants(_ id: String) {
        grantChecks[id] = nil
    }

    /// Uses a grant. `request` makes a repeat of the request answer `already_used` instead of using another.
    static func resetRequest(token: String, organization: String, grant: String, request: String) -> ResetClaims.Request {
        ResetClaims.Request(url: "https://api.anthropic.com/api/organizations/\(organization)/reset_rate_limits", headers: headers(token),
                            body: ["program": "cedar_ember", "grant_id": grant, "request_id": request], timeout: 25)
    }

    /// What using a reset came to, and whether the answer settles its request ID.
    static func resetOutcome(_ response: HTTP.Response?, renew: String, now: Date = Date()) -> (outcome: ResetOutcome, settled: Bool) {
        guard let response else { return (.unsure("Anthropic didn't answer."), false) }
        switch response.status {
        case 200..<300: break
        case 401, 403: return (.notUsed("Login expired. \(renew)"), false)
        case 429: return (.notUsed("Anthropic is limiting requests. Try again in a few minutes."), false)
        case 500...: return (.unsure("Anthropic answered HTTP \(response.status)."), false)
        default: return (.notUsed("Anthropic turned the request down (HTTP \(response.status))."), false)
        }
        let body = response.json
        // `unavailable` says why in `reason`.
        let result = body?["result"] as? String
        switch result == "unavailable" ? body?["reason"] as? String : result {
        case "reset":
            return (.reset, true)
        // Answers a repeat of a request that went through. Only a repeat carries an ID already sent.
        case "already_used":
            return (.usedEarlier, true)
        case "not_limited":
            return (.notUsed("Your limits don't need a reset right now."), true)
        case "ineligible", "no_grant", "unknown_grant", "not_next_grant":
            return (.notUsed("That reset is no longer available."), true)
        case "cooldown", "paused", "low_priority_active":
            guard let until = JSONValue.date(body?["cooldown_until"]), until > now else {
                return (.notUsed("This reset can't be used right now."), true)
            }
            let wait = RelativeDateTimeFormatter().localizedString(for: until, relativeTo: now)
            return (.notUsed("This reset can be used again \(wait)."), true)
        case "not_authorized", "no_profile_scope":
            return (.notUsed("This login isn't allowed to use resets."), true)
        case "reset_unconfirmed", "stamp_indeterminate":
            return (.unsure("Anthropic hasn't confirmed the reset yet."), false)
        default:
            return (.unsure("Anthropic sent an answer the app doesn't know."), false)
        }
    }
}

/// Anthropic's one-off usage-limit resets (`cedar_ember`), as the usage API lists them with
/// `?cedar_ember=1`. Anthropic only lists them for Claude Code, so it's asked as Claude Code.
struct ResetGrants: Sendable, Equatable {
    struct Grant: Sendable, Equatable {
        var id: String
        var left: Int
        var ends: Date?
        /// The windows it clears: `five_hour`, `seven_day`.
        var clears: [String]
    }

    var eligible: Bool
    var grants: [Grant]
    /// The grant using a reset spends, which Anthropic picks.
    var next: String?

    /// Nil without the block, or with a grant it can't read in full, which Claude Code turns away too.
    init?(_ value: Any?) {
        guard let block = value as? [String: Any] else { return nil }
        var grants: [Grant] = []
        for entry in block["grants"] as? [Any] ?? [] {
            guard let grant = entry as? [String: Any], let id = grant["id"] as? String, !id.isEmpty,
                  let left = JSONValue.number(grant["resets_left"]) else { return nil }
            grants.append(Grant(id: id, left: max(Int(saturating: left), 0), ends: JSONValue.date(grant["ends_at"]), clears: grant["clears"] as? [String] ?? []))
        }
        eligible = block["eligible"] as? Bool == true
        self.grants = grants
        next = (block["next_grant_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func live(_ grant: Grant, now: Date) -> Bool {
        grant.left > 0 && (grant.ends.map { $0 > now } ?? true)
    }

    /// The next grant, when it has a reset left. Anthropic only takes IDs like `opus55-launch-20260921`.
    func usable(now: Date = Date()) -> String? {
        guard eligible, let next, next.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
              grants.contains(where: { $0.id == next && live($0, now: now) }) else { return nil }
        return next
    }

    /// What the card shows, or nil without any left. Paused grants count: they're held, just not usable
    /// this minute.
    func resets(now: Date = Date()) -> LimitResets? {
        guard eligible else { return nil }
        let held = grants.filter { live($0, now: now) }
        let count = held.reduce(0) { $0.addingReportingOverflow($1.left).overflow ? .max : $0 + $1.left }
        guard count > 0 else { return nil }
        let next = usable(now: now)
        let windows = ["five_hour": "session", "seven_day": "weekly"]
        let refills = held.first { $0.id == next }?.clears.compactMap { windows[$0] } ?? []
        return LimitResets(available: count, nextExpiry: held.compactMap(\.ends).min(), refills: refills, usable: next != nil)
    }
}
