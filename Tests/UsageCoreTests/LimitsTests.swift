import CommonCrypto
import Foundation
import Testing
@testable import UsageCore

struct LimitsTests {
    let now = Date(timeIntervalSince1970: Timestamp.parse("2026-10-19T16:00:00Z")!)

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
        let cards = await AntigravityLimits().fetch(home: nowhere, keychain: keychain)
        #expect(cards.map(\.id) == ["antigravity:" + "app".sha256Prefix, "antigravity:keychain"])
        #expect(cards.last?.action == .allowKeychain)
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
        let source = AntigravityLimits()
        let login = AntigravityLimits.Login(refresh: "1//fixture")
        _ = await source.session(for: login) { _ in .renewed("tok", .distantPast, "user@example.com") }
        let rejected = await source.session(for: login) { _ in .rejected }
        #expect(rejected.email == "user@example.com")
        #expect(rejected.problem == "Login expired. Open Antigravity or run `agy` to sign in again.")
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

    @Test func piReadsItsOwnFolderAndTheNamedOnes() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(PiLimits.folders(home: home, configured: []).map(\.path) == ["/Users/someone/.pi/agent"])
        #expect(PiLimits.folders(home: home, configured: ["/work/pi", "/Users/someone/.pi/agent/"]).map(\.path) == ["/work/pi", "/Users/someone/.pi/agent"])
    }

    @Test func environmentFoldersAreRememberedUntilTheyreGone() throws {
        let suite = "usagegraphs-tests-\(UUID().uuidString)"
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
}
