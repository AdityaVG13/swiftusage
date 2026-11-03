import Foundation

/// Z.AI's GLM Coding Plan limits, read with the plan's API key: the one Hermes keeps in `~/.hermes/.env`
/// (the key the agents on this Mac bill with), else the accounts CodexBar keeps in its config, else a key
/// in the environment. One key per account is read: another tool's key for the same plan would report the
/// same windows a second time.
public struct ZaiLimits: LimitsSource {
    public let provider = Provider.zai
    private static let global = URL(string: "https://api.z.ai")!
    private static let china = URL(string: "https://open.bigmodel.cn")!

    public init() {}

    public func fetch() async -> [AccountLimits] {
        await fetch(home: .home, environment: ProcessInfo.processInfo.environment)
    }

    func fetch(home: URL, environment: [String: String]) async -> [AccountLimits] {
        await LimitsSources.readings(of: Self.logins(home: home, environment: environment), id: \.id) { login in
            await Self.limits(login)
        }
    }

    struct Team: Equatable, Sendable {
        var organization: String
        var project: String
    }

    struct Login: Equatable, Sendable {
        var token: String
        /// The account's name in CodexBar's config, when it has one.
        var label: String?
        var base: URL
        /// CodexBar's team accounts are read with the organization and project headers, and `type=2`.
        var team: Team?
        var id: String { "zai:" + token.sha256Prefix }
    }

    static func logins(home: URL, environment: [String: String]) -> [Login] {
        let dotenv = environmentFile(home.appendingPathComponent(".hermes/.env"))
        // Hermes's key names the plan its agents use; a second key for the same plan would read the same
        // windows again, so the other sources are only asked when Hermes has none.
        for name in ["ZAI_API_KEY", "Z_AI_API_KEY", "GLM_API_KEY", "BIGMODEL_API_KEY"] {
            guard let token = dotenv[name] ?? environment[name], !token.isEmpty else { continue }
            return [Login(token: token, label: nil, base: name == "BIGMODEL_API_KEY" ? china : global, team: nil)]
        }

        var logins: [Login] = []
        for path in [".config/codexbar/config.json", ".codexbar/config.json"] {
            guard let config = JSONValue.object(file: home.appendingPathComponent(path)),
                  let providers = config["providers"] as? [[String: Any]] else { continue }
            for provider in providers where provider["id"] as? String == "zai" {
                let base = provider["region"] as? String == "bigmodel-cn" ? china : global
                if let key = provider["apiKey"] as? String, !key.isEmpty {
                    logins.append(Login(token: key, label: nil, base: base, team: nil))
                }
                let accounts = (provider["tokenAccounts"] as? [String: Any])?["accounts"] as? [[String: Any]] ?? []
                for account in accounts {
                    guard let token = account["token"] as? String, !token.isEmpty else { continue }
                    var team: Team?
                    if account["usageScope"] as? String == "team",
                       let organization = account["organizationId"] as? String, !organization.isEmpty,
                       let project = account["workspaceID"] as? String, !project.isEmpty {
                        team = Team(organization: organization, project: project)
                    }
                    logins.append(Login(token: token, label: account["label"] as? String, base: base, team: team))
                }
            }
        }
        if !logins.isEmpty {
            var seen: Set<String> = []
            return logins.filter { seen.insert($0.token).inserted }
        }
        for name in ["Z_AI_API_KEY", "ZAI_API_KEY"] {
            guard let token = environment[name], !token.isEmpty else { continue }
            return [Login(token: token, label: nil, base: global, team: nil)]
        }
        return []
    }

    static func limits(_ login: Login) async -> AccountLimits {
        var url = login.base.absoluteString + "/api/monitor/usage/quota/limit"
        if login.team != nil { url += "?type=2" }
        var headers = ["Authorization": "Bearer " + login.token, "Accept": "application/json"]
        if let team = login.team {
            headers["Bigmodel-Organization"] = team.organization
            headers["Bigmodel-Project"] = team.project
        }
        guard let response = await HTTP.get(url, headers: headers) else {
            return .failed(login.id, .zai, account: login.label, "Couldn't reach Z.AI.")
        }
        switch response.status {
        case 200..<300: break
        case 401, 403: return .failed(login.id, .zai, account: login.label, "Z.AI rejected this API key.")
        case 429: return .failed(login.id, .zai, account: login.label, "Z.AI is limiting requests. Try again in a little while.")
        case 500...: return .failed(login.id, .zai, account: login.label, "Z.AI's usage service is unavailable right now.")
        default: return .failed(login.id, .zai, account: login.label, "Z.AI's usage API answered HTTP \(response.status).")
        }
        guard let root = response.json else {
            return .failed(login.id, .zai, account: login.label, "Z.AI's usage API sent something unexpected.")
        }
        if root["success"] as? Bool == false {
            let message = root["msg"] as? String ?? ""
            if message.localizedCaseInsensitiveContains("coding plan") {
                return .failed(login.id, .zai, account: login.label, "No coding plan is on this key.")
            }
            return .failed(login.id, .zai, account: login.label, message.isEmpty ? "Z.AI's usage API reported an error." : "Z.AI's usage API said: \(message)")
        }
        return limits(root, id: login.id, account: login.label)
    }

    /// One answer from `GET /api/monitor/usage/quota/limit`: the Coding Plan's 5-hour and weekly token
    /// windows, the monthly MCP allowance, and any credit window, in the order the plan lists them.
    static func limits(_ root: [String: Any], id: String, account: String?) -> AccountLimits {
        guard let data = root["data"] as? [String: Any], let limits = data["limits"] as? [[String: Any]] else {
            return .failed(id, .zai, account: account, "Z.AI's usage API sent something unexpected.")
        }
        var result = AccountLimits(id: id, provider: .zai, account: account, plan: (data["level"] as? String)?.titleCased)
        for limit in limits {
            guard let read = meter(limit) else { continue }
            result.meters.append(read.meter)
            if let note = read.note { result.notes.append(note) }
        }
        if !result.hasValues {
            result.problem = "No coding plan is on this key."
        }
        return result
    }

    static func meter(_ limit: [String: Any]) -> (meter: LimitMeter, note: LimitNote?)? {
        let type = limit["type"] as? String ?? ""
        guard ["TOKENS_LIMIT", "TIME_LIMIT", "CREDIT_LIMIT"].contains(type) else { return nil }
        let unit = Int(saturating: JSONValue.number(limit["unit"]) ?? -1)
        let number = Int(saturating: JSONValue.number(limit["number"]) ?? 0)
        let multipliers: [Int: Double] = [1: 1440, 3: 60, 5: 1, 6: 10080]
        let minutes = number > 0 ? multipliers[unit].map { Double(number) * $0 } : nil
        let period = minutes.map { $0 * 60 }
        let resetsAt = JSONValue.date(limit["nextResetTime"])

        var percent = JSONValue.number(limit["percentage"]) ?? 0
        let usage = JSONValue.number(limit["usage"])
        let current = JSONValue.number(limit["currentValue"])
        let remaining = JSONValue.number(limit["remaining"])
        if let usage, usage > 0 {
            if let remaining {
                percent = max(usage - remaining, current ?? usage - remaining) / usage * 100
            } else if let current {
                percent = current / usage * 100
            }
        }
        percent = min(max(percent, 0), 100)

        let name: String
        let id: String
        switch type {
        case "TIME_LIMIT" where unit == 5 && number == 1:
            name = "MCP tools"
            id = "mcp"
        case "TOKENS_LIMIT" where minutes == 300:
            name = "5-hour"
            id = "5-hour"
        case "TOKENS_LIMIT" where minutes == 10_080:
            name = "Weekly"
            id = "weekly"
        case "CREDIT_LIMIT":
            name = "Credits"
            id = "credits"
        default:
            let units: [Int: String] = [1: "day", 3: "hour", 5: "minute", 6: "week"]
            if let unitName = units[unit], number > 0 {
                name = "\(number) \(unitName)\(number == 1 ? "" : "s")"
                id = "window-\(minutes.map { Int($0) } ?? number)"
            } else {
                name = type.titleCased.replacingOccurrences(of: " Limit", with: "")
                id = type.lowercased()
            }
        }
        let window = type == "TIME_LIMIT" && unit == 5 && number == 1 ? 30 * .day : period
        var note: LimitNote?
        if type == "TIME_LIMIT", let usage, let remaining {
            note = LimitNote(id: "mcp-left", label: "MCP tools left", value: "\(Format.grouped(Int(saturating: remaining))) of \(Format.grouped(Int(saturating: usage)))")
        }
        return (.percent(id, name, used: percent, resetsAt: resetsAt, period: window), note)
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
