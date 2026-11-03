import Foundation
import Testing
@testable import UsageCore

/// The plan limits of the cards that come through Hermes: Nous Portal's usage gauges, Z.AI's Coding Plan
/// quota, and Kimi's ratio pools. The bodies are the shapes the services answered with on this Mac.
struct PlanLimitsTests {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private func close(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.0001 }

    @Test func nousReadsUsageWindowGauges() {
        let body = object(#"""
            {"user":{"email":null,"privy_did":"did:privy:abc"},
             "organisation":{"id":"nas_organisation:13d9","name":"AdityaVG13's account"},
             "subscription":{"plan":"Hermes Super","monthly_credits":0,"current_period_end":"2026-11-30T19:54:41.000Z",
                             "credits_remaining":-0.0689,"rollover_credits":0},
             "purchased_credits_remaining":158.4937286,
             "usage_window":{"gauges":[
               {"id":"day","scope":"all","label":"Today","used_bp":1127,"resets_at_ms":1793758387382},
               {"id":"week","scope":"all","label":"This week","used_bp":1380,"resets_at_ms":1793999647509},
               {"id":"month","scope":"all","label":"This month","used_bp":460,"resets_at_ms":1796068481000},
               {"id":"top_tier","scope":"top_tier","label":"Large models (monthly)","used_bp":108,"resets_at_ms":1796068481000}],
              "keep_going_on_credits":false}}
            """#)
        let account = NousLimits.limits(body, fallbackID: "nous:fallback")
        #expect(account.id == "nous:nas_organisation:13d9")
        #expect(account.account == "AdityaVG13's account")
        #expect(account.plan == "Hermes Super")
        #expect(account.meters.map(\.id) == ["day", "week", "month", "top-tier"])
        #expect(account.meters.map(\.label) == ["Today", "This week", "This month", "Large models (monthly)"])
        #expect(zip(account.meters.map(\.used), [11.27, 13.8, 4.6, 1.08]).allSatisfy { close($0.0, $0.1) })
        #expect(account.meters[0].period == TimeInterval.day)
        #expect(account.meters[1].period == 7 * TimeInterval.day)
        #expect(account.meters[3].period == 30 * TimeInterval.day)
        #expect(abs((account.meters[0].resetsAt?.timeIntervalSince1970 ?? 0) - 1_793_758_387.382) < 0.001)
        #expect(account.notes.map(\.id) == ["topup", "keep-going"])
        #expect(account.notes[0].value == "$158")
        #expect(account.notes[1].value == "Off")
        #expect(account.problem == nil)

        // An older credit plan: the monthly grant and what's left of it, with no gauges.
        let credits = NousLimits.limits(object(#"""
            {"organisation":{"id":"org","name":"Work"},
             "subscription":{"plan":"Pro","monthly_credits":100,"credits_remaining":40,"current_period_end":"2026-11-30T19:54:41.000Z"}}
            """#), fallbackID: "nous:fallback")
        #expect(credits.meters.map(\.id) == ["monthly"])
        #expect(close(credits.meters[0].used, 60))
        #expect(credits.meters[0].period == 30 * TimeInterval.day)
    }

    @Test func nousKeepsTheBearerTokenOnThePortal() {
        #expect(NousLimits.portal("https://portal.nousresearch.com") == URL(string: "https://portal.nousresearch.com"))
        #expect(NousLimits.portal("https://preview.nousresearch.com/") == URL(string: "https://preview.nousresearch.com/"))
        #expect(NousLimits.portal("https://evil.example") == URL(string: "https://portal.nousresearch.com"))
        #expect(NousLimits.portal("http://portal.nousresearch.com") == URL(string: "https://portal.nousresearch.com"))
        #expect(NousLimits.portal(nil) == URL(string: "https://portal.nousresearch.com"))
    }

    @Test func zaiReadsCodingPlanWindows() {
        let root = object(#"""
            {"code":200,"msg":"Operation successful","data":{"level":"max","limits":[
              {"type":"TIME_LIMIT","unit":5,"number":1,"usage":4000,"currentValue":0,"remaining":4000,
               "percentage":0,"nextResetTime":1794109173998},
              {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17,"nextResetTime":1793749996842},
              {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":21,"nextResetTime":1794106773999}]},"success":true}
            """#)
        let account = ZaiLimits.limits(root, id: "zai:key", account: "Coding Plan")
        #expect(account.plan == "Max")
        #expect(account.meters.map(\.id) == ["mcp", "5-hour", "weekly"])
        #expect(account.meters.map(\.label) == ["MCP tools", "5-hour", "Weekly"])
        #expect(account.meters.map(\.used) == [0, 17, 21])
        #expect(account.meters[0].period == 30 * TimeInterval.day)
        #expect(account.meters[1].period == 5 * TimeInterval.hour)
        #expect(account.meters[2].period == 7 * TimeInterval.day)
        #expect(account.notes == [LimitNote(id: "mcp-left", label: "MCP tools left", value: "4,000 of 4,000")])
    }

    @Test func zaiWithoutACodingPlanSaysSo() async {
        let login = ZaiLimits.Login(token: "key", label: nil, base: URL(string: "https://api.z.ai")!, team: nil)
        let body = Data(#"{"success":false,"code":500,"msg":"当前用户不存在coding plan"}"#.utf8)
        let account = await HTTP.$transport.withValue({ _ in HTTP.Response(status: 200, headers: [:], data: body) }) {
            await ZaiLimits.limits(login)
        }
        #expect(account.problem == "No coding plan is on this key.")
        #expect(!account.hasValues)
    }

    @Test func zaiKeySourcesKeepOneReadingPerPlan() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("swiftusage-zai-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ relative: String, _ text: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        // Hermes's key names the plan its agents use; CodexBar's own key for the same plan isn't read twice.
        try write(".hermes/.env", "GLM_API_KEY=hermes-key\n")
        try write(".codexbar/config.json", #"{"providers":[{"id":"zai","region":"global","tokenAccounts":{"accounts":[{"label":"Coding Plan","token":"codexbar-key"}]}}]}"#)
        let hermes = ZaiLimits.logins(home: home, environment: [:])
        #expect(hermes.map(\.token) == ["hermes-key"])
        #expect(hermes.map(\.base.absoluteString) == ["https://api.z.ai"])

        // Without Hermes's key CodexBar's accounts are read, each labeled, teams with their headers.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".hermes/.env"))
        try write(".codexbar/config.json", #"{"providers":[{"id":"zai","region":"bigmodel-cn","tokenAccounts":{"accounts":[{"label":"Personal","token":"personal"},{"label":"Team","token":"team","usageScope":"team","organizationId":"org_1","workspaceID":"proj_1"}]}}]}"#)
        let accounts = ZaiLimits.logins(home: home, environment: [:])
        #expect(accounts.map(\.token) == ["personal", "team"])
        #expect(accounts.map(\.label) == ["Personal", "Team"])
        #expect(accounts.map(\.base.absoluteString) == ["https://open.bigmodel.cn", "https://open.bigmodel.cn"])
        #expect(accounts[1].team == ZaiLimits.Team(organization: "org_1", project: "proj_1"))
    }

    @Test func kimiReadsRatioPools() {
        let body = object(#"""
            {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                        "detail":{"limit":"100","used":"14","remaining":"86","resetTime":"2026-11-03T23:17:35.372739Z"}}],
             "usages":{"limit_5h":{"used_ratio":0.144,"reset_time":"2026-11-03T23:17:34Z"},
                       "limit_month_total":{"used_ratio":0.064,"reset_time":"2026-11-24T00:00:00Z"},
                       "limit_month_code":{"used_ratio":0.0515,"reset_time":"2026-11-24T00:00:00Z"}}}
            """#)
        let account = KimiLimits.limits(body, id: "kimi:key", account: nil)
        #expect(account.meters.map(\.id) == ["5-hour", "month"])
        #expect(zip(account.meters.map(\.used), [14.4, 6.4]).allSatisfy { close($0.0, $0.1) })
        #expect(account.meters[0].period == 5 * TimeInterval.hour)
        #expect(account.meters[1].period == 30 * TimeInterval.day)
        #expect(account.notes == [LimitNote(id: "code-share", label: "Code this month", value: "5.2% of the month")])

        // A plan that reports only request counts still shows its 5-hour window.
        let counts = KimiLimits.limits(object(#"""
            {"limits":[{"window":{"duration":300},"detail":{"limit":"100","used":"14","resetTime":"2026-11-03T23:17:35Z"}}]}
            """#), id: "kimi:key", account: nil)
        #expect(counts.meters.map(\.id) == ["5-hour"])
        #expect(counts.meters[0].unit == .count)
        #expect(counts.meters[0].used == 14)
        #expect(counts.meters[0].limit == 100)
    }

    @Test func kimiPrefersTheApiKeyOverTheShortLivedLogin() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("swiftusage-kimi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ relative: String, _ text: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(".hermes/.env", "KIMI_API_KEY=key-123\n")
        try write(".kimi-code/credentials/kimi-code.json", #"{"access_token":"cli-token","expires_at":1793736848}"#)
        let key = KimiLimits.logins(home: home, environment: [:])
        #expect(key.map(\.token) == ["key-123"])
        #expect(key.map(\.kind) == [.apiKey])

        // Without the key the CLI's login is read, from the host its config names.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".hermes/.env"))
        try write(".kimi-code/config.toml", "base_url = \"https://api.kimi.ai/coding/v1\"\n")
        let cli = KimiLimits.logins(home: home, environment: [:])
        #expect(cli.map(\.token) == ["cli-token"])
        #expect(cli.map(\.kind) == [.cli])
        #expect(cli.first?.base.absoluteString == "https://api.kimi.ai")
    }

    @Test func everyPlanThatComesThroughHermesReadsItsLimits() {
        let providers = Set(LimitsSources.all().map(\.provider))
        #expect(providers.isSuperset(of: [.nous, .zai, .kimi]))
    }
}
