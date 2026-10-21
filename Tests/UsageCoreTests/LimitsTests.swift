import CommonCrypto
import Foundation
import SQLite3
import Synchronization
import Testing
@testable import UsageCore

struct LimitsTests {
    let now = Date(timeIntervalSince1970: Timestamp.parse("2026-10-19T16:00:00Z")!)

    /// A source that keeps what it learns about logins in a folder of its own, not the app's.
    static func antigravity() -> AntigravityLimits {
        AntigravityLimits(emailsURL: FileManager.default.temporaryDirectory.appendingPathComponent("swiftusage-tests-\(UUID().uuidString)/antigravity-accounts.json"))
    }

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Providers' answers

    @Test func claudeReadsItsLimitsList() {
        let body = object("""
            {"five_hour":{"utilization":100.0,"resets_at":"2026-10-19T19:10:00.399644+00:00"},
             "seven_day":{"utilization":58.0,"resets_at":"2026-10-23T23:00:00.399669+00:00"},
             "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1234},
             "limits":[
               {"kind":"session","group":"session","percent":100,"resets_at":"2026-10-19T19:10:00.399644+00:00","scope":null},
               {"kind":"weekly_all","group":"weekly","percent":58,"resets_at":"2026-10-23T23:00:00.399669+00:00","scope":null},
               {"kind":"weekly_scoped","group":"weekly","percent":7,"resets_at":"2026-10-23T23:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}}]}
            """)
        let meters = ClaudeLimits.meters(body)
        #expect(meters.map(\.id) == ["session", "weekly", "model-fable"])
        #expect(meters.map(\.label) == ["Session", "Weekly", "Fable"])
        #expect(meters.map(\.used) == [100, 58, 7])
        #expect(meters[0].period == TimeInterval(5 * 3600))
        #expect(meters[2].period == TimeInterval(7 * 86_400))
        #expect(meters[0].resetsAt == Date(timeIntervalSince1970: Timestamp.parse("2026-10-19T19:10:00.399644Z")!))
        #expect(ClaudeLimits.notes(body) == [LimitNote(id: "extra", label: "Extra usage", value: "$12.34 of $50.00")])

        // Answers without the list still have the named windows; a session that hasn't begun has no reset.
        let older = ClaudeLimits.meters(object(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":"12","resets_at":"2026-10-23T23:00:00Z"},"seven_day_opus":null}"#))
        #expect(older.map(\.id) == ["session", "weekly"])
        #expect(older[0].resetsAt == nil)
        #expect(older[1].used == 12)
    }

    @Test func claudePlansAndAccountNames() {
        #expect(ClaudeLimits.plan("claude_max", "default_claude_max_20x") == "Max 20x")
        #expect(ClaudeLimits.plan("claude_team", "default_claude_max_5x") == "Team 5x")
        #expect(ClaudeLimits.plan("pro", "default_claude_ai") == "Pro")
        #expect(ClaudeLimits.plan(nil, "default_claude_max_5x") == nil)
        #expect(ClaudeLimits.label(organization: "someone@example.com's Organization", email: "someone@example.com") == "Personal")
        #expect(ClaudeLimits.label(organization: "Tasteskill", email: "a@b.c") == "Tasteskill")
        #expect(ClaudeLimits.label(organization: nil, email: "a@b.c") == "a@b.c")
    }

    @Test func claudeFindsEveryConfigFolderOnce() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ relative: String, _ json: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: url, atomically: true, encoding: .utf8)
        }
        let future = Int((now.timeIntervalSince1970 + 3600) * 1000)
        try write(".claude.json", #"{"oauthAccount":{"accountUuid":"A1","organizationUuid":"O1","organizationName":"Tasteskill","emailAddress":"k@t.dev"}}"#)
        try write(".claude/projects/.keep", "")
        try write(".claude_personal/.claude.json", #"{"oauthAccount":{"accountUuid":"A2","organizationUuid":"O2","organizationName":"me@x.com's Organization"}}"#)
        // The same account under a third folder shows once.
        try write(".claude-copy/.claude.json", #"{"oauthAccount":{"accountUuid":"A2","organizationUuid":"O2"}}"#)
        try write(".claude-copy/.credentials.json", #"{"claudeAiOauth":{"accessToken":"copy","expiresAt":\#(future)}}"#)
        // A folder without a login is skipped.
        try write(".claude-empty/.claude.json", #"{"oauthAccount":{"accountUuid":"A3"}}"#)

        let personal = "Claude Code-credentials-" + home.appendingPathComponent(".claude_personal").path.sha256Prefix
        let keychain: [String: String] = [
            "Claude Code-credentials": #"{"claudeAiOauth":{"accessToken":"default","expiresAt":\#(future),"scopes":["user:inference","user:profile"],"subscriptionType":"team","rateLimitTier":"default_claude_max_5x"}}"#,
            personal: #"{"claudeAiOauth":{"accessToken":"personal","expiresAt":\#(future),"subscriptionType":"max"}}"#,
        ]
        let logins = ClaudeLimits.logins(home: home, environment: ["USER": "tester"]) { item in keychain[item.service].map(Keychain.Reading.password) ?? .missing }
        #expect(logins.map(\.token) == ["default", "copy", "personal"])
        #expect(logins.map(\.id) == ["claude:a1|o1", "claude:a2|o2", "claude:a2|o2"])
        #expect(logins.first?.account == "Tasteskill")
        #expect(logins.first?.isDefault == true)
        #expect(logins.last?.account == "Personal")

        // Started from a shell that set `CLAUDE_CONFIG_DIR`, the plain default login still shows.
        let custom = ClaudeLimits.logins(home: home, environment: ["USER": "tester", "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude_personal").path]) { item in keychain[item.service].map(Keychain.Reading.password) ?? .missing }
        #expect(custom.map(\.token) == ["personal", "default", "copy"])
        #expect(custom.map(\.isDefault) == [true, false, false])

        // A folder `CLAUDE_CONFIG_DIR` named outside the home folder, opened later without it set.
        let elsewhere = home.appendingPathComponent("work/claude config")
        try write("work/claude config/.claude.json", #"{"oauthAccount":{"accountUuid":"A4","organizationUuid":"O4","organizationName":"Work"}}"#)
        var withWork = keychain
        withWork["Claude Code-credentials-" + elsewhere.path.sha256Prefix] = #"{"claudeAiOauth":{"accessToken":"work","expiresAt":\#(future)}}"#
        let remembered = ClaudeLimits.logins(home: home, environment: ["USER": "tester"], remembered: [elsewhere.path]) { item in withWork[item.service].map(Keychain.Reading.password) ?? .missing }
        #expect(remembered.map(\.token) == ["default", "work", "copy", "personal"])
        #expect(remembered.first?.isDefault == true)

        // A keychain item macOS would ask about isn't read: its folder waits on it, and the items after it
        // aren't tried. A folder whose login is also in a file uses the file.
        var asked: [Keychain.Item] = []
        let waiting = ClaudeLimits.logins(home: home, environment: ["USER": "tester"]) { item in
            asked.append(item)
            return item.service == "Claude Code-credentials" || item.service == personal ? .needsPermission : .missing
        }
        #expect(waiting.map(\.token) == [nil, "copy", nil])
        #expect(waiting.map(\.waitingOn) == [Keychain.Item(service: "Claude Code-credentials", account: "tester"), nil,
                                            Keychain.Item(service: personal, account: "tester")])
        #expect(!asked.contains(Keychain.Item(service: "Claude Code-credentials", account: nil)))
    }

    @Test func codexNamesWindowsByLength() {
        let body = object("""
            {"plan_type":"pro","email":"a@b.c",
             "rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1792440000},
                           "secondary_window":{"used_percent":"20","limit_window_seconds":604800,"reset_after_seconds":3600}},
             "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000}}},
                                       {"limit_name":"Other","rate_limit":{"primary_window":{"used_percent":99}}}],
             "credits":{"has_credits":true,"balance":"250"},
             "rate_limit_reset_credits":{"available_count":2}}
            """)
        let limits = CodexLimits.limits(body, id: "codex:x", account: "a@b.c")
        #expect(limits.plan == "Pro")
        #expect(limits.meters.map(\.id) == ["session", "weekly", "spark-session"])
        #expect(limits.meters.map(\.label) == ["Session", "Weekly", "Spark Session"])
        #expect(limits.meters[0].resetsAt == Date(timeIntervalSince1970: 1_792_440_000))
        #expect(limits.notes.map(\.value) == ["250"])
        #expect(limits.resets == LimitResets(available: 2, refills: ["session", "weekly"]))
        // Free plans have one 30-day window.
        let free = CodexLimits.limits(object(#"{"plan_type":"free","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":2592000,"reset_at":1795016862},"secondary_window":null}}"#), id: "c", account: nil)
        #expect(free.meters.map(\.label) == ["Monthly"])
        #expect(CodexLimits.plan("team_plus") == "Team Plus")
    }

    @Test func outOfRangeNumericResetDatesAreIgnored() {
        #expect(JSONValue.date(1_792_440_000) == Date(timeIntervalSince1970: 1_792_440_000))
        #expect(JSONValue.date(1_792_440_000_000) == Date(timeIntervalSince1970: 1_792_440_000))
        #expect(JSONValue.date(1e24) == nil)
        let codex = CodexLimits.limits([
            "rate_limit": [
                "primary_window": ["used_percent": 25, "reset_at": 1e24],
                "secondary_window": ["used_percent": 50, "reset_after_seconds": 1e24],
            ],
        ], id: "codex:x", account: nil)
        #expect(codex.meters.map(\.resetsAt) == [nil, nil])
    }

    @Test func fractionalCodexCreditsAreNotTruncated() {
        let result = CodexLimits.limits(["credits": ["has_credits": true, "balance": "0.75"]], id: "codex:fixture", account: nil)
        #expect(result.notes.first?.value == "0.75")
    }

    @Test func devinReportsWhatsLeft() {
        let status = object("""
            {"planInfo":{"planName":"Max","hideDailyQuota":true},"dailyQuotaRemainingPercent":100,"weeklyQuotaRemainingPercent":94,
             "overageBalanceMicros":"-1114817","dailyQuotaResetAtUnix":"1792483200","weeklyQuotaResetAtUnix":"1792915200"}
            """)
        let limits = DevinLimits.limits(status, id: "devin:x")
        #expect(limits.plan == "Max")
        #expect(limits.meters.map(\.id) == ["weekly"])
        #expect(limits.meters.first?.used == 6)
        #expect(limits.notes.first?.value == "$0")
        // A used-up quota leaves its percentage out of the answer.
        let spent = DevinLimits.limits(object(#"{"planInfo":{},"dailyQuotaResetAtUnix":1792483200,"weeklyQuotaRemainingPercent":50,"weeklyQuotaResetAtUnix":1792915200}"#), id: "d")
        #expect(spent.meters.map(\.used) == [100, 50])
    }

    @Test func devinReadsXDGDataHomeBeforeDefaultFolder() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-devin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent("xdg")
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("devin"), withIntermediateDirectories: true)
        try "windsurf_api_key = \"xdg-key\"\n".write(to: xdg.appendingPathComponent("devin/credentials.toml"), atomically: true, encoding: .utf8)

        // One suite per test, emptied after: preferences keeps a file for every suite name ever used.
        let suite = "usagegraphs-tests-devin-xdg"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configured = EnvironmentFolders.seen("XDG_DATA_HOME", environment: ["XDG_DATA_HOME": xdg.path], defaults: defaults)
        #expect(EnvironmentFolders.seen("XDG_DATA_HOME", environment: [:], defaults: defaults) == [xdg.path])

        let sent = Mutex<[URLRequest]>([])
        let body = Data(#"{"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":80}}}"#.utf8)
        let cards = await HTTP.$transport.withValue({ request in
            sent.withLock { $0.append(request) }
            return HTTP.Response(status: 200, headers: [:], data: body)
        }) {
            await DevinLimits().fetch(home: home, configured: configured)
        }
        #expect(cards.first?.id == "devin:" + "xdg-key".sha256Prefix)
        #expect(cards.first?.meters.first?.used == 20)
        #expect(sent.withLock { $0.count } == 1)

        let fallback = home.appendingPathComponent(".local/share/devin")
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        try "windsurf_api_key = \"default-key\"\n".write(to: fallback.appendingPathComponent("credentials.toml"), atomically: true, encoding: .utf8)
        #expect(DevinLimits.credentials(home: home, configured: configured)?.key == "xdg-key")
        #expect(DevinLimits.credentials(home: home, configured: [])?.key == "default-key")
    }

    @Test func grokReadsItsWeeklyPool() {
        let config = object(#"{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-13T16:52:11.0+00:00","end":"2026-10-20T16:52:11.0+00:00"},"onDemandCap":{"val":2500}}"#)
        let limits = GrokLimits.limits(config, id: "grok:x", account: nil, plan: "SuperGrok Heavy")
        #expect(limits.meters.map(\.id) == ["weekly"])
        // Zero values are left out, so no percentage means none used.
        #expect(limits.meters.first?.used == 0)
        #expect(limits.meters.first?.period == TimeInterval(7 * 86_400))
        #expect(limits.notes.first?.value == "$2.50K cap")
    }

    // MARK: Pace

    private func meter(used: Double, resetIn: TimeInterval?, period: TimeInterval? = 5 * 3600) -> LimitMeter {
        .percent("session", "Session", used: used, resetsAt: resetIn.map { now.addingTimeInterval($0) }, period: period)
    }

    @Test func paceJudgesTheWholeWindow() throws {
        // Half the window gone, a third used: on course for two thirds.
        let fine = Pace(meter(used: 33, resetIn: 2.5 * 3600), now: now)
        #expect(fine.verdict == .fine)
        #expect(abs((fine.atReset ?? 0) - 0.66) < 0.001)
        #expect(fine.runsOut == nil)
        // On course for 96%: tight.
        #expect(Pace(meter(used: 48, resetIn: 2.5 * 3600), now: now).verdict == .tight)
        // Half used a fifth of the way in: runs out after another 1.5 hours.
        let over = Pace(meter(used: 50, resetIn: 4 * 3600), now: now)
        #expect(over.verdict == .over)
        let runsOut = try #require(over.runsOut)
        #expect(abs(runsOut.timeIntervalSince(now) - 3600) < 1)
        #expect(Pace(meter(used: 100, resetIn: 3600), now: now).verdict == .reached)
        // Too early in the window to project; the level alone is judged.
        #expect(Pace(meter(used: 30, resetIn: 5 * 3600 - 60), now: now).verdict == .fine)
        #expect(Pace(meter(used: 85, resetIn: nil, period: nil), now: now).verdict == .tight)
        #expect(Pace(meter(used: 92, resetIn: nil, period: nil), now: now).verdict == .over)
    }

    // MARK: Failed readings

    @Test func failedReadingsKeepTheLastValues() {
        let weekly = LimitMeter.percent("weekly", "Weekly", used: 58, resetsAt: now.addingTimeInterval(-3600), period: 7 * 86_400)
        let session = LimitMeter.percent("session", "Session", used: 90, resetsAt: now.addingTimeInterval(-60), period: 5 * 3600)
        let fable = LimitMeter.percent("model-fable", "Fable", used: 3, resetsAt: now.addingTimeInterval(86_400), period: 7 * 86_400)
        let previous = AccountLimits(id: "claude:a", provider: .claude, plan: "Max 20x", meters: [weekly, session, fable], updated: now.addingTimeInterval(-7200))
        let failed = AccountLimits.failed("claude:a", .claude, "Couldn't reach Anthropic.")

        let kept = failed.keepingValues(of: previous, now: now)
        #expect(kept.problem == "Couldn't reach Anthropic.")
        #expect(kept.plan == "Max 20x")
        #expect(kept.updated == previous.updated)
        // The week rolled over into the next; the session waits for the next message.
        #expect(kept.meters[0].used == 0)
        #expect(kept.meters[0].resetsAt == weekly.resetsAt!.addingTimeInterval(7 * 86_400))
        #expect(kept.meters[1].used == 0)
        #expect(kept.meters[1].resetsAt == nil)
        #expect(kept.meters[2] == fable)

        // A good reading replaces the old one.
        let fresh = AccountLimits(id: "claude:a", provider: .claude, meters: [fable])
        #expect(fresh.keepingValues(of: previous, now: now) == fresh)
    }

    @Test func calendarBillingMonthIsNotRolledByPreviousMonthsLength() throws {
        let september = try #require(JSONValue.date("2026-09-01T00:00:00Z"))
        let october = try #require(JSONValue.date("2026-10-01T00:00:00Z"))
        let octoberNoon = try #require(JSONValue.date("2026-10-01T12:00:00Z"))
        let november = try #require(JSONValue.date("2026-11-01T00:00:00Z"))
        let previous = AccountLimits(id: "cursor:fixture", provider: .cursor, meters: [
            .percent("total", "Included usage", used: 80, resetsAt: october, period: october.timeIntervalSince(september)),
        ])
        let kept = AccountLimits.failed(previous.id, .cursor, "Fixture outage").keepingValues(of: previous, now: octoberNoon)
        #expect(kept.meters.first?.resetsAt == november)

        let jan31 = try #require(JSONValue.date("2026-01-31T00:00:00Z"))
        let mar5 = try #require(JSONValue.date("2026-03-05T00:00:00Z"))
        let mar31 = try #require(JSONValue.date("2026-03-31T00:00:00Z"))
        let clamped = AccountLimits(id: "cursor:fixture", provider: .cursor, meters: [
            .percent("total", "Included usage", used: 80, resetsAt: jan31, period: 31 * 86_400),
        ])
        let keptClamped = AccountLimits.failed(clamped.id, .cursor, "Fixture outage").keepingValues(of: clamped, now: mar5)
        #expect(keptClamped.meters.first?.resetsAt == mar31)
    }

    @Test func structurallyUnexpectedResponsesKeepLastGoodLimits() {
        let codex = CodexLimits.limits(["plan_type": "pro", "email": "a@b.c"], id: "codex:fixture", account: "a@b.c")
        #expect(codex.problem == "ChatGPT's usage API sent no limits the app knows.")
        #expect(codex.plan == "Pro")
        #expect(codex.account == "a@b.c")

        let devin = DevinLimits.limits(["planInfo": ["planName": "Max"]], id: "devin:fixture")
        #expect(devin.problem == "Devin's usage API sent no limits the app knows.")
        #expect(devin.plan == "Max")

        for fresh in [codex, devin] {
            let previous = AccountLimits(id: fresh.id, provider: fresh.provider, meters: [
                .percent("weekly", "Weekly", used: 71, resetsAt: now.addingTimeInterval(3600), period: 604_800),
            ], updated: now)
            var missing: [String: Date] = [:]
            let updated = LimitsSources.update([previous], with: [fresh], asked: [fresh.provider], missingSince: &missing, now: now)
            #expect(updated.first?.meters.first?.used == 71)
            #expect(updated.first?.problem == fresh.problem)
        }
    }

    @Test func emptyAnswersFromEveryProviderKeepLastGoodLimits() async {
        @Sendable func answer(_ status: Int, _ json: String) -> HTTP.Response {
            HTTP.Response(status: status, headers: ["content-type": "application/json"], data: Data(json.utf8))
        }
        let claude = await HTTP.$transport.withValue({ _ in answer(200, "{}") }) {
            await AnthropicUsage.shared.limits(id: "claude:empty", provider: .claude, account: "Personal", token: "empty-token", renew: "Run `claude`.", plan: "Max")
        }
        #expect(claude.problem == "Anthropic's usage API sent no limits the app knows.")
        #expect(claude.plan == "Max")

        let antigravity = await HTTP.$transport.withValue({ request in
            request.url!.path.hasSuffix("fetchAvailableModels") ? answer(200, #"{"models":{"gemini-3":{"displayName":"Gemini 3"}}}"#) : answer(200, #"{"groups":[]}"#)
        }) {
            await Self.antigravity().limits(AntigravityLimits.Session(token: "empty-token", email: "a@b.c"), id: "antigravity:a@b.c", provider: .antigravity)
        }
        #expect(antigravity.problem == "Google's quota service sent no limits the app knows.")
        #expect(antigravity.account == "a@b.c")

        let opencode = OpenCodeLimits.limits(answer(200, #"{"usage":{}}"#), id: "opencode:empty")
        #expect(opencode.map(\.problem) == ["OpenCode's usage API sent no limits the app knows."])

        for fresh in [claude, antigravity] + opencode {
            let previous = AccountLimits(id: fresh.id, provider: fresh.provider, meters: [
                .percent("weekly", "Weekly", used: 71, resetsAt: now.addingTimeInterval(3600), period: 604_800),
            ], updated: now)
            var missing: [String: Date] = [:]
            let updated = LimitsSources.update([previous], with: [fresh], asked: [fresh.provider], missingSince: &missing, now: now)
            #expect(updated.first?.meters.first?.used == 71)
        }
    }

    @Test func claudeLimitsListWithoutPercentsFallsBackToNamedWindows() {
        let body = object("""
            {"limits":[{"kind":"session","resets_at":"2026-10-19T19:10:00Z"}],
             "five_hour":{"utilization":42,"resets_at":"2026-10-19T19:10:00Z"}}
            """)
        #expect(ClaudeLimits.meters(body).map(\.used) == [42])
    }

    @Test func openCodeKeyWithoutGoSaysSo() {
        let cards = OpenCodeLimits.limits(HTTP.Response(status: 403, headers: [:], data: Data()), id: "opencode:lapsed")
        #expect(cards.map(\.problem) == ["This OpenCode Go key has no active subscription."])
    }

    @Test func limitsAreReadAgainJustAfterAWindowResets() {
        let last = now.addingTimeInterval(-30)
        #expect(LimitsTimer.next(after: last, interval: 3600, resets: [], now: now) == (last.addingTimeInterval(3600), false))
        #expect(LimitsTimer.next(after: last, interval: 3600, resets: [last.addingTimeInterval(600), last.addingTimeInterval(900)], now: now) == (last.addingTimeInterval(605), true))
        #expect(LimitsTimer.next(after: last, interval: 3600, resets: [last.addingTimeInterval(10)], now: now) == (last.addingTimeInterval(60), true))
        #expect(LimitsTimer.next(after: last, interval: 3600, resets: [last.addingTimeInterval(-10), last.addingTimeInterval(7200)], now: now) == (last.addingTimeInterval(3600), false))
        #expect(LimitsTimer.next(after: nil, interval: 300, resets: [now.addingTimeInterval(-5)], now: now) == (now.addingTimeInterval(300), false))
        // Readings that reached no provider are tried again sooner, backing off to the interval.
        #expect(LimitsTimer.next(after: last, interval: 3600, resets: [], unanswered: 1, now: now) == (last.addingTimeInterval(60), false))
        #expect(LimitsTimer.next(after: last, interval: 3600, resets: [], unanswered: 3, now: now) == (last.addingTimeInterval(240), false))
        #expect(LimitsTimer.next(after: last, interval: 300, resets: [], unanswered: 9, now: now) == (last.addingTimeInterval(300), false))
        #expect(LimitsTimer.next(after: last, interval: 3600, resets: [last.addingTimeInterval(30)], unanswered: 1, now: now) == (last.addingTimeInterval(60), true))
    }

    @Test func freshReadingsOfWindowsThatAlreadyResetReadAsUnused() {
        let fresh = AccountLimits(id: "claude:x", provider: .claude, meters: [
            .percent("session", "Session", used: 100, resetsAt: now.addingTimeInterval(-60), period: 18_000),
            .percent("weekly", "Weekly", used: 40, resetsAt: now.addingTimeInterval(-60), period: 604_800),
            .percent("daily", "Daily", used: 30, resetsAt: now.addingTimeInterval(600), period: 86_400),
        ], updated: now)
        var missing: [String: Date] = [:]
        let meters = LimitsSources.update([], with: [fresh], asked: [.claude], missingSince: &missing, now: now).first?.meters ?? []
        #expect(meters.map(\.used) == [0, 0, 30])
        #expect(meters.map(\.resetsAt) == [nil, now.addingTimeInterval(604_740), now.addingTimeInterval(600)])
    }

    @Test func meterIDsRepeatedWithinAnAccountAreToldApart() async {
        struct Fixed: LimitsSource {
            let provider = Provider.codex
            let account: AccountLimits
            func fetch() async -> [AccountLimits] { [account] }
        }
        let window: [String: Any] = ["used_percent": 10, "limit_window_seconds": 18_000, "reset_at": 1_792_000_000]
        let body: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": ["primary_window": window],
            "additional_rate_limits": [
                ["limit_name": "spark", "rate_limit": ["primary_window": window]],
                ["limit_name": "spark-fast", "rate_limit": ["primary_window": window]],
            ],
        ]
        let cards = await LimitsSources.fetch([Fixed(account: CodexLimits.limits(body, id: "codex:x", account: nil))])
        #expect(cards.first?.meters.map(\.id) == ["session", "spark-session", "spark-fast-session"])
        // Told apart by name, they keep their IDs in either order.
        var reordered = body
        reordered["additional_rate_limits"] = Array(((body["additional_rate_limits"] as? [[String: Any]]) ?? []).reversed())
        #expect(CodexLimits.limits(reordered, id: "codex:x", account: nil).meters.map(\.id) == ["session", "spark-fast-session", "spark-session"])
        // A pin made while one Spark limit was listed survives a second turning up beside it.
        var real = body
        real["additional_rate_limits"] = [["limit_name": "GPT-5.3-Codex-Spark", "rate_limit": ["primary_window": window]]]
        #expect(CodexLimits.limits(real, id: "codex:x", account: nil).meters.map(\.id) == ["session", "spark-session"])
        real["additional_rate_limits"] = [["limit_name": "GPT-5.3-Codex-Spark-Fast", "rate_limit": ["primary_window": window]],
                                          ["limit_name": "GPT-5.3-Codex-Spark", "rate_limit": ["primary_window": window]]]
        #expect(CodexLimits.limits(real, id: "codex:x", account: nil).meters.map(\.id) == ["session", "gpt-5-3-codex-spark-fast-session", "spark-session"])
        // The same ID twice still comes apart.
        var twins = body
        twins["additional_rate_limits"] = [["limit_name": "spark", "rate_limit": ["primary_window": window]], ["limit_name": "spark", "rate_limit": ["primary_window": window]]]
        let twinCards = await LimitsSources.fetch([Fixed(account: CodexLimits.limits(twins, id: "codex:x", account: nil))])
        #expect(twinCards.first?.meters.map(\.id) == ["session", "spark-session", "spark-session-2"])
    }

    @Test func aRefusedKeychainItemThatIsGoneReadsAsMissing() {
        let item = Keychain.Item(service: "swiftusage-tests-\(UUID().uuidString)", account: "gone")
        Keychain.setRefused(item, true)
        #expect(Keychain.password(item) == .missing)
        #expect(!Keychain.isRefused(item))
    }

    // MARK: More providers and logins

    @Test func antigravityReadsItsKeychainLogin() throws {
        let json = #"{"token":{"access_token":"ya29.a","refresh_token":"1//r","expiry":"2026-10-19T17:00:00.5+02:00"}}"#
        let login = try #require(AntigravityLimits.login("go-keyring-base64:" + Data(json.utf8).base64EncodedString()))
        #expect(login.access == "ya29.a")
        #expect(login.refresh == "1//r")
        #expect(login.expires == Date(timeIntervalSince1970: Timestamp.parse("2026-10-19T15:00:00.5Z")!))
        #expect(AntigravityLimits.login("Bearer ya29.b")?.access == "ya29.b")
        #expect(AntigravityLimits.login("  ") == nil)
    }

    @Test func antigravityFindsTheAppsAndAgysLogins() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-agy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        try #"{"auth_method":"consumer","token":{"access_token":"cli","refresh_token":"1//cli","expiry":"2026-08-15T14:39:42.77425+02:00","token_type":"Bearer"}}"#
            .write(to: home.appendingPathComponent(".gemini/jetski-standalone-oauth-token"), atomically: true, encoding: .utf8)
        let app = "go-keyring-base64:" + Data(#"{"token":{"access_token":"app","refresh_token":"1//app"}}"#.utf8).base64EncodedString()
        let logins = AntigravityLimits.logins(home: home) { item in item == Keychain.Item(service: "gemini", account: "antigravity") ? .password(app) : .missing }.logins
        #expect(logins.map(\.refresh) == ["1//app", "1//cli"])
        #expect(logins.last?.access == "cli")
        #expect(AntigravityLimits.logins(home: home.appendingPathComponent("nowhere")) { _ in .missing }.logins.isEmpty)
        // An item macOS would ask about is left for the person to allow.
        let waiting = AntigravityLimits.logins(home: home.appendingPathComponent("nowhere")) { _ in .needsPermission }
        #expect(waiting.logins.isEmpty)
        #expect(waiting.waitingOn == Keychain.Item(service: "gemini", account: "antigravity"))
    }

    @Test func mixedAntigravityDiscoveryRetainsAWaitingItem() async {
        let nowhere = URL(fileURLWithPath: "/tmp/nonexistent-swiftusage-agy-\(UUID().uuidString)")
        let expired = #"{"token":{"access_token":"app","expiry":"2026-08-15T14:39:42Z"}}"#
        let keychain: @Sendable (Keychain.Item) -> Keychain.Reading = { item in
            item.account == "antigravity" ? .password(expired) : .needsPermission
        }
        let found = AntigravityLimits.logins(home: nowhere, keychain: keychain)
        #expect(found.logins.count == 1)
        #expect(found.waitingOn == Keychain.Item(service: "gemini", account: "antigravity-cli"))
        let cards = await Self.antigravity().fetch(home: nowhere, keychain: keychain)
        #expect(cards.map(\.id) == ["antigravity:" + "app".sha256Prefix, "antigravity:keychain"])
        #expect(cards.last?.action == .allowKeychain)
    }

    @Test func aRefusedAntigravityLoginDoesntHideAWorkingOneForTheSameAccount() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swiftusage-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let emails = folder.appendingPathComponent("antigravity-accounts.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The app's login was once renewed as this account; Google has since refused its refresh token.
        try JSONEncoder().encode(["1//refused".sha256Prefix: "a@b.c"]).write(to: emails)
        let nowhere = folder.appendingPathComponent("home")
        let keychain: @Sendable (Keychain.Item) -> Keychain.Reading = { item in
            let refresh = item.account == "antigravity" ? "1//refused" : "1//works"
            return .password(#"{"token":{"refresh_token":"\#(refresh)"}}"#)
        }
        func base64URL(_ json: String) -> String {
            Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let idToken = base64URL(#"{"alg":"none"}"#) + "." + base64URL(#"{"email":"a@b.c"}"#) + ".x"
        let cards = await HTTP.$transport.withValue({ request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if request.url!.host == "oauth2.googleapis.com" {
                return body.contains("refused")
                    ? HTTP.Response(status: 400, headers: [:], data: Data(#"{"error":"invalid_grant"}"#.utf8))
                    : HTTP.Response(status: 200, headers: [:], data: Data(#"{"access_token":"renewed","expires_in":3600,"id_token":"\#(idToken)"}"#.utf8))
            }
            if request.url!.path.hasSuffix("retrieveUserQuotaSummary") {
                return HTTP.Response(status: 200, headers: [:], data: Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75}]}]}"#.utf8))
            }
            return HTTP.Response(status: 200, headers: [:], data: Data("{}".utf8))
        }) {
            await AntigravityLimits(emailsURL: emails).fetch(home: nowhere, keychain: keychain)
        }
        #expect(cards.map(\.id) == ["antigravity:a@b.c"])
        #expect(cards.first?.problem == nil)
        #expect(cards.first?.meters.map(\.id) == ["gemini-5h"])
    }

    @Test func antigravityPoolsItsQuotas() {
        // The summary: shared buckets by exact ID, the first answer winning, plus Argon's own week.
        let first = object(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-10-19T20:00:00Z"},{"bucketId":"gemini-image-5h","remainingFraction":0}]},{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"argon","window":"weekly","remainingFraction":0.5}]}]}"#)
        let second = object(#"{"groups":[{"displayName":"Claude","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.1},{"bucketId":"3p-weekly","remainingFraction":0.9},{"bucketId":"3p-5h"}]}]}"#)
        let summary = AntigravityLimits.summaryMeters([first, second])
        #expect(summary.map(\.id) == ["gemini-5h", "argon-weekly", "3p-weekly"])
        #expect(summary.map(\.used) == [25, 50, 10])

        // Per-model quotas: the most used model speaks for its pool, the window told by the reset.
        let models = object("""
            {"gemini-3-flash":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":0.6,"resetTime":"2026-10-19T19:00:00Z"}},
             "gemini-3.5-flash-low":{"displayName":"Gemini 3.5 Flash (Medium)","quotaInfo":{"remainingFraction":0.2,"resetTime":"2026-10-26T16:00:00Z"}},
             "gemini-2.5-pro":{"displayName":"Gemini 2.5 Pro","quotaInfo":{"remainingFraction":0.9,"resetTime":"2026-10-19T18:00:00Z"}},
             "claude-sonnet-4-6":{"displayName":"Claude Sonnet 4.6 (Thinking)","quotaInfo":{"resetTime":"2026-10-26T16:00:00Z"}},
             "chat_20706":{"isInternal":true,"quotaInfo":{"remainingFraction":0}},
             "tab_flash_lite_preview":{"quotaInfo":{"remainingFraction":1}},
             "gemini-4-argon":{"displayName":"Gemini 4 Argon","quotaInfo":{"remainingFraction":0.1}}}
            """)
        let pooled = AntigravityLimits.modelMeters(models, now: now)
        #expect(pooled.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-weekly"])
        // Zero is left out of the answer, so Sonnet's quota without a fraction is used up.
        #expect(pooled.map(\.used) == [40, 80, 100])
        #expect(AntigravityLimits.plan(paid: ["id": "free-tier", "name": "Antigravity Starter Quota"], current: nil) == "Free")
        #expect(AntigravityLimits.plan(paid: ["name": "Google AI Ultra"], current: nil) == "Ultra")
    }

    @Test func antigravityWeeklyIdentityDoesNotChangeNearReset() {
        let reset = now.addingTimeInterval(7 * 3600)
        let models: [String: Any] = [
            "gemini-fixture": [
                "displayName": "Gemini Fixture",
                "quotaInfo": ["remainingFraction": 0.2, "resetTime": reset.timeIntervalSince1970],
            ],
        ]
        let remembered = AntigravityLimits.weeklyResets(in: models, now: now)
        let early = AntigravityLimits.modelMeters(models, now: now, weeklyResets: remembered)
        let late = AntigravityLimits.modelMeters(models, now: reset.addingTimeInterval(-2 * 3600), weeklyResets: remembered)
        #expect(early.map(\.id) == ["gemini-weekly"])
        #expect(late.map(\.id) == ["gemini-weekly"])
        #expect(late.first?.period == 604_800)
        let freshSession = AntigravityLimits.modelMeters(models, now: reset.addingTimeInterval(-4 * 3600))
        #expect(freshSession.map(\.id) == ["gemini-5h"])
        #expect(freshSession.first?.period == 18_000)
    }

    @Test func rejectedAntigravityRenewalKeepsCachedEmail() async {
        let source = Self.antigravity()
        let login = AntigravityLimits.Login(refresh: "1//fixture")
        _ = await source.session(for: login) { _ in .renewed("tok", .distantPast, "user@example.com") }
        let rejected = await source.session(for: login) { _ in .rejected }
        #expect(rejected.email == "user@example.com")
        #expect(rejected.problem == "Login expired. Open Antigravity or run `agy` to sign in again.")
    }

    @Test func antigravityKnowsWhoseLoginItIsWhenGoogleCantBeReached() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swiftusage-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let emails = folder.appendingPathComponent("antigravity-accounts.json")
        let login = AntigravityLimits.Login(access: "own-token", refresh: "1//known", expires: .distantFuture)
        _ = await AntigravityLimits(emailsURL: emails).session(for: login) { _ in .renewed("tok", .distantFuture, "a@b.c") }
        // After a relaunch, with Google's token service down and the login's own token still good.
        let relaunched = await AntigravityLimits(emailsURL: emails).session(for: login) { _ in .unavailable }
        #expect(relaunched.token == "own-token")
        #expect(relaunched.email == "a@b.c")
    }

    @Test func revokedAntigravityRefreshTokenIsNotRetried() async {
        let calls = Mutex(0)
        let source = Self.antigravity()
        let revoked = AntigravityLimits.Login(access: "fixture-access", refresh: "fixture-revoked", expires: .distantFuture)
        for _ in 0..<3 {
            let session = await source.session(for: revoked) { _ in
                calls.withLock { $0 += 1 }
                return .rejected
            }
            #expect(session.token == nil)
            #expect(session.problem == "Login expired. Open Antigravity or run `agy` to sign in again.")
        }
        #expect(calls.withLock { $0 } == 1)

        let fresh = AntigravityLimits.Login(refresh: "fixture-fresh")
        let renewed = await source.session(for: fresh) { _ in
            calls.withLock { $0 += 1 }
            return .renewed("fresh-token", .distantFuture, "user@example.com")
        }
        #expect(renewed.token == "fresh-token")
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func antigravityRenewalOnlyGivesUpWhenGoogleRefusesTheLogin() async {
        let source = Self.antigravity()
        let login = AntigravityLimits.Login(refresh: "1//portal")
        let replies = Mutex([
            HTTP.Response(status: 302, headers: ["location": "http://portal.example/"], data: Data()),
            HTTP.Response(status: 200, headers: [:], data: Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8)),
        ])
        let first = await HTTP.$transport.withValue({ _ in replies.withLock { $0.removeFirst() } }) { await source.session(for: login) }
        #expect(first.token == nil)
        let second = await HTTP.$transport.withValue({ _ in replies.withLock { $0.removeFirst() } }) { await source.session(for: login) }
        #expect(second.token == "renewed")
    }

    @Test func cursorWeeklyPlanWithoutItsResetHasNoReset() {
        let usage: [String: Any] = ["billingCycleStart": "2026-10-01T00:00:00Z", "billingCycleEnd": "2026-11-01T00:00:00Z",
                                    "planUsage": ["totalPercentUsed": 40]]
        let card = CursorLimits.limits(usage, planInfo: ["includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY"], id: "cursor:x", account: nil, plan: "Pro")
        #expect(card.meters.first?.resetsAt == nil)
        #expect(card.meters.first?.period == 604_800)
    }

    @Test func piReadsItsSubscriptionLogins() {
        let auth = object("""
            {"anthropic":{"type":"oauth","access":"sk-ant-oat","refresh":"r","expires":1792500000000},
             "openai-codex":{"type":"oauth","access":"a.b.c","accountId":"acct-1","refresh":"r","expires":1792500000000},
             "openai-codex-2":{"type":"oauth","access":"d.e.f","accountId":"acct-2"},
             "xai":{"type":"oauth","access":"x"},
             "github-copilot":{"type":"oauth","access":"ghu"},
             "openrouter":{"type":"api_key","key":"sk-or"}}
            """)
        let logins = PiLimits.logins(auth)
        #expect(logins.map(\.service) == [.claude, .chatGPT, .chatGPT, .xai])
        #expect(logins.map(\.accountID) == [nil, "acct-1", "acct-2", nil])
        #expect(logins.first?.expires == Date(timeIntervalSince1970: 1_792_500_000))
    }

    @Test func expiredPiClaudeAccountKeepsItsExistingCard() {
        let token = "sk-ant-oat-fixture"
        let profile = AnthropicUsage.Profile(accountID: "A", organizationID: "O", organizationName: "me@x.com's Organization", email: "me@x.com", plan: "Max")
        let live = PiLimits.identity(for: token, expired: false, profile: profile)
        #expect(live.id == "claude:a|o")
        #expect(live.name == "Claude · Personal")

        let expired = PiLimits.identity(for: token, expired: true)
        #expect(expired.id == "claude:a|o")
        #expect(expired.name == "Claude · Personal")

        let previous = AccountLimits(id: live.id, provider: .pi, account: live.name, meters: [
            .percent("weekly", "Weekly", used: 31, resetsAt: now.addingTimeInterval(3600), period: 604_800),
        ], updated: now)
        let failed = AccountLimits.failed(expired.id, .pi, account: expired.name, "Login expired. Run `pi` to renew it.")
        var missing: [String: Date] = [:]
        let cards = LimitsSources.update([previous], with: [failed], asked: [.pi], missingSince: &missing, now: now)
        #expect(cards.count == 1)
        #expect(cards.first?.id == "claude:a|o")
        #expect(cards.first?.account == "Claude · Personal")
        #expect(cards.first?.meters.first?.used == 31)
        #expect(cards.first?.problem == "Login expired. Run `pi` to renew it.")

        let cold = PiLimits.identity(for: "sk-ant-oat-never-seen", expired: true)
        #expect(cold.id == "pi-claude:" + "sk-ant-oat-never-seen".sha256Prefix)
        #expect(cold.name == "Claude")
    }

    @Test func claudeDesktopLoginsDecrypt() throws {
        let password = "desktop-storage-password"
        let account = "a2"
        let future = Int(Date().timeIntervalSince1970 * 1000) + 3_600_000
        let cache: [String: Any] = [
            // Desktop's own client with both scopes beats a narrower token for the same organization.
            "acct:A2|9d1c250a-e61b-44d9-88ed-5944d1962f5e:O1:https://api.anthropic.com:user:inference user:profile": ["token": "best", "expiresAt": future, "subscriptionType": "max"],
            "other-client:O1:https://api.anthropic.com:user:profile": ["token": "narrow", "expiresAt": future],
            // Another account's, one that can't read limits, an expired one, and a deleted one.
            "acct:A9|9d1c250a-e61b-44d9-88ed-5944d1962f5e:O2:https://api.anthropic.com:user:inference user:profile": ["token": "theirs", "expiresAt": future],
            "9d1c250a-e61b-44d9-88ed-5944d1962f5e:O3:https://api.anthropic.com:user:inference": ["token": "inference", "expiresAt": future],
            "9d1c250a-e61b-44d9-88ed-5944d1962f5e:O4:https://api.anthropic.com:user:inference user:profile": ["token": "old", "expiresAt": 1000],
            "9d1c250a-e61b-44d9-88ed-5944d1962f5e:O5:https://api.anthropic.com:user:profile": NSNull(),
        ]
        let sealed = try Self.seal(JSONSerialization.data(withJSONObject: cache), password: password)
        #expect(ClaudeDesktop.decrypt(sealed, password: password) == (try JSONSerialization.data(withJSONObject: cache)))
        // A wrong key fails, or yields bytes that aren't the cache.
        #expect(ClaudeDesktop.decrypt(sealed, password: "wrong") != (try JSONSerialization.data(withJSONObject: cache)))

        let logins = ClaudeDesktop.logins(config: ["oauth:tokenCacheV2": sealed.base64EncodedString()], key: password, account: account)
        #expect(logins.map(\.token) == ["best"])
        #expect(logins.first?.organization == "o1")
        #expect(logins.first?.subscription == "max")
    }

    /// Electron's encryption, to make a test cache: `v10` and AES-128-CBC with the PBKDF2 key.
    private static func seal(_ plain: Data, password: String) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var cipher = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = cipher.withUnsafeMutableBytes { out in
            plain.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, kCCKeySizeAES128,
                                v.baseAddress, input.baseAddress, plain.count, out.baseAddress, out.count, &written)
                    }
                }
            }
        }
        try #require(status == kCCSuccess)
        return Data("v10".utf8) + cipher.prefix(written)
    }

    @Test func sharedAccountsShowOnce() {
        let meter = LimitMeter.percent("session", "Session", used: 10, resetsAt: nil, period: nil)
        let claudeCode = AccountLimits.failed("claude:a|o", .claude, account: "Personal", "Anthropic is limiting requests.")
        let pi = AccountLimits(id: "claude:a|o", provider: .pi, account: "Claude · Personal", meters: [meter])
        let codex = AccountLimits(id: "codex:1", provider: .codex, meters: [meter])
        let piCodex = AccountLimits.failed("codex:1", .pi, "Login expired.")

        let merged = LimitsSources.merged([claudeCode, codex, pi, piCodex])
        #expect(merged.map(\.id) == ["claude:a|o", "codex:1"])
        // The card keeps its place and name, and takes the reading that worked.
        #expect(merged[0].provider == .claude)
        #expect(merged[0].account == "Personal")
        #expect(merged[0].meters == [meter])
        #expect(merged[0].problem == nil)
        #expect(merged[0].sharedWith == [.pi])
        #expect(merged[1].meters == [meter])
        #expect(merged[1].sharedWith == [.pi])
        #expect(merged[1].isUsed(by: .pi) && merged[1].isUsed(by: .codex) && !merged[1].isUsed(by: .claude))

        // Readings saved before `sharedWith` existed still load.
        let old = #"{"id":"codex:1","provider":"codex","meters":[],"notes":[],"updated":0}"#
        #expect((try? JSONDecoder().decode(AccountLimits.self, from: Data(old.utf8)))?.sharedWith == [])
        #expect((try? JSONDecoder().decode(AccountLimits.self, from: Data(old.utf8)))?.resets == nil)
    }

    @Test func aWorkingLoginReplacesAnEarlierFailedOne() async throws {
        let meter = LimitMeter.percent("session", "Session", used: 25, resetsAt: nil, period: nil)
        let failed = AccountLimits.failed("claude:a|o", .claude, account: "Personal", "Login expired.")
        let working = AccountLimits(id: "claude:a|o", provider: .claude, meters: [meter])

        var tried: [String] = []
        let fallback = await LimitsSources.readings(of: ["expired", "working"], id: { _ in "claude:a|o" }) { token in
            tried.append(token)
            return token == "expired" ? failed : working
        }
        #expect(tried == ["expired", "working"])
        let merged = LimitsSources.merged(fallback)
        #expect(merged.count == 1)
        #expect(merged.first?.account == "Personal")
        #expect(merged.first?.meters == [meter])
        #expect(merged.first?.problem == nil)

        tried = []
        let firstWorked = await LimitsSources.readings(of: ["working", "spare"], id: { _ in "claude:a|o" }) { token in
            tried.append(token)
            return working
        }
        #expect(tried == ["working"])
        #expect(LimitsSources.merged(firstWorked).first?.meters == [meter])

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude-work"), withIntermediateDirectories: true)
        let identity = #"{"oauthAccount":{"accountUuid":"A1","organizationUuid":"O1","organizationName":"Tasteskill"}}"#
        try identity.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try identity.write(to: home.appendingPathComponent(".claude-work/.claude.json"), atomically: true, encoding: .utf8)
        let future = Int((now.timeIntervalSince1970 + 3600) * 1000)
        try #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1000}}"#
            .write(to: home.appendingPathComponent(".claude/.credentials.json"), atomically: true, encoding: .utf8)
        try #"{"claudeAiOauth":{"accessToken":"current","expiresAt":\#(future)}}"#
            .write(to: home.appendingPathComponent(".claude-work/.credentials.json"), atomically: true, encoding: .utf8)

        let logins = ClaudeLimits.logins(home: home, environment: ["USER": "tester"]) { _ in .missing }
        let readings = await LimitsSources.readings(of: logins, id: \.id) { login in
            if let expires = login.expires, expires < now {
                return .failed(login.id, .claude, account: login.account, "Login expired.")
            }
            return AccountLimits(id: login.id, provider: .claude, account: login.account, meters: [meter])
        }
        let cards = LimitsSources.merged(readings)
        #expect(cards.count == 1)
        #expect(cards.first?.account == "Tasteskill")
        #expect(cards.first?.meters == [meter])
        #expect(cards.first?.problem == nil)
    }

    @Test func cursorTeamPlansReadTheDashboard() {
        let summary = object("""
            {"billingCycleStart":"2026-10-01T00:00:00.000Z","billingCycleEnd":"2026-11-01T00:00:00.000Z",
             "individualUsage":{"plan":{"totalPercentUsed":42,"autoPercentUsed":30,"apiPercentUsed":12},"onDemand":{"enabled":false,"used":0,"limit":0}},
             "teamUsage":{"onDemand":{"enabled":true,"used":1250,"limit":10000}}}
            """)
        let requests = object(#"{"gpt-4":{"numRequests":120,"numRequestsTotal":130,"maxRequestUsage":500},"startOfMonth":"2026-10-01T00:00:00.000Z"}"#)
        let dashboard = CursorLimits.dashboard(summary: summary, requests: requests)
        #expect(dashboard.meters.map(\.id) == ["total", "auto", "api", "requests", "on-demand"])
        #expect(dashboard.meters[3].used == 130)
        #expect(dashboard.meters[3].limit == 500)
        #expect(dashboard.meters[4].used == 12.5)
        #expect(dashboard.meters[4].limit == 100)
        #expect(CursorLimits.dashboard(summary: nil, requests: nil).hasValues == false)
    }

    @Test func cursorReadsOnDemandFromTheMatchingScope() throws {
        let individual = CursorLimits.limits([
            "spendLimitUsage": [
                "individualLimit": 10_000,
                "individualUsed": 0,
                "pooledLimit": 100_000,
                "pooledUsed": 5_000,
            ],
        ], planInfo: nil, id: "cursor:x", account: nil, plan: "Team")
        let individualMeter = try #require(individual.meters.first(where: { $0.id == "on-demand" }))
        #expect(individualMeter.used == 0)
        #expect(individualMeter.limit == 100)

        let pooled = CursorLimits.limits([
            "spendLimitUsage": [
                "individualLimit": 0,
                "individualUsed": 0,
                "pooledLimit": 100_000,
                "pooledUsed": 5_000,
            ],
        ], planInfo: nil, id: "cursor:x", account: nil, plan: "Team")
        let pooledMeter = try #require(pooled.meters.first(where: { $0.id == "on-demand" }))
        #expect(pooledMeter.used == 50)
        #expect(pooledMeter.limit == 1_000)

        let unMetered = CursorLimits.limits(["spendLimitUsage": ["totalSpend": 1234]], planInfo: nil, id: "cursor:x", account: nil, plan: "Pro")
        #expect(unMetered.meters.isEmpty)
        #expect(unMetered.notes == [LimitNote(id: "on-demand", label: "On-demand", value: "$12.34 spent")])
    }

    @Test func cursorWeeklyPlanKeepsItsWeekWhenThePlanRequestFails() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-cursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func base64URL(_ json: String) -> String {
            Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let token = base64URL(#"{"alg":"none"}"#) + "." + base64URL(#"{"sub":"auth0|weekly-\#(UUID().uuidString)"}"#) + ".x"
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');", nil, nil, nil) == SQLITE_OK)

        func read(planAnswers: Bool) async -> AccountLimits? {
            await HTTP.$transport.withValue({ request in
                if request.url!.path.hasSuffix("GetPlanInfo") {
                    guard planAnswers else { return HTTP.Response(status: 503, headers: [:], data: Data()) }
                    let plan = #"{"planInfo":{"planName":"Pro","includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY","includedUsageResetsAt":"2026-10-22T00:00:00Z"}}"#
                    return HTTP.Response(status: 200, headers: [:], data: Data(plan.utf8))
                }
                let usage = #"{"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","planUsage":{"totalPercentUsed":40}}"#
                return HTTP.Response(status: 200, headers: [:], data: Data(usage.utf8))
            }) {
                await CursorLimits().fetch(home: home) { _ in .missing }.first
            }
        }
        let weekly = Date(timeIntervalSince1970: Timestamp.parse("2026-10-22T00:00:00Z")!)
        #expect(await read(planAnswers: true)?.meters.first?.resetsAt == weekly)
        let unanswered = await read(planAnswers: false)
        #expect(unanswered?.meters.first?.resetsAt == weekly)
        #expect(unanswered?.meters.first?.period == 604_800)
        #expect(unanswered?.plan == "Pro")
    }

    @Test func cursorFallsBackForIncludedUsageAlongsideConnectOverage() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-cursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'fixture-cursor-token'), ('cursorAuth/stripeMembershipType', 'enterprise');", nil, nil, nil) == SQLITE_OK)

        let cards = await HTTP.$transport.withValue({ request in
            let body: String = if request.url!.path.hasSuffix("GetPlanInfo") {
                #"{"planInfo":{"planName":"Enterprise"}}"#
            } else if request.url!.path.hasSuffix("GetCurrentPeriodUsage") {
                #"{"spendLimitUsage":{"individualLimit":10000,"individualUsed":1200}}"#
            } else if request.url!.path == "/api/usage-summary" {
                #"{"individualUsage":{"plan":{"totalPercentUsed":37}}}"#
            } else {
                "{}"
            }
            return HTTP.Response(status: 200, headers: [:], data: Data(body.utf8))
        }) {
            await CursorLimits().fetch(home: home) { _ in .missing }
        }
        let card = try #require(cards.first)
        #expect(card.plan == "Enterprise")
        #expect(card.problem == nil)
        #expect(card.meters.map(\.id) == ["total", "on-demand"])
        #expect(card.meters.first?.used == 37)
        #expect(card.meters.last?.used == 12)
        #expect(card.meters.last?.limit == 100)
    }

    @Test func cursorFindsCLIFileAndKeychainLoginsAfterIDE() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-cursor-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func jwt(sub: String) -> String {
            let payload = Data(#"{"sub":"\#(sub)"}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
        }

        let cliToken = jwt(sub: "auth0|cli-user")
        let authURL = home.appendingPathComponent(".cursor/auth.json")
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"accessToken":"\#(cliToken)","refreshToken":"cli-refresh"}"#.write(to: authURL, atomically: true, encoding: .utf8)

        let sent = Mutex<[URLRequest]>([])
        try await HTTP.$transport.withValue({ request in
            sent.withLock { $0.append(request) }
            #expect(request.url!.path != "/oauth/token")
            let body: String = if request.url!.path.hasSuffix("GetPlanInfo") {
                #"{"planInfo":{"planName":"Pro"}}"#
            } else {
                #"{"planUsage":{"totalPercentUsed":25}}"#
            }
            return HTTP.Response(status: 200, headers: [:], data: Data(body.utf8))
        }) {
            // CLI auth.json login is used without touching the keychain.
            let keychainAsked = Mutex(false)
            let fromFile = await CursorLimits().fetch(home: home) { _ in
                keychainAsked.withLock { $0 = true }
                return .needsPermission
            }
            #expect(!keychainAsked.withLock { $0 })
            #expect(fromFile.count == 1)
            #expect(fromFile.first?.id == "cursor:auth0|cli-user")
            #expect(fromFile.first?.meters.first?.used == 25)

            // Without auth.json, the keychain items are read, and needs-permission gives the Allow Access card.
            try FileManager.default.removeItem(at: authURL)
            let fromKeychain = await CursorLimits().fetch(home: home) { item in
                item.service == "cursor-access-token" ? .password(cliToken) : .missing
            }
            #expect(fromKeychain.count == 1)
            #expect(fromKeychain.first?.id == "cursor:auth0|cli-user")
            #expect(fromKeychain.first?.meters.first?.used == 25)

            // A refresh token alone isn't renewed here, which could sign Cursor out: the login reads as expired.
            let fromRefresh = await CursorLimits().fetch(home: home) { item in
                item.service == "cursor-refresh-token" ? .password("cli-refresh") : .missing
            }
            #expect(fromRefresh.count == 1)
            #expect(fromRefresh.first?.problem == "Login expired. Run `agent login` to renew it.")
            #expect(fromRefresh.first?.meters.isEmpty == true)

            let waiting = await CursorLimits().fetch(home: home) { item in
                item.service == "cursor-access-token" ? .needsPermission : .missing
            }
            #expect(waiting.count == 1)
            #expect(waiting.first?.action == .allowKeychain)

            // When the IDE has a login for the same account, the IDE login wins.
            try #"{"accessToken":"\#(cliToken)","refreshToken":"cli-refresh"}"#.write(to: authURL, atomically: true, encoding: .utf8)
            let dbURL = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var db: OpaquePointer?
            #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(cliToken)'), ('cursorAuth/cachedEmail', 'ide@example.com');", nil, nil, nil) == SQLITE_OK)
            sent.withLock { $0.removeAll() }
            let deduplicated = await CursorLimits().fetch(home: home) { _ in .missing }
            #expect(deduplicated.count == 1)
            #expect(deduplicated.first?.account == "ide@example.com")
            #expect(sent.withLock { $0.count } == 2)
        }
    }

    @Test func codexFindsEveryHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in [".codex", ".codex-work", ".config/codex-team", ".codex-empty"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
            if folder != ".codex-empty" { try Data("{}".utf8).write(to: home.appendingPathComponent(folder + "/auth.json")) }
        }
        #expect(CodexLimits.homes(home: home, configured: []).map(\.lastPathComponent) == [".codex", ".codex-work", "codex-team"])
        // A home `CODEX_HOME` named, now or before, comes first.
        let named = home.appendingPathComponent("elsewhere/codex")
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: named.appendingPathComponent("auth.json"))
        #expect(CodexLimits.homes(home: home, configured: [named.path]).first?.path == named.path)
    }

    @Test func codexReadsKeyringLoginsAndPrefersAuthFile() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-codex-keyring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHome = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "cli_auth_credentials_store = \"keyring\"\n".write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        #expect(CodexLimits.homes(home: home, configured: []).map(\.lastPathComponent) == [".codex"])
        let expectedItem = CodexLimits.keychainItem(for: codexHome)
        #expect(expectedItem.service == "Codex Auth")
        #expect(expectedItem.account?.hasPrefix("cli|") == true)
        #expect(expectedItem.account?.count == 20)

        let body = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000}}}"#.utf8)
        let sent = Mutex<[URLRequest]>([])
        try await HTTP.$transport.withValue({ request in
            sent.withLock { $0.append(request) }
            return HTTP.Response(status: 200, headers: [:], data: body)
        }) {
            let keyringJSON = #"{"tokens":{"access_token":"keyring-token","account_id":"acct-keyring"}}"#
            let cards = await CodexLimits().fetch(home: home, configured: []) { item in
                item == expectedItem ? .password(keyringJSON) : .missing
            }
            #expect(cards.count == 1)
            #expect(cards.first?.id == "codex:acct-keyring")
            #expect(cards.first?.meters.first?.used == 12)
            #expect(sent.withLock { $0.first?.value(forHTTPHeaderField: "Authorization") } == "Bearer keyring-token")

            let waiting = await CodexLimits().fetch(home: home, configured: []) { item in
                item == expectedItem ? .needsPermission : .missing
            }
            #expect(waiting.count == 1)
            #expect(waiting.first?.action == .allowKeychain)
            #expect(waiting.first?.problem == "To see these limits, allow access to Codex's login and choose Always Allow.")

            // When both auth.json and keyring exist, auth.json wins without asking the keychain.
            try #"{"tokens":{"access_token":"file-token","account_id":"acct-file"}}"#
                .write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
            sent.withLock { $0.removeAll() }
            let fileWins = await CodexLimits().fetch(home: home, configured: []) { _ in .needsPermission }
            #expect(fileWins.count == 1)
            #expect(fileWins.first?.id == "codex:acct-file")
            #expect(fileWins.first?.action == nil)
            #expect(sent.withLock { $0.first?.value(forHTTPHeaderField: "Authorization") } == "Bearer file-token")
        }
    }

    @Test func piReadsItsOwnFolderAndTheNamedOnes() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(PiLimits.folders(home: home, configured: []).map(\.path) == ["/Users/someone/.pi/agent"])
        #expect(PiLimits.folders(home: home, configured: ["/work/pi", "/Users/someone/.pi/agent/"]).map(\.path) == ["/work/pi", "/Users/someone/.pi/agent"])
    }

    @Test func environmentFoldersAreRememberedUntilTheyreGone() throws {
        let suite = "usagegraphs-tests-environment-folders"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(EnvironmentFolders.seen("CLAUDE_CONFIG_DIR", environment: ["CLAUDE_CONFIG_DIR": folder.path], defaults: defaults) == [folder.path])
        // Opened from Finder, without it set.
        #expect(EnvironmentFolders.seen("CLAUDE_CONFIG_DIR", environment: [:], defaults: defaults) == [folder.path])
        // A folder that doesn't exist isn't kept.
        #expect(EnvironmentFolders.seen("CLAUDE_CONFIG_DIR", environment: ["CLAUDE_CONFIG_DIR": "/nowhere"], defaults: defaults) == [folder.path])
        try FileManager.default.removeItem(at: folder)
        #expect(EnvironmentFolders.seen("CLAUDE_CONFIG_DIR", environment: [:], defaults: defaults).isEmpty)
        #expect(defaults.stringArray(forKey: "environmentFolders.CLAUDE_CONFIG_DIR") == [])
    }

    // MARK: Cards across readings

    @Test func aLoginOutOfSightKeepsItsCardQuietlyAtFirst() {
        let meter = LimitMeter.percent("session", "Session", used: 11, resetsAt: nil, period: 5 * 3600)
        let team = AccountLimits(id: "claude:a|team", provider: .claude, account: "Tasteskill", meters: [meter], updated: now.addingTimeInterval(-600))
        let personal = AccountLimits(id: "claude:b|me", provider: .claude, account: "Personal", meters: [meter], updated: now)
        var missingSince: [String: Date] = [:]

        var cards = LimitsSources.update([team, personal], with: [personal], asked: [.claude], missingSince: &missingSince, now: now)
        #expect(cards.map(\.id) == ["claude:b|me", "claude:a|team"])
        #expect(cards[1].problem == nil)
        cards = LimitsSources.update(cards, with: [personal], asked: [.claude], missingSince: &missingSince, now: now.addingTimeInterval(16 * 60))
        #expect(cards[1].problem == "Couldn't find this login. Sign in again if you signed out.")
        // Found again, it's itself, and a later miss starts over.
        cards = LimitsSources.update(cards, with: [personal, team], asked: [.claude], missingSince: &missingSince, now: now.addingTimeInterval(20 * 60))
        #expect(missingSince.isEmpty)
        // After a day it's taken as signed out.
        cards = LimitsSources.update([team, personal], with: [personal], asked: [.claude], missingSince: &missingSince, now: now.addingTimeInterval(86_400))
        #expect(cards.map(\.id) == ["claude:b|me"])
        // A provider that wasn't asked keeps its cards as they were.
        cards = LimitsSources.update([team, personal], with: [], asked: [], missingSince: &missingSince, now: now)
        #expect(cards.map(\.id) == ["claude:b|me", "claude:a|team"])
        #expect(cards.allSatisfy { $0.problem == nil })
    }

    @Test func onlyALoneCardIsTakenAsRenamed() {
        let meter = LimitMeter.percent("session", "Session", used: 11, resetsAt: nil, period: 5 * 3600)
        func card(_ id: String, _ name: String) -> AccountLimits {
            AccountLimits(id: id, provider: .claude, account: name, meters: [meter], updated: now)
        }
        var missingSince: [String: Date] = [:]
        // The same account under the ID a newer build gives it.
        var cards = LimitsSources.update([card("claude:a", "Tasteskill")], with: [card("claude:a|team", "Tasteskill")],
                                         asked: [.claude], missingSince: &missingSince, now: now)
        #expect(cards.map(\.id) == ["claude:a|team"])
        // Two "Personal" accounts: one out of sight isn't the other, nor a third that just signed in.
        cards = LimitsSources.update([card("claude:b", "Personal"), card("claude:c", "Personal")],
                                     with: [card("claude:c", "Personal"), card("claude:d", "Personal")],
                                     asked: [.claude], missingSince: &missingSince, now: now)
        #expect(Set(cards.map(\.id)) == ["claude:b", "claude:c", "claude:d"])
    }

    @Test func missingLoginRollsExpiredWindowsLikeExplicitFailures() {
        let previous = AccountLimits(id: "codex:fixture", provider: .codex, meters: [
            .percent("session", "Session", used: 100, resetsAt: now.addingTimeInterval(-60), period: 18_000),
        ], updated: now.addingTimeInterval(-120))
        var missing: [String: Date] = [:]
        let cards = LimitsSources.update([previous], with: [], asked: [.codex], missingSince: &missing, now: now)
        #expect(cards.first?.meters.first?.used == 0)
        #expect(cards.first?.meters.first?.resetsAt == nil)
    }

    @Test func loopbackCrossOriginRedirectBehavior() async throws {
        let other = try LoopbackServer { _, _ in
            (200, ["Content-Type": "application/json"], #"{"leaked":true}"#)
        }
        defer { other.stop() }
        let origin = try LoopbackServer { request, port in
            if request.hasPrefix("GET /same ") {
                return (307, ["Location": "http://127.0.0.1:\(port)/landed"], "")
            }
            if request.hasPrefix("GET /landed ") {
                return (200, ["Content-Type": "application/json"], #"{"sameOrigin":true}"#)
            }
            return (307, ["Location": "http://localhost:\(other.port)/landing"], "")
        }
        defer { origin.stop() }

        let getCross = try #require(await HTTP.get(
            "http://127.0.0.1:\(origin.port)/start",
            headers: ["Authorization": "Bearer fixture-only", "Cookie": "fixture-cookie=only"]
        ))
        #expect(getCross.status == 307)

        let postCross = try #require(await HTTP.post(
            "http://127.0.0.1:\(origin.port)/start",
            json: ["metadata": ["apiKey": "fixture-only"]]
        ))
        #expect(postCross.status == 307)
        #expect(other.requests.isEmpty)

        let sameOrigin = try #require(await HTTP.get("http://127.0.0.1:\(origin.port)/same"))
        #expect(sameOrigin.status == 200)
        #expect(sameOrigin.json?["sameOrigin"] as? Bool == true)
    }

    @Test func duplicateMissingAccountsTrapInLimitsSourcesUpdate() {
        let card = AccountLimits(
            id: "claude:acc|org",
            provider: .claude,
            account: "Personal",
            meters: [.percent("session", "Session", used: 42, resetsAt: now.addingTimeInterval(3600), period: 18_000)],
            updated: now.addingTimeInterval(-60)
        )
        var missingSince: [String: Date] = [:]
        let updated = LimitsSources.update([card, card], with: [], asked: [.claude], missingSince: &missingSince, now: now)
        #expect(updated == [card])
        #expect(missingSince == ["claude:acc|org": now])
    }

    @Test func rateLimitsCoolDownAndDoubleUpToAnHour() async throws {
        let clock = Mutex(now)
        let sent = Mutex<[URLRequest]>([])
        let reply = Mutex(HTTP.Response(status: 429, headers: ["retry-after": "3600"], data: Data()))

        try await HTTP.$now.withValue({ clock.withLock { $0 } }) {
            try await HTTP.$transport.withValue({ request in
                sent.withLock { $0.append(request) }
                return reply.withLock { $0 }
            }) {
                // A 429 with Retry-After: 3600 keeps the next call off the network, including Pi's profile lookup.
                for _ in 0..<2 {
                    let codex = await CodexLimits.limits(token: "n1-codex", accountID: "acct", provider: .codex, renew: "Run `codex`.")
                    #expect(codex.problem == "ChatGPT's usage API answered HTTP 429.")
                }
                #expect(sent.withLock { $0.count } == 1)

                let home = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-n1-pi-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: home) }
                let authURL = home.appendingPathComponent(".pi/agent/auth.json")
                try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try #"{"anthropic":{"type":"oauth","access":"n1-pi-token","expires":9999999999999}}"#
                    .write(to: authURL, atomically: true, encoding: .utf8)
                sent.withLock { $0.removeAll() }
                for _ in 0..<2 {
                    _ = await PiLimits().fetch(folders: [home.appendingPathComponent(".pi/agent")])
                }
                #expect(sent.withLock { $0.count } == 1)

                // Once the cooldown passes, a non-429 answer clears the key.
                clock.withLock { $0 = $0.addingTimeInterval(3601) }
                reply.withLock { $0 = HTTP.Response(status: 200, headers: [:], data: Data(#"{"ok":true}"#.utf8)) }
                let cleared = try #require(await HTTP.get("https://chatgpt.com/backend-api/wham/usage", headers: ["Authorization": "Bearer n1-codex"]))
                #expect(cleared.status == 200)
                #expect(sent.withLock { $0.count } == 2)

                // Without Retry-After, a 429 cools down for 5 minutes and each further 429 in a row doubles up to 1 hour.
                reply.withLock { $0 = HTTP.Response(status: 429, headers: [:], data: Data()) }
                let headers = ["Authorization": "Bearer n1-codex"]
                for expected in [300.0, 600, 1200, 2400, 3600, 3600] {
                    let countBefore = sent.withLock { $0.count }
                    let first = try #require(await HTTP.get("https://chatgpt.com/backend-api/wham/usage", headers: headers))
                    #expect(first.status == 429)
                    #expect(sent.withLock { $0.count } == countBefore + 1)

                    let cached = try #require(await HTTP.get("https://chatgpt.com/backend-api/wham/usage", headers: headers))
                    #expect(cached.status == 429)
                    #expect(cached.retryAfter == expected)
                    #expect(sent.withLock { $0.count } == countBefore + 1)

                    clock.withLock { $0 = $0.addingTimeInterval(expected + 1) }
                }
            }
        }
    }
}

private final class LoopbackServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var seen: [String] = []

    var requests: [String] { lock.withLock { seen } }

    init(handler: @escaping @Sendable (String, Int) -> (status: Int, headers: [String: String], body: String)) throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        try #require(sock >= 0)
        var yes: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(sock, 16) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        self.fd = sock
        self.port = port
        let lock = self.lock
        Thread.detachNewThread {
            while true {
                let client = accept(sock, nil, nil)
                if client < 0 { break }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(client, &buffer, buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                    if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                        let headerText = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                        let length = headerText.split(separator: "\r\n").compactMap { line -> Int? in
                            let parts = line.split(separator: ":", maxSplits: 1)
                            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                            return Int(parts[1].trimmingCharacters(in: .whitespaces))
                        }.first ?? 0
                        if data.count >= range.upperBound + length { break }
                    }
                }
                let request = String(decoding: data, as: UTF8.self)
                lock.withLock { self.seen.append(request) }
                let reply = handler(request, port)
                let body = Data(reply.body.utf8)
                var response = "HTTP/1.1 \(reply.status) OK\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
                for (name, value) in reply.headers { response += "\(name): \(value)\r\n" }
                response += "\r\n"
                let payload = Data(response.utf8) + body
                _ = payload.withUnsafeBytes { write(client, $0.baseAddress, payload.count) }
                close(client)
            }
        }
    }

    func stop() {
        close(fd)
    }
}

