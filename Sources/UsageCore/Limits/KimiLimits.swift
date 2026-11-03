import Foundation

/// Kimi's Coding Plan limits. Kimi Code signs in with an API key — Hermes keeps one in `~/.hermes/.env`,
/// and every agent here bills the plan with it — or with the short-lived login `kimi` saves in
/// `~/.kimi-code/credentials`. The plan reports its 5-hour and monthly pools, and the older per-window
/// request counts when a pool isn't reported.
public struct KimiLimits: LimitsSource {
    public let provider = Provider.kimi
    private static let international = URL(string: "https://api.kimi.ai")!
    private static let china = URL(string: "https://api.kimi.com")!

    public init() {}

    public func fetch() async -> [AccountLimits] {
        await fetch(home: .home, environment: ProcessInfo.processInfo.environment)
    }

    func fetch(home: URL, environment: [String: String]) async -> [AccountLimits] {
        await LimitsSources.readings(of: Self.logins(home: home, environment: environment), id: \.id) { login in
            await Self.limits(login)
        }
    }

    struct Login: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case apiKey
            case cli
        }

        var token: String
        var kind: Kind
        var base: URL
        var expires: Date?
        var id: String { "kimi:" + token.sha256Prefix }
        /// What to do when Kimi turns the login away.
        var renew: String {
            switch kind {
            case .apiKey: "Check KIMI_API_KEY in Hermes's .env."
            case .cli: "Run `kimi` to sign in again."
            }
        }
    }

    /// An API key first, as Kimi Code's own console issues one that doesn't expire every fifteen minutes;
    /// the CLI's login only when there is no key.
    static func logins(home: URL, environment: [String: String]) -> [Login] {
        let dotenv = environmentFile(home.appendingPathComponent(".hermes/.env"))
        if let key = dotenv["KIMI_API_KEY"] ?? environment["KIMI_CODE_API_KEY"] ?? environment["KIMI_API_KEY"], !key.isEmpty {
            return [Login(token: key, kind: .apiKey, base: china, expires: nil)]
        }
        guard let credential = JSONValue.object(file: home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")),
              let token = credential["access_token"] as? String, !token.isEmpty else { return [] }
        var base = international
        if let config = try? String(contentsOf: home.appendingPathComponent(".kimi-code/config.toml"), encoding: .utf8),
           let range = config.range(of: #"base_url\s*=\s*"https://api\.kimi\.(ai|com)[^"]*""#, options: .regularExpression) {
            let written = String(config[range])
            base = written.contains("kimi.com") ? china : international
        }
        return [Login(token: token, kind: .cli, base: base, expires: JSONValue.date(credential["expires_at"]) ?? JWT.expiry(token))]
    }

    static func limits(_ login: Login) async -> AccountLimits {
        if let expires = login.expires, expires <= Date() {
            return .failed(login.id, .kimi, "Login expired. \(login.renew)")
        }
        let headers = ["Authorization": "Bearer " + login.token, "Accept": "application/json"]
        var response = await HTTP.get(login.base.absoluteString + "/coding/v1/usages", headers: headers)
        // A key issued on the other side of the region split answers at the other host; the two report the
        // same plan for one account. Only an authentication answer is worth the second request.
        if let status = response?.status, status == 401 || status == 403 || status == 404 {
            let other = login.base == china ? international : china
            if let retry = await HTTP.get(other.absoluteString + "/coding/v1/usages", headers: headers) {
                response = retry
            }
        }
        guard let response else {
            return .failed(login.id, .kimi, "Couldn't reach Kimi.")
        }
        switch response.status {
        case 200..<300: break
        case 401, 403: return .failed(login.id, .kimi, login.kind == .apiKey ? "Kimi rejected this API key. \(login.renew)" : "Login expired. \(login.renew)")
        case 429: return .failed(login.id, .kimi, "Kimi is limiting requests. Try again in a little while.")
        case 500...: return .failed(login.id, .kimi, "Kimi's usage service is unavailable right now.")
        default: return .failed(login.id, .kimi, "Kimi's usage API answered HTTP \(response.status).")
        }
        guard let body = response.json else {
            return .failed(login.id, .kimi, "Kimi's usage API sent something unexpected.")
        }
        let claims = JWT.claims(login.token)
        let account = (claims?["email"] as? String) ?? (claims?["sub"] as? String)
        let id = account.map { "kimi:" + $0 } ?? login.id
        return limits(body, id: id, account: account)
    }

    /// One answer from `GET /coding/v1/usages`: the `usages` ratio pools (5-hour, weekly, monthly total), or
    /// the older `limits` request counts when a window has no pool, and the monthly Kai Code share as a note.
    static func limits(_ body: [String: Any], id: String, account: String?) -> AccountLimits {
        var result = AccountLimits(id: id, provider: .kimi, account: account, plan: plan(body))
        let usages = body["usages"] as? [String: Any] ?? [:]

        let pools: [(key: String, id: String, label: String, period: TimeInterval)] = [
            ("limit_5h", "5-hour", "5-hour", 5 * .hour),
            ("limit_week", "weekly", "Weekly", 7 * .day),
            ("limit_month_total", "month", "This month", 30 * .day),
        ]
        for pool in pools {
            guard let entry = usages[pool.key] as? [String: Any], let ratio = JSONValue.number(entry["used_ratio"]) else { continue }
            result.meters.append(.percent(pool.id, pool.label, used: ratio * 100,
                                          resetsAt: JSONValue.date(entry["reset_time"]), period: pool.period))
        }

        // Counts remain for a window the pools didn't cover, such as a plan that reports only requests.
        if let limits = body["limits"] as? [[String: Any]] {
            for limit in limits {
                let window = limit["window"] as? [String: Any] ?? [:]
                let detail = limit["detail"] as? [String: Any] ?? [:]
                let minutes = JSONValue.number(window["duration"]) ?? 0
                let period = minutes > 0 ? minutes * 60 : nil
                if let period, result.meters.contains(where: { $0.period == period }) { continue }
                guard let total = JSONValue.number(detail["limit"]), total > 0,
                      let used = JSONValue.number(detail["used"]) else { continue }
                let label = minutes == 300 ? "5-hour" : minutes == 10_080 ? "Weekly" : "\(Int(minutes)) min window"
                let meterID = minutes == 300 ? "5-hour" : minutes == 10_080 ? "weekly" : "window-\(Int(minutes))"
                result.meters.append(LimitMeter(id: meterID, label: label, used: used, limit: total, unit: .count,
                                                 resetsAt: JSONValue.date(detail["resetTime"]), period: period))
            }
        }

        if let entry = usages["limit_month_code"] as? [String: Any], let ratio = JSONValue.number(entry["used_ratio"]) {
            let tenths = (ratio * 1000).rounded()
            result.notes.append(LimitNote(id: "code-share", label: "Code this month",
                                          value: String(format: "%.1f%% of the month", tenths / 10)))
        }
        if !result.hasValues {
            result.problem = "Kimi didn't report any limits for this plan."
        }
        return result
    }

    /// The membership level the plan reports, when it names one.
    private static func plan(_ body: [String: Any]) -> String? {
        if let plan = body["membership"] as? String, !plan.isEmpty { return plan }
        if let membership = body["membership"] as? [String: Any] {
            for key in ["title", "name", "level"] {
                if let plan = membership[key] as? String, !plan.isEmpty { return plan }
            }
        }
        return nil
    }

    /// `KEY=value` lines from a dotenv file, quotes around a value taken off. Comments are skipped.
    private static func environmentFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}
