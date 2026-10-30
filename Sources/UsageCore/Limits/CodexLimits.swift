import CryptoKit
import Foundation

/// Codex's limits from ChatGPT, signed in with the login in each Codex home's `auth.json`: `$CODEX_HOME`
/// now or before, `~/.codex`, `~/.config/codex`, and side-by-side homes such as `~/.codex-work`. Codex
/// renews those logins whenever it runs; one in a home it hasn't run in for so long that it has run out is
/// renewed and saved back as Codex would (`CodexRenewal`).
public struct CodexLimits: LimitsSource {
    public let provider = Provider.codex

    public init() {}

    struct Login: Equatable {
        var token: String?
        var accountID: String?
        var waitingOn: Keychain.Item?
        /// The home whose `auth.json` it's kept in, for saving it back renewed. Nil for a keychain login.
        var home: URL?

        var id: String { "codex:" + (accountID ?? waitingOn?.account ?? "default") }
    }

    public func fetch() async -> [AccountLimits] {
        await fetch(home: .home)
    }

    func fetch(home: URL = .home, configured: [String] = EnvironmentFolders.seen("CODEX_HOME"),
               keychain: @Sendable (Keychain.Item) -> Keychain.Reading = Keychain.password,
               renewal: CodexRenewal = .shared) async -> [AccountLimits] {
        let logins: [Login] = Self.homes(home: home, configured: configured).compactMap { folder in
            if let auth = JSONValue.object(file: folder.appendingPathComponent("auth.json")),
               var login = Self.login(auth) {
                login.home = folder
                return login
            }
            guard Self.usesKeyring(folder) else { return nil }
            let item = Self.keychainItem(for: folder)
            switch keychain(item) {
            case .password(let raw):
                return JSONValue.object(Data(raw.utf8)).flatMap(Self.login)
            case .needsPermission:
                return Login(waitingOn: item)
            case .missing:
                return nil
            }
        }
        return await LimitsSources.readings(of: logins, id: \.id) { login in
            guard let token = login.token else {
                if let item = login.waitingOn { Keychain.wait(login.id, on: item) }
                return AccountLimits(id: login.id, provider: .codex,
                                     problem: "To see these limits, allow access to Codex's login and choose Always Allow.",
                                     action: .allowKeychain)
            }
            let renew = "Run `codex` to renew it."
            guard let home = login.home else {
                return await Self.limits(token: token, accountID: login.accountID, provider: .codex, renew: renew)
            }
            // Renewed only when it's read, so a home that's a copy of another account's login is left alone.
            var current = token
            if let expiry = JWT.expiry(token), expiry < Date(), case .renewed(let renewed, _) = await renewal.renew(home: home, token: token) {
                current = renewed
            }
            return await Self.limits(token: current, accountID: login.accountID, provider: .codex, renew: renew) { [current] in
                guard case .renewed(let renewed, _) = await renewal.renew(home: home, token: current, turnedAway: true), renewed != current else { return nil }
                return renewed
            }
        }
    }

    private static func login(_ auth: [String: Any]) -> Login? {
        guard let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty else {
            // Missing, or signed in with an API key, which has no plan limits.
            return nil
        }
        let accountID = tokens["account_id"] as? String ?? JWT.claims(token)?[path: "https://api.openai.com/auth", "chatgpt_account_id"] as? String
        return Login(token: token, accountID: accountID)
    }

    static func keychainItem(for home: URL) -> Keychain.Item {
        let canonical: String
        if let resolved = realpath(home.path, nil) {
            canonical = String(cString: resolved)
            free(resolved)
        } else {
            canonical = home.path
        }
        let hash = SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return Keychain.Item(service: "Codex Auth", account: "cli|" + hash)
    }

    private static func usesKeyring(_ home: URL) -> Bool {
        guard let toml = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return false }
        for line in toml.split(whereSeparator: \.isNewline) {
            let uncommented = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = uncommented.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "cli_auth_credentials_store" else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value == "keyring" || value == "auto"
        }
        return false
    }

    /// Codex homes with a login, the one Codex uses by default first.
    /// `configured` are the folders `CODEX_HOME` names now or has named before.
    static func homes(home: URL = .home, configured: [String] = EnvironmentFolders.seen("CODEX_HOME")) -> [URL] {
        var homes = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        homes += [home.appendingPathComponent(".codex"), home.appendingPathComponent(".config/codex")]
        for parent in [home, home.appendingPathComponent(".config")] {
            let prefix = parent == home ? ".codex-" : "codex-"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            homes += names.sorted().filter { $0.hasPrefix(prefix) }.map { parent.appendingPathComponent($0) }
        }
        var seen: Set<String> = []
        return homes.filter {
            (FileManager.default.fileExists(atPath: $0.appendingPathComponent("auth.json").path) || usesKeyring($0))
                && seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    /// One ChatGPT login's limits. Pi signs in to ChatGPT too, so it reads its login through here. `renewing`
    /// gives a new token for one ChatGPT turned away before its time; the reading is asked again once with it.
    static func limits(token: String, accountID: String?, provider: Provider, renew: String,
                       renewing: (@Sendable () async -> String?)? = nil) async -> AccountLimits {
        let claims = JWT.claims(token)
        let id = "codex:" + (accountID ?? "default")
        let email = claims?[path: "https://api.openai.com/profile", "email"] as? String
        if let expiry = JWT.expiry(token), expiry < Date() {
            return .failed(id, provider, account: email, "Login expired. \(renew)")
        }
        guard let response = await HTTP.get("https://chatgpt.com/backend-api/wham/usage", headers: headers(token: token, accountID: accountID)) else {
            return .failed(id, provider, account: email, "Couldn't reach ChatGPT.")
        }
        switch response.status {
        case 200..<300: break
        case 401, 403:
            if response.status == 401, let renewing, let fresh = await renewing() {
                return await limits(token: fresh, accountID: accountID, provider: provider, renew: renew)
            }
            return .failed(id, provider, account: email, "Login expired. \(renew)")
        default: return .failed(id, provider, account: email, "ChatGPT's usage API answered HTTP \(response.status).")
        }
        guard let body = response.json else { return .failed(id, provider, account: email, "ChatGPT's usage API sent something unexpected.") }
        var result = limits(body, id: id, account: body["email"] as? String ?? email)
        result.provider = provider
        if !result.hasValues {
            return .failed(id, provider, account: result.account, plan: result.plan, "ChatGPT's usage API sent no limits the app knows.")
        }
        if result.resets != nil {
            // The usage answer only counts the resets; their list says when they lapse.
            if let list = await HTTP.get(resetsURL, headers: resetHeaders(token: token, accountID: accountID)), list.ok, let body = list.json {
                result.resets?.nextExpiry = resetCredits(body).first?.expires
            }
            await ResetClaims.shared.offer(.chatGPT(token: token, accountID: accountID, renew: renew), for: id)
        } else {
            await ResetClaims.shared.offer(nil, for: id)
        }
        return result
    }

    static func headers(token: String, accountID: String?) -> [String: String] {
        var headers = ["Authorization": "Bearer " + token, "Accept": "application/json"]
        if let accountID, !accountID.isEmpty { headers["ChatGPT-Account-Id"] = accountID }
        return headers
    }

    static func limits(_ body: [String: Any], id: String, account: String?) -> AccountLimits {
        var result = AccountLimits(id: id, provider: .codex, account: account, plan: plan(body["plan_type"] as? String))
        let own = (body["rate_limit"] as? [String: Any]).map { meters($0, prefix: "", label: "") } ?? []
        result.meters += own
        let sparks = (body["additional_rate_limits"] as? [[String: Any]] ?? []).compactMap { extra -> (name: String, limit: [String: Any])? in
            let name = extra["limit_name"] as? String ?? extra["metered_feature"] as? String ?? ""
            guard name.lowercased().contains("spark"), let limit = extra["rate_limit"] as? [String: Any] else { return nil }
            return (name, limit)
        }
        // Several are told apart by name, so a pinned one stays pinned whatever order they come in. The
        // shortest name, the model's own, keeps the IDs a single one has.
        let base = sparks.map(\.name).min { ($0.count, $0) < ($1.count, $1) }
        for spark in sparks {
            let slug = String(spark.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let (prefix, label) = spark.name == base ? ("spark-", "Spark ") : (slug + "-", spark.name + " ")
            result.meters += meters(spark.limit, prefix: prefix, label: label)
        }
        if let review = body["code_review_rate_limit"] as? [String: Any] {
            result.meters += meters(review, prefix: "review-", label: "Code Review ")
        }
        if let credits = body["credits"] as? [String: Any], credits["has_credits"] as? Bool == true,
           let balance = JSONValue.number(credits["balance"]), balance > 0 {
            result.notes.append(LimitNote(id: "credits", label: "Credits", value: Format.grouped(balance)))
        }
        if let count = JSONValue.number(body[path: "rate_limit_reset_credits", "available_count"]), count > 0 {
            // A reset refills the plan's own windows: the session and the week, or the month on Free.
            result.resets = LimitResets(available: Int(saturating: count), refills: own.map(\.id))
        }
        if !result.hasValues {
            result.problem = "ChatGPT's usage API sent no limits the app knows."
        }
        return result
    }

    /// A window is named by its length: five hours is the session, seven days the week. Free plans have a
    /// single 30-day window.
    private static func meters(_ limit: [String: Any], prefix: String, label: String) -> [LimitMeter] {
        var meters: [LimitMeter] = []
        for (slot, fallback) in [("primary_window", "Session"), ("secondary_window", "Weekly")] {
            guard let window = limit[slot] as? [String: Any], let used = JSONValue.number(window["used_percent"]) else { continue }
            let seconds = JSONValue.number(window["limit_window_seconds"])
            let reset = JSONValue.date(window["reset_at"])
                ?? JSONValue.number(window["reset_after_seconds"]).flatMap(Timestamp.seconds).map { Date().addingTimeInterval($0) }
            let name: String = switch seconds {
            case 18_000?: "Session"
            case 604_800?: "Weekly"
            case let seconds? where seconds >= 2_419_200: "Monthly"
            case let seconds? where seconds == 86_400: "Daily"
            default: fallback
            }
            meters.append(.percent(prefix + name.lowercased(), label + name, used: used, resetsAt: reset, period: seconds))
        }
        return meters
    }

    // MARK: - Limit resets

    /// The rate limit resets OpenAI hands out, as the Codex CLI lists and uses them. Using one posts to
    /// `/consume` with the credit's ID and a request ID that makes a repeat of the request harmless.
    static let resetsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

    /// The reset endpoints expect what the Codex app sends.
    static func resetHeaders(token: String, accountID: String?) -> [String: String] {
        headers(token: token, accountID: accountID).merging(["OpenAI-Beta": "codex-1", "originator": "Codex Desktop"]) { $1 }
    }

    /// The resets that can still be used, the first to lapse first. One without a status counts as
    /// available, and one without an expiry never lapses.
    static func resetCredits(_ body: [String: Any], now: Date = Date()) -> [(id: String, expires: Date?)] {
        let credits = (body["credits"] as? [[String: Any]] ?? []).compactMap { credit -> (id: String, expires: Date?)? in
            guard let id = credit["id"] as? String, !id.isEmpty, (credit["status"] as? String ?? "available") == "available" else { return nil }
            let expires = JSONValue.date(credit["expires_at"])
            if let expires, expires <= now { return nil }
            return (id, expires)
        }
        return credits.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
    }

    /// What using a reset came to, and whether the answer settles its request ID. ChatGPT answers every
    /// outcome with HTTP 200 and names it in `code`.
    static func resetOutcome(_ response: HTTP.Response?, renew: String) -> (outcome: ResetOutcome, settled: Bool) {
        guard let response else { return (.unsure("ChatGPT didn't answer."), false) }
        switch response.status {
        case 200..<300: break
        case 401, 403: return (.notUsed("Login expired. \(renew)"), false)
        case 429: return (.notUsed("ChatGPT is limiting requests. Try again in a few minutes."), false)
        case 500...: return (.unsure("ChatGPT answered HTTP \(response.status)."), false)
        default: return (.notUsed("ChatGPT turned the request down (HTTP \(response.status))."), false)
        }
        switch response.json?["code"] as? String {
        case "reset": return (.reset, true)
        // Answers a repeat of a request that went through. Only a repeat carries an ID already sent.
        case "already_redeemed": return (.usedEarlier, true)
        case "nothing_to_reset": return (.notUsed("Your limits don't need a reset right now."), true)
        case "no_credit": return (.notUsed("That reset is no longer available."), true)
        default: return (.unsure("ChatGPT sent an answer the app doesn't know."), false)
        }
    }

    /// `pro` → `Pro`, `prolite` → `Pro Lite`, `team_plus` → `Team Plus`.
    static func plan(_ type: String?) -> String? {
        guard let type = type?.lowercased(), !type.isEmpty else { return nil }
        switch type {
        case "prolite": return "Pro Lite"
        case "promax": return "Pro Max"
        default: return type.titleCased
        }
    }
}
