import Foundation

/// Grok's weekly limit, signed in with the logins the Grok CLI keeps in `~/.grok/auth.json`. Their access
/// tokens last a few hours; the CLI renews them whenever it runs.
public struct GrokLimits: LimitsSource {
    public let provider = Provider.grok
    private static let api = "https://cli-chat-proxy.grok.com/v1"

    public init() {}

    public func fetch() async -> [AccountLimits] {
        guard let auth = JSONValue.object(file: .home.appendingPathComponent(".grok/auth.json")) else { return [] }
        var results: [AccountLimits] = []
        for (key, value) in auth.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any], let token = entry["key"] as? String, !token.isEmpty else { continue }
            let id = "grok:" + (entry["user_id"] as? String ?? key)
            let email = entry["email"] as? String
            if let expiry = JSONValue.date(entry["expires_at"] ?? entry["expires"]), expiry < Date() {
                results.append(.failed(id, provider, account: email, "Login expired. Run `grok` to renew it."))
                continue
            }
            results.append(await Self.limits(token: token, id: id, account: email, provider: .grok, renew: "Run `grok` to renew it."))
        }
        return results
    }

    /// One xAI login's limits. Pi signs in to xAI too, so it reads its login through here.
    static func limits(token: String, id: String, account: String?, provider: Provider, renew: String) async -> AccountLimits {
        let headers = ["Authorization": "Bearer " + token, "X-XAI-Token-Auth": "xai-grok-cli", "Accept": "application/json"]
        async let settings = HTTP.get(Self.api + "/settings", headers: headers)
        let plan = await settings?.json?["subscription_tier_display"] as? String
        guard let response = await HTTP.get(Self.api + "/billing?format=credits", headers: headers) else {
            return .failed(id, provider, account: account, plan: plan, "Couldn't reach xAI.")
        }
        switch response.status {
        case 200..<300: break
        case 401, 403: return .failed(id, provider, account: account, plan: plan, "Login expired. \(renew)")
        case 412 where String(decoding: response.data, as: UTF8.self).lowercased().contains("no personal team"):
            return .failed(id, provider, account: account, plan: plan, "Team accounts have no personal limit.")
        case 500...:
            return .failed(id, provider, account: account, plan: plan, "xAI's usage service is unavailable right now.")
        default:
            return .failed(id, provider, account: account, plan: plan, "xAI's usage API answered HTTP \(response.status).")
        }
        guard let config = response.json?["config"] as? [String: Any] else {
            return .failed(id, provider, account: account, plan: plan, "xAI's usage API sent something unexpected.")
        }
        var result = Self.limits(config, id: id, account: account, plan: plan)
        result.provider = provider
        return result
    }

    /// Zero values are left out of the answer, so a missing percentage means none used.
    static func limits(_ config: [String: Any], id: String, account: String?, plan: String?) -> AccountLimits {
        var result = AccountLimits(id: id, provider: .grok, account: account, plan: plan)
        let used = JSONValue.number(config["creditUsagePercent"]) ?? 0
        if let period = config["currentPeriod"] as? [String: Any] {
            let start = JSONValue.date(period["start"]), end = JSONValue.date(period["end"])
            let length = start.flatMap { start in end.map { $0.timeIntervalSince(start) } }
            let label = period["type"] as? String == "USAGE_PERIOD_TYPE_MONTHLY" ? "Monthly" : "Weekly"
            result.meters.append(.percent(label.lowercased(), label, used: used, resetsAt: end, period: length))
        }
        let cap = JSONValue.number(config[path: "onDemandCap", "val"]) ?? 0
        result.notes.append(LimitNote(id: "payg", label: "Pay as you go", value: cap > 0 ? "\(Format.dollars(cap)) cap" : "Off"))
        return result
    }
}
