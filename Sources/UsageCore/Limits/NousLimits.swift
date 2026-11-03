import Foundation

/// Nous Portal's plan limits, read from the Hermes login the portal already keeps on this Mac: the shared
/// copy `~/.hermes/shared/nous_auth.json` Hermes writes for every profile, then `~/.hermes/auth.json`. The
/// account endpoint reports a usage-window plan's allowances as gauges, and an older credit plan's monthly
/// grant against what is left of it.
public struct NousLimits: LimitsSource {
    public let provider = Provider.nous
    private static let defaultPortal = "https://portal.nousresearch.com"
    private static let renew = "Run `hermes` to renew it."

    public init() {}

    public func fetch() async -> [AccountLimits] {
        await fetch(home: .home, environment: ProcessInfo.processInfo.environment)
    }

    func fetch(home: URL, environment: [String: String]) async -> [AccountLimits] {
        var results: [AccountLimits] = []
        var seen: Set<String> = []
        for login in Self.logins(home: home, environment: environment) where seen.insert(login.token.sha256Prefix).inserted {
            results.append(await Self.limits(login))
        }
        return results
    }

    struct Login: Equatable {
        var token: String
        var portal: URL
        var expires: Date?
    }

    /// The logins Hermes keeps, shared copy first. A token from the environment is read after them, for a
    /// portal deployment Hermes hasn't written to this Mac.
    static func logins(home: URL, environment: [String: String]) -> [Login] {
        var logins: [Login] = []
        func add(_ entry: [String: Any]) {
            guard let token = entry["access_token"] as? String, !token.isEmpty else { return }
            let portal = portal(entry["portal_base_url"] as? String)
            logins.append(Login(token: token, portal: portal, expires: JSONValue.date(entry["expires_at"]) ?? JWT.expiry(token)))
        }
        if let shared = JSONValue.object(file: home.appendingPathComponent(".hermes/shared/nous_auth.json")) { add(shared) }
        if let auth = JSONValue.object(file: home.appendingPathComponent(".hermes/auth.json")),
           let entry = auth["nous"] as? [String: Any] { add(entry) }
        if let token = environment["NOUS_PORTAL_ACCESS_TOKEN"], !token.isEmpty {
            add(["access_token": token,
                 "portal_base_url": environment["NOUS_PORTAL_BASE_URL"] ?? environment["HERMES_PORTAL_BASE_URL"] ?? ""])
        }
        return logins
    }

    /// The portal a login came from, when Hermes wrote one this app may send its bearer token to. Anything
    /// else falls back to the portal itself, so a rewritten file can't send the token somewhere else.
    static func portal(_ written: String?) -> URL {
        let fallback = URL(string: defaultPortal)!
        guard let written, let url = URL(string: written), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "nousresearch.com" || host.hasSuffix(".nousresearch.com") else { return fallback }
        return url
    }

    static func limits(_ login: Login) async -> AccountLimits {
        let id = "nous:" + login.token.sha256Prefix
        if let expires = login.expires, expires <= Date() {
            return .failed(id, .nous, "Login expired. \(renew)")
        }
        guard let response = await HTTP.get(login.portal.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/oauth/account",
                                            headers: ["Authorization": "Bearer " + login.token, "Accept": "application/json"]) else {
            return .failed(id, .nous, "Couldn't reach Nous Portal.")
        }
        switch response.status {
        case 200..<300: break
        case 401, 403: return .failed(id, .nous, "Login expired. \(renew)")
        case 429: return .failed(id, .nous, "Nous Portal is limiting requests. Try again in a little while.")
        case 500...: return .failed(id, .nous, "Nous Portal's account service is unavailable right now.")
        default: return .failed(id, .nous, "Nous Portal's account API answered HTTP \(response.status).")
        }
        guard var account = response.json else {
            return .failed(id, .nous, "Nous Portal's account API sent something unexpected.")
        }
        if account["error"] != nil {
            return .failed(id, .nous, "Nous Portal's account API reported an error.")
        }
        account["token"] = login.token
        return limits(account, fallbackID: id)
    }

    /// One account body from `GET /api/oauth/account`: its gauges when it has a usage window, else its
    /// monthly credit grant, plus the credit and setting rows the card shows under the meters.
    static func limits(_ body: [String: Any], fallbackID: String) -> AccountLimits {
        let user = body["user"] as? [String: Any] ?? [:]
        let organisation = body["organisation"] as? [String: Any] ?? [:]
        let subscription = body["subscription"] as? [String: Any] ?? [:]
        let access = body["paid_service_access"] as? [String: Any] ?? [:]
        let token = body["token"] as? String ?? ""
        let name = (user["email"] as? String) ?? (organisation["name"] as? String)
        let identity = (organisation["id"] as? String) ?? (user["privy_did"] as? String) ?? token.sha256Prefix
        var result = AccountLimits(id: identity.isEmpty ? fallbackID : "nous:" + identity, provider: .nous, account: name,
                                   plan: subscription["plan"] as? String)

        let window = body["usage_window"] as? [String: Any] ?? [:]
        if let gauges = window["gauges"] as? [[String: Any]] {
            for gauge in gauges {
                guard let used = JSONValue.number(gauge["used_bp"]) else { continue }
                let key = (gauge["id"] as? String) ?? ""
                let label = (gauge["label"] as? String) ?? key.titleCased
                result.meters.append(.percent(meterID(key), label, used: used / 100,
                                              resetsAt: JSONValue.date(gauge["resets_at_ms"]), period: period(key)))
            }
        } else if let monthly = JSONValue.number(subscription["monthly_credits"]), monthly > 0,
                  let remaining = JSONValue.number(subscription["credits_remaining"]) ?? JSONValue.number(access["subscription_credits_remaining"]) {
            let used = (monthly - remaining) / monthly * 100
            result.meters.append(.percent("monthly", "Monthly credits", used: used,
                                          resetsAt: JSONValue.date(subscription["current_period_end"]), period: 30 * .day))
        }

        let purchased = JSONValue.number(body["purchased_credits_remaining"]) ?? JSONValue.number(access["purchased_credits_remaining"])
        if let purchased {
            result.notes.append(LimitNote(id: "topup", label: "Top-up credits", value: Format.dollars(purchased)))
        }
        if let keepGoing = window["keep_going_on_credits"] as? Bool {
            result.notes.append(LimitNote(id: "keep-going", label: "Keep going on credits", value: keepGoing ? "On" : "Off"))
        }
        if !result.hasValues {
            result.problem = "Nous Portal didn't report any limits for this account."
        }
        return result
    }

    /// A gauge's ID as the menu bar pins it, and the length of the window it counts.
    private static func meterID(_ key: String) -> String {
        switch key {
        case "top_tier": "top-tier"
        case "": "monthly"
        default: key.replacingOccurrences(of: "_", with: "-")
        }
    }

    private static func period(_ key: String) -> TimeInterval? {
        switch key {
        case "day": .day
        case "week": 7 * .day
        case "month", "top_tier": 30 * .day
        default: nil
        }
    }
}
