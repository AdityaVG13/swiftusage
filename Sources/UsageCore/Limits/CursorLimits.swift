import Foundation

/// Cursor's included usage for the billing period, signed in with the login the Cursor app keeps in its
/// `state.vscdb`.
public struct CursorLimits: LimitsSource {
    public let provider = Provider.cursor
    private static let api = "https://api2.cursor.sh/aiserver.v1.DashboardService/"
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    public init() {}

    struct Login: Equatable {
        enum Source: Equatable {
            case ide, cli
        }

        var source: Source
        var access: String?
        var refresh: String?
        var email: String?
        var membership: String?

        var subject: String? {
            [access, refresh].compactMap(CursorLimits.subject).first
        }

        var id: String { "cursor:" + (subject ?? "default") }
    }

    public func fetch() async -> [AccountLimits] {
        await fetch(home: .home)
    }

    func fetch(home: URL = .home, keychain: @Sendable (Keychain.Item) -> Keychain.Reading = Keychain.password) async -> [AccountLimits] {
        let (logins, waitingOn) = Self.logins(home: home, keychain: keychain)
        var results = LimitsSources.merged(await LimitsSources.readings(of: logins, id: \.id) { login in
            await limits(for: login)
        })
        if let item = waitingOn {
            let id = "cursor:keychain"
            Keychain.wait(id, on: item)
            results.append(AccountLimits(id: id, provider: provider,
                                         problem: "To see these limits, allow access to Cursor's login and choose Always Allow.",
                                         action: .allowKeychain))
        }
        return results
    }

    static func logins(home: URL = .home, keychain: (Keychain.Item) -> Keychain.Reading = Keychain.password) -> (logins: [Login], waitingOn: Keychain.Item?) {
        var logins: [Login] = []
        let state = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        if let reader = SQLiteReader(path: state.path) {
            var values: [String: String] = [:]
            reader.rows("SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/refreshToken', 'cursorAuth/cachedEmail', 'cursorAuth/stripeMembershipType')") { row in
                if let key = row.text(0), let value = Self.trimmed(row.text(1)) { values[key] = value }
            }
            if values["cursorAuth/accessToken"] != nil || values["cursorAuth/refreshToken"] != nil {
                logins.append(Login(source: .ide, access: values["cursorAuth/accessToken"], refresh: values["cursorAuth/refreshToken"],
                                    email: values["cursorAuth/cachedEmail"], membership: values["cursorAuth/stripeMembershipType"]))
            }
        }

        var waitingOn: Keychain.Item?
        if let auth = JSONValue.object(file: home.appendingPathComponent(".cursor/auth.json")) {
            let access = Self.trimmed((auth["accessToken"] ?? auth["access_token"]) as? String)
            let refresh = Self.trimmed((auth["refreshToken"] ?? auth["refresh_token"]) as? String)
            let email = Self.trimmed(auth["email"] as? String)
            if access != nil || refresh != nil {
                logins.append(Login(source: .cli, access: access, refresh: refresh, email: email))
            }
        }
        if !logins.contains(where: { $0.source == .cli }) {
            let accessItem = Keychain.Item(service: "cursor-access-token")
            let refreshItem = Keychain.Item(service: "cursor-refresh-token")
            var access: String?
            var refresh: String?
            switch keychain(accessItem) {
            case .password(let raw): access = Self.trimmed(raw)
            case .needsPermission: waitingOn = accessItem
            case .missing: break
            }
            if waitingOn == nil {
                switch keychain(refreshItem) {
                case .password(let raw): refresh = Self.trimmed(raw)
                case .needsPermission: if access == nil { waitingOn = refreshItem }
                case .missing: break
                }
            }
            if access != nil || refresh != nil {
                logins.append(Login(source: .cli, access: access, refresh: refresh))
            }
        }
        return (logins, waitingOn)
    }

    private func limits(for login: Login) async -> AccountLimits {
        let email = login.email
        let renewHint = login.source == .ide ? "Open Cursor to renew it." : "Run `agent login` to renew it."
        var token = login.access
        let needsRefresh = token == nil || (token.flatMap(JWT.expiry).map { $0 <= HTTP.now().addingTimeInterval(5 * 60) } ?? false)
        var renewed = false
        if needsRefresh, let refresh = login.refresh {
            renewed = true
            if let refreshed = await Self.renew(refresh) { token = refreshed }
        }
        let id = "cursor:" + (Self.subject(token) ?? login.subject ?? "default")
        guard var token else {
            return .failed(id, provider, account: email, "Login expired. \(renewHint)")
        }
        if let expiry = JWT.expiry(token), expiry < HTTP.now() {
            return .failed(id, provider, account: email, "Login expired. \(renewHint)")
        }

        var (planResponse, usageResponse) = await Self.query(token: token)
        if usageResponse?.status == 401, !renewed, let refresh = login.refresh, let refreshed = await Self.renew(refresh) {
            token = refreshed
            (planResponse, usageResponse) = await Self.query(token: token)
        }
        let planInfo = planResponse?.json?["planInfo"] as? [String: Any]
        let plan = (planInfo?["planName"] as? String) ?? login.membership?.replacingOccurrences(of: "unified_", with: "").titleCased

        guard let usageResponse else { return .failed(id, provider, account: email, plan: plan, "Couldn't reach Cursor.") }
        switch usageResponse.status {
        case 200..<300: break
        case 401, 403: return .failed(id, provider, account: email, plan: plan, "Login expired. \(renewHint)")
        default: return .failed(id, provider, account: email, plan: plan, "Cursor's usage API answered HTTP \(usageResponse.status).")
        }
        guard let usage = usageResponse.json else { return .failed(id, provider, account: email, plan: plan, "Cursor's usage API sent something unexpected.") }
        var result = Self.limits(usage, planInfo: planInfo, id: id, account: email, plan: plan)
        if !result.meters.contains(where: { $0.id == "total" || $0.id == "auto" }) {
            // Team and enterprise plans report through the dashboard's own endpoints instead.
            let user = Self.subject(token).map { $0.split(separator: "|").last.map(String.init) ?? $0 } ?? ""
            let cookie = ["Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(token)", "Accept": "application/json"]
            async let summary = HTTP.get("https://cursor.com/api/usage-summary", headers: cookie)
            let requests = await HTTP.get("https://cursor.com/api/usage?user=" + (user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user), headers: cookie)
            let dashboard = Self.dashboard(summary: await summary?.json, requests: requests?.json)
            if dashboard.hasValues {
                let overage = result.meters.first { $0.id == "on-demand" }
                result.meters = dashboard.meters.filter { $0.id != "on-demand" }
                    + (overage.map { [$0] } ?? dashboard.meters.filter { $0.id == "on-demand" })
                if overage != nil {
                    result.notes = dashboard.notes.filter { $0.id != "on-demand" }
                } else if result.notes.isEmpty {
                    result.notes = dashboard.notes
                }
                result.problem = nil
            }
        }
        return result
    }

    private static func query(token: String) async -> (plan: HTTP.Response?, usage: HTTP.Response?) {
        let headers = ["Authorization": "Bearer " + token, "Connect-Protocol-Version": "1"]
        async let planResponse = HTTP.post(api + "GetPlanInfo", headers: headers, json: [String: Any](), timeout: 20)
        let usageResponse = await HTTP.post(api + "GetCurrentPeriodUsage", headers: headers, json: [String: Any](), timeout: 20)
        return (await planResponse, usageResponse)
    }

    private static func renew(_ refresh: String) async -> String? {
        let body: [String: Any] = ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refresh]
        guard let response = await HTTP.post("https://api2.cursor.sh/oauth/token", json: body),
              response.ok, response.json?["shouldLogout"] as? Bool != true,
              let token = trimmed(response.json?["access_token"] as? String)
        else { return nil }
        return token
    }

    private static func subject(_ token: String?) -> String? {
        guard let token else { return nil }
        return trimmed(JWT.claims(token)?["sub"] as? String)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
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
            // Cursor's months are Gregorian, whatever calendar this Mac uses.
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = .gmt
            let reset = monthStart.flatMap { gregorian.date(byAdding: .month, value: 1, to: $0) } ?? end
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
            let individualLimit = JSONValue.number(onDemand["individualLimit"])
            let pooledLimit = JSONValue.number(onDemand["pooledLimit"])
            let individualUsed = JSONValue.number(onDemand["individualUsed"])
            let pooledUsed = JSONValue.number(onDemand["pooledUsed"])
            let totalSpend = JSONValue.number(onDemand["totalSpend"])
            let scope: (limit: Double, used: Double)? = if let individualLimit, individualLimit > 0 {
                (individualLimit, individualUsed ?? totalSpend ?? 0)
            } else if let pooledLimit, pooledLimit > 0 {
                (pooledLimit, pooledUsed ?? totalSpend ?? 0)
            } else {
                nil
            }
            if let scope {
                result.meters.append(LimitMeter(id: "on-demand", label: "On-demand", used: scope.used / 100, limit: scope.limit / 100, unit: .dollars,
                                                resetsAt: end, period: start.flatMap { start in end.map { $0.timeIntervalSince(start) } }))
            } else if let spent = individualUsed ?? pooledUsed ?? totalSpend, spent > 0 {
                result.notes.append(LimitNote(id: "on-demand", label: "On-demand", value: Format.dollars(spent / 100) + " spent"))
            }
        }
        if !result.hasValues {
            result.problem = "Cursor didn't report included usage for this plan."
        }
        return result
    }
}
