import Foundation

/// Antigravity's limits from Google's Cloud Code API, signed in with the logins the Antigravity app and its
/// `agy` CLI keep: the keychain (`gemini` / `antigravity`, or `antigravity-cli`) and `agy`'s
/// `~/.gemini/jetski-standalone-oauth-token`. One Google account signed in to both is one card. Access
/// tokens last an hour; a new one is fetched with the login's refresh token, which Google doesn't rotate,
/// and kept in memory only, so the tools' own logins are never touched.
///
/// Paid plans answer with a summary of their shared pools (Gemini models, and Claude with GPT-OSS), each
/// with a five-hour and a weekly window. Other accounts list each model's quota instead; those are pooled
/// the same way, the window told by how far off its reset is, and the most used model in each speaks for
/// its pool.
public actor AntigravityLimits: LimitsSource {
    public nonisolated let provider = Provider.antigravity
    private static let hosts = ["https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com"]
    // Antigravity's own OAuth client, as it ships in every copy of the app and `agy`; Google doesn't treat
    // an installed app's secret as confidential.
    private static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let clientSecret = "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"
    /// Google drops the paid tier from answers to callers that don't look like Antigravity.
    private static let clientAgent = "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=\(AntigravityLimits.architecture))"
    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }
    private static let renew = "Open Antigravity or run `agy` to sign in again."

    /// Renewed access tokens, by the refresh token they came from.
    private var renewed: [String: (token: String, expires: Date, email: String?)] = [:]
    private var plans: [String: String] = [:]
    private var weeklyResets: Set<Date> = []

    public init() {}

    struct Login: Equatable {
        var access: String?
        var refresh: String?
        var expires: Date?
    }

    /// A working access token for a login, and whose it is.
    struct Session {
        var token: String?
        var email: String?
        var problem: String?
    }

    public func fetch() async -> [AccountLimits] {
        await fetch(home: .home, keychain: Keychain.password)
    }

    func fetch(home: URL = .home, keychain: @Sendable (Keychain.Item) -> Keychain.Reading = Keychain.password) async -> [AccountLimits] {
        let (logins, waitingOn) = Self.logins(home: home, keychain: keychain)
        var results: [AccountLimits] = []
        var seen: Set<String> = []
        for login in logins {
            // Renewing names the account, which tells one person's two logins from two people's.
            let session = await session(for: login)
            let id = "antigravity:" + (session.email?.lowercased() ?? (login.refresh ?? login.access ?? "").sha256Prefix)
            guard seen.insert(id).inserted else { continue }
            results.append(await limits(session, id: id, provider: provider))
        }
        if let item = waitingOn {
            let id = "antigravity:keychain"
            Keychain.wait(id, on: item)
            results.append(AccountLimits(id: id, provider: provider, problem: "To see these limits, allow access to Antigravity's login and choose Always Allow.",
                                         action: .allowKeychain))
        }
        return results
    }

    /// Every login on this Mac: the app's keychain item, `agy`'s, then `agy`'s file. With the first keychain
    /// item that needs the person's permission.
    static func logins(home: URL = .home, keychain: (Keychain.Item) -> Keychain.Reading = Keychain.password) -> (logins: [Login], waitingOn: Keychain.Item?) {
        var logins: [Login] = []
        var waitingOn: Keychain.Item?
        for account in ["antigravity", "antigravity-cli"] {
            let item = Keychain.Item(service: "gemini", account: account)
            switch keychain(item) {
            case .password(let raw):
                if let login = login(raw), !logins.contains(login) { logins.append(login) }
            case .needsPermission:
                waitingOn = waitingOn ?? item
            case .missing:
                break
            }
        }
        let file = home.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        if let raw = try? String(contentsOf: file, encoding: .utf8), let login = login(raw), !logins.contains(login) { logins.append(login) }
        return (logins, waitingOn)
    }

    /// A renewed token when the login can renew, kept until it nears expiry; else the login's own while it lasts.
    private func session(for login: Login) async -> Session {
        let soon = Date().addingTimeInterval(60)
        let own = login.access.flatMap { (login.expires ?? .distantFuture) > soon ? $0 : nil }
        guard let refresh = login.refresh else {
            return own.map { Session(token: $0) } ?? Session(problem: "Login expired. \(Self.renew)")
        }
        if let cached = renewed[refresh], cached.expires > soon { return Session(token: cached.token, email: cached.email) }
        switch await renewToken(refresh) {
        case .renewed(let token, let expires, let email):
            let email = email ?? renewed[refresh]?.email
            renewed[refresh] = (token, expires, email)
            return Session(token: token, email: email)
        case .rejected:
            return Session(problem: "Login expired. \(Self.renew)")
        case .unavailable:
            return own.map { Session(token: $0, email: renewed[refresh]?.email) } ?? Session(email: renewed[refresh]?.email, problem: "Couldn't reach Google.")
        }
    }

    func limits(_ session: Session, id: String, provider: Provider) async -> AccountLimits {
        guard let token = session.token else {
            return .failed(id, provider, account: session.email, session.problem ?? "Login expired. \(Self.renew)")
        }
        switch await read(token: token) {
        case .success(var result):
            result.id = id
            result.provider = provider
            result.account = session.email
            return result
        case .unavailable:
            return .failed(id, provider, account: session.email, "Google's quota service is unavailable right now.")
        case .rejected:
            return .failed(id, provider, account: session.email, "Google didn't accept this login. \(Self.renew)")
        }
    }

    private enum Reading {
        case success(AccountLimits)
        case rejected
        case unavailable
    }

    private func read(token: String) async -> Reading {
        let headers = ["Authorization": "Bearer " + token, "Accept": "application/json"]
        // The summary, from both hosts: one can leave out a pool the other has.
        var bodies: [[String: Any]] = []
        var rejected = false
        for host in Self.hosts {
            guard let response = await HTTP.post(host + "/v1internal:retrieveUserQuotaSummary", headers: headers.merging(["User-Agent": "antigravity"]) { $1 }, json: [String: Any]()) else { continue }
            if response.ok, let body = response.json, let groups = body["groups"] as? [[String: Any]], !groups.isEmpty {
                bodies.append(body)
                if Self.summaryMeters(bodies).count >= 4 { break }
            } else if response.status == 401 {
                rejected = true
            }
        }
        let summary = Self.summaryMeters(bodies)
        if !summary.isEmpty {
            return .success(AccountLimits(id: "", provider: provider, plan: await plan(token: token), meters: summary))
        }
        if rejected { return .rejected }

        // Accounts without the summary (free ones, and older builds) list each model's quota.
        for host in Self.hosts {
            guard let response = await HTTP.post(host + "/v1internal:fetchAvailableModels", headers: headers.merging(["User-Agent": "antigravity"]) { $1 }, json: [String: Any]()) else { continue }
            switch response.status {
            case 200..<300:
                guard let models = response.json?["models"] as? [String: Any] else { continue }
                let now = Date()
                weeklyResets = weeklyResets.union(Self.weeklyResets(in: models, now: now)).filter { $0 > now }
                return .success(AccountLimits(id: "", provider: provider, plan: await plan(token: token), meters: Self.modelMeters(models, now: now, weeklyResets: weeklyResets)))
            case 401, 403:
                return .rejected
            default:
                continue
            }
        }
        return .unavailable
    }

    /// The plan, looked up once per access token: the Google One tier, else the tier's own name.
    private func plan(token: String) async -> String? {
        if let plan = plans[token] { return plan }
        let body: [String: Any] = ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
        guard let answer = await HTTP.post(Self.hosts[0] + "/v1internal:loadCodeAssist",
                                           headers: ["Authorization": "Bearer " + token, "Accept": "application/json", "User-Agent": Self.clientAgent], json: body)?.json
        else { return nil }
        let plan = Self.plan(paid: answer["paidTier"] as? [String: Any], current: answer["currentTier"] as? [String: Any])
        if let plan { plans[token] = plan }
        return plan
    }

    private enum Renewal {
        case renewed(String, Date, String?)
        case rejected
        case unavailable
    }

    private func renewToken(_ refresh: String) async -> Renewal {
        let form = ["client_id": Self.clientID, "client_secret": Self.clientSecret, "refresh_token": refresh, "grant_type": "refresh_token"]
        guard let response = await HTTP.postForm("https://oauth2.googleapis.com/token", form: form) else { return .unavailable }
        switch response.status {
        case 200..<300:
            guard let body = response.json, let token = body["access_token"] as? String else { return .unavailable }
            let lifetime = JSONValue.number(body["expires_in"]) ?? 3600
            let email = (body["id_token"] as? String).flatMap(JWT.claims)?["email"] as? String
            return .renewed(token, Date().addingTimeInterval(lifetime), email)
        case 408, 429, 500...:
            return .unavailable
        default:
            return .rejected
        }
    }

    // MARK: - Reading the answers

    /// The keychain value: `go-keyring-base64:` and base64 of `{"token": {"access_token", "refresh_token",
    /// "expiry"}}`, or that JSON as is, or a bare token.
    static func login(_ raw: String) -> Login? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("go-keyring-base64:"), let data = Data(base64Encoded: String(text.dropFirst(18))), let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        }
        guard let object = JSONValue.object(Data(text.utf8)) else {
            return text.isEmpty ? nil : Login(access: text.replacingOccurrences(of: "Bearer ", with: ""))
        }
        let token = object["token"] as? [String: Any] ?? object
        let login = Login(access: token["access_token"] as? String, refresh: token["refresh_token"] as? String, expires: JSONValue.date(token["expiry"]))
        return login.access == nil && login.refresh == nil ? nil : login
    }

    /// The four shared buckets, matched by their exact IDs, and Gemini 4 Argon's own weekly quota. The
    /// first answer with a bucket wins.
    static func summaryMeters(_ bodies: [[String: Any]]) -> [LimitMeter] {
        let buckets: [(id: String, label: String, period: TimeInterval)] = [
            ("gemini-5h", "Gemini Session", 5 * .hour), ("gemini-weekly", "Gemini Weekly", .week),
            ("3p-5h", "Claude Session", 5 * .hour), ("3p-weekly", "Claude Weekly", .week),
        ]
        var found: [String: LimitMeter] = [:]
        var argon: LimitMeter?
        for body in bodies {
            for group in body["groups"] as? [[String: Any]] ?? [] {
                let isArgon = group["displayName"] as? String == "Gemini 4 Argon"
                for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                    // A bucket without a fraction is left out rather than guessed at.
                    guard let left = JSONValue.number(bucket["remainingFraction"]), bucket["disabled"] as? Bool != true else { continue }
                    let reset = JSONValue.date(bucket["resetTime"])
                    if isArgon {
                        if argon == nil, bucket["window"] as? String == "weekly" {
                            argon = .percent("argon-weekly", "Argon Weekly", used: ((1 - min(max(left, 0), 1)) * 100).rounded(), resetsAt: reset, period: .week)
                        }
                    } else if let id = bucket["bucketId"] as? String, let spec = buckets.first(where: { $0.id == id }), found[id] == nil {
                        found[id] = .percent(spec.id, spec.label, used: ((1 - min(max(left, 0), 1)) * 100).rounded(), resetsAt: reset, period: spec.period)
                    }
                }
            }
        }
        var meters = buckets.compactMap { found[$0.id] }
        if let argon { meters.insert(argon, at: meters.firstIndex { $0.id.hasPrefix("3p") } ?? meters.endIndex) }
        return meters
    }

    /// Per-model quotas pooled into Gemini and the rest, each split into five-hour and weekly windows by
    /// how far off the model's reset is. Zero values are left out of the answer, so a quota without a
    /// fraction is used up; a model without a quota has no limit and is skipped.
    static func modelMeters(_ models: [String: Any], now: Date = Date(), weeklyResets: Set<Date> = []) -> [LimitMeter] {
        var pools: [String: (label: String, period: TimeInterval, used: Double, reset: Date?)] = [:]
        for (key, value) in models {
            guard let model = value as? [String: Any], model["isInternal"] as? Bool != true,
                  let name = (model["displayName"] as? String) ?? (model["label"] as? String), !name.isEmpty,
                  let quota = model["quotaInfo"] as? [String: Any] else { continue }
            // Argon's window isn't said here, so it's left to the summary.
            guard !name.lowercased().contains("argon"), !key.lowercased().contains("argon") else { continue }
            let left = min(max(JSONValue.number(quota["remainingFraction"]) ?? 0, 0), 1)
            let reset = JSONValue.date(quota["resetTime"])
            let weekly = reset.map { $0.timeIntervalSince(now) > 5 * .hour + 600 || weeklyResets.contains($0) } ?? false
            let gemini = name.lowercased().contains("gemini")
            let id = (gemini ? "gemini" : "3p") + (weekly ? "-weekly" : "-5h")
            let label = (gemini ? "Gemini" : "Claude") + (weekly ? " Weekly" : " Session")
            let used = ((1 - left) * 100).rounded()
            if let pool = pools[id], pool.used >= used { continue }
            pools[id] = (label, weekly ? .week : 5 * .hour, used, reset)
        }
        return ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"].compactMap { id in
            pools[id].map { LimitMeter.percent(id, $0.label, used: $0.used, resetsAt: $0.reset, period: $0.period) }
        }
    }

    static func weeklyResets(in models: [String: Any], now: Date) -> Set<Date> {
        var resets: Set<Date> = []
        for (key, value) in models {
            guard let model = value as? [String: Any], model["isInternal"] as? Bool != true,
                  let name = (model["displayName"] as? String) ?? (model["label"] as? String), !name.isEmpty,
                  let quota = model["quotaInfo"] as? [String: Any],
                  !name.lowercased().contains("argon"), !key.lowercased().contains("argon"),
                  let reset = JSONValue.date(quota["resetTime"]), reset.timeIntervalSince(now) > 5 * .hour + 600 else { continue }
            resets.insert(reset)
        }
        return resets
    }

    /// Google One's tiers by ID, else the tier's name: `Google AI Pro` → `Pro`, the free tier → `Free`.
    static func plan(paid: [String: Any]?, current: [String: Any]?) -> String? {
        let known = ["g1-pro-tier": "Pro", "g1-ultra-tier": "Ultra", "g1-ultra-lite-tier": "Ultra Lite", "free-tier": "Free"]
        for tier in [paid, current] {
            if let id = tier?["id"] as? String, let plan = known[id] { return plan }
        }
        guard let name = (paid?["name"] ?? current?["name"]) as? String, !name.isEmpty else { return nil }
        return name.hasPrefix("Google AI ") ? String(name.dropFirst(10)) : name
    }
}
