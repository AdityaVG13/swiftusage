import Foundation

/// Cursor's included usage for the billing period, signed in with the login the Cursor app keeps in its
/// `state.vscdb`.
public struct CursorLimits: LimitsSource {
    public let provider = Provider.cursor
    private static let api = "https://api2.cursor.sh/aiserver.v1.DashboardService/"

    public init() {}

    public func fetch() async -> [AccountLimits] {
        let state = URL.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let reader = SQLiteReader(path: state.path) else { return [] }
        var values: [String: String] = [:]
        reader.rows("SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/cachedEmail', 'cursorAuth/stripeMembershipType')") { row in
            if let key = row.text(0), let value = row.text(1) { values[key] = value }
        }
        guard let token = values["cursorAuth/accessToken"], !token.isEmpty else { return [] }
        let email = values["cursorAuth/cachedEmail"]
        let id = "cursor:" + ((JWT.claims(token)?["sub"] as? String) ?? "default")
        if let expiry = JWT.expiry(token), expiry < Date() {
            return [.failed(id, provider, account: email, "Login expired. Open Cursor to renew it.")]
        }

        let headers = ["Authorization": "Bearer " + token, "Connect-Protocol-Version": "1"]
        async let planResponse = HTTP.post(Self.api + "GetPlanInfo", headers: headers, json: [String: Any](), timeout: 20)
        let usageResponse = await HTTP.post(Self.api + "GetCurrentPeriodUsage", headers: headers, json: [String: Any](), timeout: 20)
        let planInfo = await planResponse?.json?["planInfo"] as? [String: Any]
        let plan = (planInfo?["planName"] as? String) ?? values["cursorAuth/stripeMembershipType"]?.replacingOccurrences(of: "unified_", with: "").titleCased

        guard let usageResponse else { return [.failed(id, provider, account: email, plan: plan, "Couldn't reach Cursor.")] }
        switch usageResponse.status {
        case 200..<300: break
        case 401, 403: return [.failed(id, provider, account: email, plan: plan, "Login expired. Open Cursor to renew it.")]
        default: return [.failed(id, provider, account: email, plan: plan, "Cursor's usage API answered HTTP \(usageResponse.status).")]
        }
        guard let usage = usageResponse.json else { return [.failed(id, provider, account: email, plan: plan, "Cursor's usage API sent something unexpected.")] }
        var result = Self.limits(usage, planInfo: planInfo, id: id, account: email, plan: plan)
        if !result.hasValues {
            // Team and enterprise plans report through the dashboard's own endpoints instead.
            let user = (JWT.claims(token)?["sub"] as? String).map { $0.split(separator: "|").last.map(String.init) ?? $0 } ?? ""
            let cookie = ["Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(token)", "Accept": "application/json"]
            async let summary = HTTP.get("https://cursor.com/api/usage-summary", headers: cookie)
            let requests = await HTTP.get("https://cursor.com/api/usage?user=" + (user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user), headers: cookie)
            let dashboard = Self.dashboard(summary: await summary?.json, requests: requests?.json)
            if dashboard.hasValues {
                result.meters = dashboard.meters
                result.notes = dashboard.notes
                result.problem = nil
            }
        }
        return [result]
    }

    /// The dashboard's view for team and enterprise plans: requests used of the month's allowance, the
    /// included usage's percentages, and on-demand spend, in cents, from the person's own budget before
    /// the team's.
    static func dashboard(summary: [String: Any]?, requests: [String: Any]?) -> AccountLimits {
        var result = AccountLimits(id: "", provider: .cursor)
        let end = JSONValue.date(summary?["billingCycleEnd"])
        let start = JSONValue.date(summary?["billingCycleStart"])
        let period = start.flatMap { start in end.map { $0.timeIntervalSince(start) } }
        if let plan = summary?[path: "individualUsage", "plan"] as? [String: Any] {
            if let total = JSONValue.number(plan["totalPercentUsed"]) {
                result.meters.append(.percent("total", "Included usage", used: total, resetsAt: end, period: period))
            }
            if let auto = JSONValue.number(plan["autoPercentUsed"]), let api = JSONValue.number(plan["apiPercentUsed"]), auto + api > 0 {
                result.meters.append(.percent("auto", "Cursor models", used: auto, resetsAt: end, period: period))
                result.meters.append(.percent("api", "Other models", used: api, resetsAt: end, period: period))
            }
        }
        if let model = requests?["gpt-4"] as? [String: Any], let allowance = JSONValue.number(model["maxRequestUsage"]), allowance > 0 {
            let used = max(JSONValue.number(model["numRequests"]) ?? 0, JSONValue.number(model["numRequestsTotal"]) ?? 0)
            let monthStart = JSONValue.date(requests?["startOfMonth"])
            let reset = monthStart.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) } ?? end
            result.meters.append(LimitMeter(id: "requests", label: "Requests", used: used, limit: allowance, unit: .count, resetsAt: reset, period: period))
        }
        let budgets = [summary?[path: "individualUsage", "onDemand"], summary?[path: "teamUsage", "onDemand"]].compactMap { $0 as? [String: Any] }
        if let budget = budgets.first(where: { $0["enabled"] as? Bool != false && (JSONValue.number($0["limit"]) ?? 0) > 0 }) {
            let limit = JSONValue.number(budget["limit"]) ?? 0
            let used = JSONValue.number(budget["used"]).flatMap { $0 > 0 ? $0 : nil } ?? max(0, limit - (JSONValue.number(budget["remaining"]) ?? limit))
            result.meters.append(LimitMeter(id: "on-demand", label: "On-demand", used: used / 100, limit: limit / 100, unit: .dollars, resetsAt: end, period: period))
        } else if let spent = budgets.compactMap({ JSONValue.number($0["used"]) }).first(where: { $0 > 0 }) {
            result.notes.append(LimitNote(id: "on-demand", label: "On-demand", value: Format.dollars(spent / 100) + " spent"))
        }
        return result
    }

    /// Money is in cents. The period is the billing month, or a week on plans whose included usage resets
    /// weekly.
    static func limits(_ usage: [String: Any], planInfo: [String: Any]?, id: String, account: String?, plan: String?) -> AccountLimits {
        var result = AccountLimits(id: id, provider: .cursor, account: account, plan: plan)
        let start = JSONValue.date(usage["billingCycleStart"]), end = JSONValue.date(usage["billingCycleEnd"])
        var reset = end
        var period = start.flatMap { start in end.map { $0.timeIntervalSince(start) } }
        if planInfo?["includedUsagePeriod"] as? String == "INCLUDED_USAGE_PERIOD_WEEKLY" {
            reset = JSONValue.date(planInfo?["includedUsageResetsAt"]) ?? reset
            period = .week
        }

        if let planUsage = usage["planUsage"] as? [String: Any] {
            let limit = JSONValue.number(planUsage["limit"])
            let spent = JSONValue.number(planUsage["totalSpend"]) ?? limit.flatMap { limit in JSONValue.number(planUsage["remaining"]).map { limit - $0 } }
            if let percent = JSONValue.number(planUsage["totalPercentUsed"]) ?? spent.flatMap({ spent in limit.flatMap { $0 > 0 ? spent / $0 * 100 : nil } }) {
                result.meters.append(.percent("total", "Included usage", used: percent, resetsAt: reset, period: period))
            }
            if let auto = JSONValue.number(planUsage["autoPercentUsed"]), let api = JSONValue.number(planUsage["apiPercentUsed"]), auto + api > 0 {
                result.meters.append(.percent("auto", "Cursor models", used: auto, resetsAt: reset, period: period))
                result.meters.append(.percent("api", "Other models", used: api, resetsAt: reset, period: period))
            }
        }
        if let onDemand = usage["spendLimitUsage"] as? [String: Any] {
            let limit = JSONValue.number(onDemand["individualLimit"]) ?? JSONValue.number(onDemand["pooledLimit"])
            let used = [onDemand["individualUsed"], onDemand["pooledUsed"], onDemand["totalSpend"]].compactMap(JSONValue.number).first { $0 > 0 } ?? 0
            if let limit, limit > 0 {
                result.meters.append(LimitMeter(id: "on-demand", label: "On-demand", used: used / 100, limit: limit / 100, unit: .dollars,
                                                resetsAt: end, period: start.flatMap { start in end.map { $0.timeIntervalSince(start) } }))
            } else if used > 0 {
                result.notes.append(LimitNote(id: "on-demand", label: "On-demand", value: Format.dollars(used / 100) + " spent"))
            }
        }
        if !result.hasValues {
            result.problem = "Cursor didn't report included usage for this plan."
        }
        return result
    }
}
