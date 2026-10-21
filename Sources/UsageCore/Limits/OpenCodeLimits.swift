import Foundation

/// OpenCode Go's rolling, weekly and monthly limits, with the API key OpenCode keeps in its `auth.json`
/// (or, since OpenCode 2, its database).
public struct OpenCodeLimits: LimitsSource {
    public let provider = Provider.opencode

    public init() {}

    public func fetch() async -> [AccountLimits] {
        guard let key = Self.key() else { return [] }
        let id = "opencode:" + key.sha256Prefix
        guard let response = await HTTP.get("https://opencode.ai/zen/go/v1/usage", headers: ["Authorization": "Bearer " + key, "Accept": "application/json"]) else {
            return [.failed(id, provider, plan: "Go", "Couldn't reach OpenCode.")]
        }
        return Self.limits(response, id: id)
    }

    static func limits(_ response: HTTP.Response, id: String) -> [AccountLimits] {
        let provider = Provider.opencode
        switch response.status {
        case 200..<300: break
        case 401:
            let expired = String(decoding: response.data, as: UTF8.self).contains("expired")
            return [.failed(id, provider, plan: "Go", expired ? "The OpenCode Go key has expired. Add a new one in OpenCode." : "OpenCode rejected the Go key. Sign in to OpenCode Go again.")]
        case 403:
            return [.failed(id, provider, plan: "Go", "This OpenCode Go key has no active subscription.")]
        default:
            return [.failed(id, provider, plan: "Go", "OpenCode's usage API answered HTTP \(response.status).")]
        }
        guard let usage = response.json?["usage"] as? [String: Any] else {
            return [.failed(id, provider, plan: "Go", "OpenCode's usage API sent something unexpected.")]
        }
        var result = AccountLimits(id: id, provider: provider, plan: "Go")
        let windows: [(key: String, id: String, label: String, period: TimeInterval)] = [
            ("rolling", "session", "Session", 5 * .hour), ("weekly", "weekly", "Weekly", .week), ("monthly", "monthly", "Monthly", 30 * .day),
        ]
        for window in windows {
            guard let value = usage[window.key] as? [String: Any], let percent = JSONValue.number(value["percent"]) else { continue }
            var reset = JSONValue.date(value["resetsAt"])
            // An idle session reports a placeholder reset five hours from now; it hasn't started.
            if window.id == "session", percent == 0, let date = reset, abs(date.timeIntervalSinceNow - 5 * .hour) < 60 { reset = nil }
            result.meters.append(.percent(window.id, window.label, used: percent, resetsAt: reset, period: window.period))
        }
        guard result.hasValues else {
            return [.failed(id, provider, plan: "Go", "OpenCode's usage API sent no limits the app knows.")]
        }
        return [result]
    }

    private static func key() -> String? {
        let root = OpenCodeSource.defaultRoot
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names.sorted() where name.hasPrefix("opencode") && name.hasSuffix(".db") {
            guard let reader = SQLiteReader(path: root.appendingPathComponent(name).path), reader.hasTable("credential") == true else { continue }
            var key: String?
            reader.rows("""
                SELECT json_extract(value, '$.key') FROM credential
                WHERE integration_id = 'opencode-go' AND (active IS NULL OR active = 1)
                ORDER BY active DESC, time_updated DESC LIMIT 1
                """) { key = $0.text(0) }
            if let key, !key.isEmpty { return key }
        }
        let auth = JSONValue.object(file: root.appendingPathComponent("auth.json"))
        return (auth?["opencode-go"] as? [String: Any])?["key"] as? String
    }
}
