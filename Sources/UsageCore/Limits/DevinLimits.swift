import Foundation

/// Devin's daily and weekly quota, with the API key Devin keeps in `~/.local/share/devin/credentials.toml`
/// (or, when only the app is signed in, its `state.vscdb`).
public struct DevinLimits: LimitsSource {
    public let provider = Provider.devin

    public init() {}

    public func fetch() async -> [AccountLimits] {
        await fetch(home: .home)
    }

    func fetch(home: URL = .home, configured: [String] = EnvironmentFolders.seen("XDG_DATA_HOME")) async -> [AccountLimits] {
        guard let (key, server) = Self.credentials(home: home, configured: configured) else { return [] }
        let id = "devin:" + key.sha256Prefix
        let body: [String: Any] = ["metadata": [
            "apiKey": key, "ideName": "devin", "ideVersion": "1.108.2", "extensionName": "devin", "extensionVersion": "1.108.2", "locale": "en",
        ]]
        guard let response = await HTTP.post(server + "/exa.seat_management_pb.SeatManagementService/GetUserStatus",
                                              headers: ["Connect-Protocol-Version": "1"], json: body) else {
            return [.failed(id, provider, "Couldn't reach Devin.")]
        }
        switch response.status {
        case 200..<300: break
        case 401, 403: return [.failed(id, provider, "Login expired. Run `devin auth login` to sign in again.")]
        default: return [.failed(id, provider, "Devin's usage API answered HTTP \(response.status).")]
        }
        guard let status = response.json?[path: "userStatus", "planStatus"] as? [String: Any] else {
            return [.failed(id, provider, "Devin's usage API sent something unexpected.")]
        }
        let result = Self.limits(status, id: id)
        guard result.hasValues else {
            return [.failed(id, provider, plan: result.plan, "Devin's usage API sent no limits the app knows.")]
        }
        return [result]
    }

    /// Devin reports what's left, not what's used. A quota with a reset time but no percentage is used up:
    /// zero values are left out of the answer.
    static func limits(_ status: [String: Any], id: String) -> AccountLimits {
        let info = status["planInfo"] as? [String: Any]
        var result = AccountLimits(id: id, provider: .devin, plan: (info?["planName"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        let quotas: [(key: String, id: String, label: String, period: TimeInterval)] = [("daily", "daily", "Daily", .day), ("weekly", "weekly", "Weekly", .week)]
        for quota in quotas {
            if quota.id == "daily", info?["hideDailyQuota"] as? Bool == true { continue }
            let reset = JSONValue.date(status[quota.key + "QuotaResetAtUnix"])
            guard let left = JSONValue.number(status[quota.key + "QuotaRemainingPercent"]) ?? (reset != nil ? 0 : nil) else { continue }
            result.meters.append(.percent(quota.id, quota.label, used: 100 - left, resetsAt: reset, period: quota.period))
        }
        if let micros = JSONValue.number(status["overageBalanceMicros"]) {
            result.notes.append(LimitNote(id: "extra", label: "Extra usage balance", value: Format.dollars(max(0, micros) / 1_000_000)))
        }
        if !result.hasValues {
            return .failed(id, .devin, plan: result.plan, "Devin's usage API sent no limits the app knows.")
        }
        return result
    }

    static func credentials(home: URL = .home, configured: [String] = EnvironmentFolders.seen("XDG_DATA_HOME")) -> (key: String, server: String)? {
        let defaultServer = "https://server.codeium.com"
        let folders = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } + [home.appendingPathComponent(".local/share")]
        for folder in folders {
            guard let toml = try? String(contentsOf: folder.appendingPathComponent("devin/credentials.toml"), encoding: .utf8) else { continue }
            var values: [String: String] = [:]
            for line in toml.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
                values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            if let key = values["windsurf_api_key"], !key.isEmpty {
                let server = values["api_server_url"].flatMap { $0.hasPrefix("https://") ? String($0.trimmingSuffix("/")) : nil }
                return (key, server ?? defaultServer)
            }
        }
        let app = home.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
        guard let reader = SQLiteReader(path: app.path) else { return nil }
        var key: String?
        reader.rows("SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1") { row in
            key = JSONValue.object(row.text(0).map { Data($0.utf8) })?["apiKey"] as? String
        }
        return key.map { ($0, defaultServer) }
    }
}

extension String {
    func trimmingSuffix(_ suffix: Character) -> Substring {
        var trimmed = self[...]
        while trimmed.last == suffix { trimmed = trimmed.dropLast() }
        return trimmed
    }
}
