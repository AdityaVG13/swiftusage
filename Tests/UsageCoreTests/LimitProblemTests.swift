import Testing
@testable import UsageCore

/// Failed readings counted by kind, from the wording the limits sources use.
struct LimitProblemTests {
    @Test(arguments: [
        ("Login expired. Run `claude` to renew it.", LimitProblem.loginExpired),
        ("Google didn't accept this login. Open Antigravity to sign in again.", .loginExpired),
        ("This login can't read limits. Sign in again with `claude`.", .loginExpired),
        ("The OpenCode Go key has expired. Add a new one in OpenCode.", .loginExpired),
        ("OpenCode rejected the Go key. Sign in to OpenCode Go again.", .loginExpired),
        ("Couldn't find this login. Sign in again if you signed out.", .loginMissing),
        ("Team accounts have no personal limit.", .notAvailable),
        ("This OpenCode Go key has no active subscription.", .notAvailable),
        ("Couldn't reach Anthropic.", .unreachable),
        ("Anthropic is limiting requests. Trying again in a few minutes.", .rateLimited),
        ("xAI's usage service is unavailable right now.", .serviceUnavailable),
        ("ChatGPT's usage API answered HTTP 404.", .httpClientError),
        ("Cursor's usage API answered HTTP 502.", .httpServerError),
        ("Factory didn't accept this login. Run `droid` to sign in again.", .loginExpired),
        ("This Factory account has no active subscription.", .notAvailable),
        ("Devin's usage API sent something unexpected.", .unexpectedResponse),
        ("Anthropic's usage API sent no limits the app knows.", .unexpectedResponse),
        ("Cursor didn't report included usage for this plan.", .unexpectedResponse),
        ("Something nobody wrote yet.", .other),
    ])
    func sortsEachSourcesWording(_ problem: String, _ kind: LimitProblem) {
        #expect(AccountLimits(id: "x", provider: .claude, problem: problem).problemKind == kind)
    }

    @Test func anAccountThePersonCanFixFromItsCardNeedsAccess() {
        let account = AccountLimits(id: "x", provider: .claude, problem: "Claude Desktop is signed in to an account Claude Code isn't. To see these limits, allow access to Claude Desktop's login and choose Always Allow.",
                                    action: .allowClaudeDesktop)
        #expect(account.problemKind == .needsAccess)
    }

    @Test func aReadingThatWorkedHasNoKind() {
        #expect(AccountLimits(id: "x", provider: .claude).problemKind == nil)
    }

    @Test func expectedKindsAreTheOnesThePersonsSetupExplains() {
        #expect(LimitProblem.allCases.filter(\.isExpected) == [.needsAccess, .loginExpired, .loginMissing, .notAvailable])
    }
}
