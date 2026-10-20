import Foundation
import Testing
@testable import UsageCore

/// Using limit resets, against scripted answers: nothing here reaches ChatGPT or Anthropic.
struct ResetTests {
    let now = Date(timeIntervalSince1970: Timestamp.parse("2026-10-19T16:00:00Z")!)

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private func answer(_ status: Int, _ json: String = "{}") -> HTTP.Response {
        HTTP.Response(status: status, headers: [:], data: Data(json.utf8))
    }

    /// Answers requests in turn, and keeps what was sent.
    private final class Provider: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [HTTP.Response?]
        private var requests: [ResetClaims.Request] = []

        init(_ answers: [HTTP.Response?]) { self.answers = answers }

        var sent: [ResetClaims.Request] { lock.withLock { requests } }

        func send(_ request: ResetClaims.Request) -> HTTP.Response? {
            lock.withLock {
                requests.append(request)
                return answers.isEmpty ? nil : answers.removeFirst()
            }
        }
    }

    // MARK: Codex

    @Test func codexUsesTheFirstResetToLapse() {
        let body = object("""
            {"credits":[
              {"id":"late","status":"available","expires_at":"2026-11-10T00:00:00Z"},
              {"id":"never","status":"available","expires_at":null},
              {"id":"used","status":"redeemed","expires_at":"2026-10-20T00:00:00Z"},
              {"id":"lapsed","status":"available","expires_at":"2026-10-19T15:00:00Z"},
              {"id":"soon","expires_at":"2026-10-22T03:57:42.677034Z"}],
             "available_count":3}
            """)
        let credits = CodexLimits.resetCredits(body, now: now)
        #expect(credits.map(\.id) == ["soon", "late", "never"])
        #expect(credits[0].expires == Date(timeIntervalSince1970: Timestamp.parse("2026-10-22T03:57:42.677034Z")!))
    }

    @Test func codexReadsWhatAUseCameTo() {
        func outcome(_ response: HTTP.Response?) -> (ResetOutcome, Bool) {
            let result = CodexLimits.resetOutcome(response, renew: "Run `codex`.")
            return (result.outcome, result.settled)
        }
        #expect(outcome(answer(200, #"{"code":"reset","windows_reset":2}"#)) == (.reset, true))
        #expect(outcome(answer(200, #"{"code":"already_redeemed"}"#)) == (.usedEarlier, true))
        #expect(outcome(answer(200, #"{"code":"nothing_to_reset"}"#)) == (.notUsed("Your limits don't need a reset right now."), true))
        #expect(outcome(answer(200, #"{"code":"no_credit"}"#)) == (.notUsed("That reset is no longer available."), true))
        #expect(outcome(answer(401)) == (.notUsed("Login expired. Run `codex`."), false))
        // Answers that don't say whether a reset went keep the request for the next try.
        #expect(outcome(nil).1 == false)
        #expect(outcome(answer(502)).1 == false)
        #expect(outcome(answer(200, #"{"code":"something_new"}"#)).1 == false)
        if case .unsure = outcome(answer(200, "<html>")).0 {} else { Issue.record("an unreadable answer isn't known to have used nothing") }
    }

    @Test func codexAsksForTheResetItPicked() async {
        let provider = Provider([
            answer(200, #"{"credits":[{"id":"b","status":"available","expires_at":"2099-02-01T00:00:00Z"},{"id":"a","status":"available","expires_at":"2099-01-01T00:00:00Z"}]}"#),
            answer(200, #"{"code":"reset","windows_reset":2}"#),
        ])
        let claims = ResetClaims(send: provider.send)
        await claims.offer(.chatGPT(token: "tok", accountID: "acct", renew: ""), for: "codex:acct")
        #expect(await claims.use("codex:acct") == .reset)

        let sent = provider.sent
        #expect(sent.map(\.url) == [CodexLimits.resetsURL, CodexLimits.resetsURL + "/consume"])
        #expect(sent[0].body == nil)
        #expect(sent[1].body?["credit_id"] == "a")
        #expect(UUID(uuidString: sent[1].body?["redeem_request_id"] ?? "") != nil)
        #expect(sent[1].headers["Authorization"] == "Bearer tok")
        #expect(sent[1].headers["ChatGPT-Account-Id"] == "acct")
        #expect(sent[1].headers["originator"] == "Codex Desktop")
    }

    @Test func codexRepeatsARequestWhoseAnswerWasLost() async {
        let list = answer(200, #"{"credits":[{"id":"a","status":"available","expires_at":"2099-01-01T00:00:00Z"}]}"#)
        let provider = Provider([list, nil, answer(200, #"{"code":"already_redeemed"}"#), list, answer(200, #"{"code":"nothing_to_reset"}"#)])
        let claims = ResetClaims(send: provider.send)
        await claims.offer(.chatGPT(token: "tok", accountID: nil, renew: ""), for: "codex:x")

        guard case .unsure = await claims.use("codex:x") else { Issue.record("a lost answer isn't known to have used nothing"); return }
        // The retry sends the same request for the same reset, without listing them again.
        #expect(await claims.use("codex:x") == .usedEarlier)
        // Settled, so the next use is a new request.
        #expect(await claims.use("codex:x") == .notUsed("Your limits don't need a reset right now."))

        let consumes = provider.sent.filter { $0.body != nil }
        #expect(provider.sent.count == 5)
        #expect(consumes.count == 3)
        #expect(consumes[0].body == consumes[1].body)
        #expect(consumes[2].body?["credit_id"] == "a")
        #expect(consumes[2].body?["redeem_request_id"] != consumes[0].body?["redeem_request_id"])
    }

    @Test func onlyARepeatThatWasTurnedDownKeepsItsRequest() async {
        let list = answer(200, #"{"credits":[{"id":"a","status":"available","expires_at":"2099-01-01T00:00:00Z"}]}"#)
        let provider = Provider([list, answer(400), list, nil, answer(401), answer(200, #"{"code":"reset"}"#)])
        let claims = ResetClaims(send: provider.send)
        await claims.offer(.chatGPT(token: "tok", accountID: nil, renew: ""), for: "codex:x")

        // A first try turned down used nothing, so the next one lists the resets again with a new request.
        guard case .notUsed = await claims.use("codex:x") else { Issue.record("a turned-down try uses nothing"); return }
        guard case .unsure = await claims.use("codex:x") else { Issue.record("a lost answer isn't known to have used nothing"); return }
        // A repeat turned down doesn't settle the try before it, so the one after sends the same request.
        guard case .unsure = await claims.use("codex:x") else { Issue.record("a turned-down repeat isn't known to have used nothing"); return }
        #expect(await claims.use("codex:x") == .reset)

        let consumes = provider.sent.filter { $0.body != nil }
        #expect(provider.sent.count == 6)
        #expect(consumes.count == 4)
        #expect(consumes[1].body?["redeem_request_id"] != consumes[0].body?["redeem_request_id"])
        #expect(consumes[1].body == consumes[2].body)
        #expect(consumes[2].body == consumes[3].body)
    }

    @Test func unauthorizedRetryMustNotClaimEarlierResetWasUnused() async {
        let list = answer(200, #"{"credits":[{"id":"a","status":"available","expires_at":"2099-01-01T00:00:00Z"}]}"#)
        let chatGPT = Provider([list, nil, answer(401), answer(200, #"{"code":"already_redeemed"}"#)])
        let codexClaims = ResetClaims(send: chatGPT.send)
        await codexClaims.offer(.chatGPT(token: "tok", accountID: nil, renew: "Run `codex` to renew it."), for: "codex:x")

        #expect(await codexClaims.use("codex:x") == .unsure("ChatGPT didn't answer."))
        #expect(await codexClaims.use("codex:x") == .unsure("Login expired. Run `codex` to renew it."))
        #expect(await codexClaims.use("codex:x") == .usedEarlier)
        let consumes = chatGPT.sent.filter { $0.body != nil }
        #expect(consumes.count == 3)
        #expect(consumes[0].body == consumes[1].body)
        #expect(consumes[1].body == consumes[2].body)

        let organization = "4f2c1f39-6a3e-4d6f-9a51-6f0f2b6f2f10"
        let anthropic = Provider([nil, answer(401), answer(200, #"{"result":"already_used"}"#)])
        let claudeClaims = ResetClaims(send: anthropic.send)
        await claudeClaims.offer(.anthropic(token: "tok", organization: organization, grant: "g1", renew: "Run `claude` to renew it."), for: "claude:a|o")

        #expect(await claudeClaims.use("claude:a|o") == .unsure("Anthropic didn't answer."))
        #expect(await claudeClaims.use("claude:a|o") == .unsure("Login expired. Run `claude` to renew it."))
        #expect(await claudeClaims.use("claude:a|o") == .usedEarlier)
        #expect(anthropic.sent.count == 3)
        #expect(anthropic.sent[0].body == anthropic.sent[1].body)
        #expect(anthropic.sent[1].body == anthropic.sent[2].body)
    }

    @Test func codexStopsWhenNoResetIsLeft() async {
        let provider = Provider([answer(200, #"{"credits":[],"available_count":0}"#)])
        let claims = ResetClaims(send: provider.send)
        await claims.offer(.chatGPT(token: "tok", accountID: nil, renew: ""), for: "codex:x")
        #expect(await claims.use("codex:x") == .notUsed("That reset is no longer available."))
        #expect(provider.sent.count == 1)
    }

    // MARK: Claude

    @Test func claudeReadsItsGrants() {
        let body = object("""
            {"eligible":true,"ineligible_reason":null,"at_limit":false,
             "grants":[
               {"id":"opus55-launch-promax-20260921","resets_total":2,"resets_left":2,"starts_at":"2026-09-22T16:00:00+00:00",
                "ends_at":"2026-10-22T16:00:00+00:00","clears":["five_hour","seven_day","seven_day_overage_included"],"paused":false},
               {"id":"spent","resets_left":0,"ends_at":"2026-10-21T16:00:00+00:00","clears":["five_hour"]},
               {"id":"over","resets_left":1,"ends_at":"2026-10-18T16:00:00+00:00","clears":["five_hour"]},
               {"id":"forever","resets_left":1,"ends_at":null,"clears":["seven_day"]}],
             "next_grant_id":"opus55-launch-promax-20260921","cooldown_until":null}
            """)
        let grants = ResetGrants(body)
        #expect(grants?.usable(now: now) == "opus55-launch-promax-20260921")
        #expect(grants?.resets(now: now) == LimitResets(available: 3, nextExpiry: Date(timeIntervalSince1970: Timestamp.parse("2026-10-22T16:00:00Z")!),
                                                        refills: ["session", "weekly"], usable: true))

        // Accounts outside the program, and blocks with a grant that can't be read in full, have none.
        #expect(ResetGrants(nil) == nil)
        #expect(ResetGrants(object(#"{"eligible":true,"grants":[{"id":"a"}],"next_grant_id":"a"}"#)) == nil)
        let surface = ResetGrants(object(#"{"eligible":false,"ineligible_reason":"surface","grants":[{"id":"a","resets_left":1}],"next_grant_id":"a"}"#))
        #expect(surface?.resets(now: now) == nil)
        #expect(surface?.usable(now: now) == nil)
        // A next grant with nothing left, or with an ID Anthropic wouldn't take, can't be used.
        #expect(ResetGrants(object(#"{"eligible":true,"grants":[{"id":"a","resets_left":0},{"id":"b","resets_left":1}],"next_grant_id":"a"}"#))?.usable(now: now) == nil)
        let odd = ResetGrants(object(#"{"eligible":true,"grants":[{"id":"../x","resets_left":1}],"next_grant_id":"../x"}"#))
        #expect(odd?.usable(now: now) == nil)
        #expect(odd?.resets(now: now) == LimitResets(available: 1, usable: false))
    }

    @Test func claudeReadsWhatAUseCameTo() {
        func outcome(_ response: HTTP.Response?) -> (ResetOutcome, Bool) {
            let result = AnthropicUsage.resetOutcome(response, renew: "Run `claude`.", now: now)
            return (result.outcome, result.settled)
        }
        // The answers OpenUsage saw from Anthropic: a reset, and a grant that matched nothing.
        #expect(outcome(answer(200, """
            {"result":"reset","reason":null,"reset":true,"grant_id":"opus55-launch-promax-20260921","resets_left":0,
             "cleared":["five_hour","seven_day","seven_day_overage_included"],"weekly_resets_at":"2026-10-20T20:00:00+00:00",
             "cooldown_until":"2026-10-18T11:56:45.910978+00:00"}
            """)) == (.reset, true))
        #expect(outcome(answer(200, #"{"result":"ineligible","reason":"unknown_grant","reset":false,"grant_id":"x","resets_left":null,"cleared":[]}"#))
            == (.notUsed("That reset is no longer available."), true))
        #expect(outcome(answer(200, #"{"result":"already_used"}"#)) == (.usedEarlier, true))
        #expect(outcome(answer(200, #"{"result":"not_limited"}"#)) == (.notUsed("Your limits don't need a reset right now."), true))
        #expect(outcome(answer(200, #"{"result":"unavailable","reason":"not_next_grant"}"#)) == (.notUsed("That reset is no longer available."), true))
        #expect(outcome(answer(200, #"{"result":"unavailable","reason":"paused"}"#)) == (.notUsed("This reset can't be used right now."), true))
        if case .notUsed(let why) = outcome(answer(200, #"{"result":"cooldown","cooldown_until":"2026-10-19T16:02:00.5+00:00"}"#)).0 {
            #expect(why.hasPrefix("This reset can be used again in "))
        } else {
            Issue.record("a cooldown uses nothing")
        }
        #expect(outcome(answer(401)) == (.notUsed("Login expired. Run `claude`."), false))
        #expect(outcome(answer(200, #"{"result":"reset_unconfirmed"}"#)) == (.unsure("Anthropic hasn't confirmed the reset yet."), false))
        #expect(outcome(answer(503)).1 == false)
        #expect(outcome(nil).1 == false)
    }

    @Test func claudeAsksAsClaudeCodeAndRepeatsAnUnsettledRequest() async {
        let organization = "4f2c1f39-6a3e-4d6f-9a51-6f0f2b6f2f10"
        let provider = Provider([answer(503), answer(200, #"{"result":"already_used"}"#)])
        let claims = ResetClaims(send: provider.send)
        await claims.offer(.anthropic(token: "tok", organization: organization, grant: "g1", renew: ""), for: "claude:a|o")

        guard case .unsure = await claims.use("claude:a|o") else { Issue.record("a server error isn't known to have used nothing"); return }
        #expect(await claims.use("claude:a|o") == .usedEarlier)

        let sent = provider.sent
        #expect(sent.count == 2)
        #expect(sent[0].url == "https://api.anthropic.com/api/organizations/\(organization)/reset_rate_limits")
        #expect(sent[0].body?["program"] == "cedar_ember")
        #expect(sent[0].body?["grant_id"] == "g1")
        #expect(sent[0].body?["request_id"]?.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil)
        #expect(sent[0].body == sent[1].body)
        #expect(sent[0].headers["Authorization"] == "Bearer tok")
        #expect(sent[0].headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(sent[0].headers["User-Agent"]?.hasPrefix("claude-cli/") == true)
        #expect(sent[0].timeout == 25)
    }

    @Test func nothingIsSentWithoutAUsableLogin() async {
        let provider = Provider([answer(200, #"{"result":"reset"}"#)])
        let claims = ResetClaims(send: provider.send)
        guard case .notUsed = await claims.use("claude:a|o") else { Issue.record("an account without a login has nothing to use"); return }
        await claims.offer(.anthropic(token: "tok", organization: "../../oauth/usage", grant: "g1", renew: ""), for: "claude:a|o")
        guard case .notUsed = await claims.use("claude:a|o") else { Issue.record("an organization that isn't a UUID can't go in the address"); return }
        // A reading that found none takes the login back.
        await claims.offer(.chatGPT(token: "tok", accountID: nil, renew: ""), for: "codex:x")
        await claims.offer(nil, for: "codex:x")
        guard case .notUsed = await claims.use("codex:x") else { Issue.record("a withdrawn login has nothing to use"); return }
        #expect(provider.sent.isEmpty)
    }
}
