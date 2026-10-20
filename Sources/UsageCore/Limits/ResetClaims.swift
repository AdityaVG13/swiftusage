import Foundation

/// What came of using a limit reset, worded for the account's card.
public enum ResetOutcome: Sendable, Equatable {
    /// The limits were refilled.
    case reset
    /// The try before, whose answer was lost, used a reset after all; this one used none.
    case usedEarlier
    /// No reset was used, for this reason.
    case notUsed(String)
    /// It isn't known whether a reset was used. Trying again sends the same request, which can't use a
    /// second one.
    case unsure(String)
}

/// Uses the limit resets Codex and Claude hand out, with the login the account's last reading used.
///
/// The only request the app makes that changes anything, so it's kept narrow: one reset per use, never
/// on its own. Each use carries a request ID the provider tells repeats apart by. Until an answer
/// settles it, the ID is kept with the reset it named and sent again on the next try, so a request
/// whose answer was lost comes back as already used instead of using a second reset.
public actor ResetClaims {
    public static let shared = ResetClaims()

    enum Login: Sendable, Equatable {
        /// A ChatGPT login: Codex's, or Pi's.
        case chatGPT(token: String, accountID: String?, renew: String)
        /// A Claude login with the grant Anthropic names as next.
        case anthropic(token: String, organization: String, grant: String, renew: String)
    }

    struct Request: Sendable, Equatable {
        var url: String
        var headers: [String: String]
        /// Posted as JSON; a GET without one.
        var body: [String: String]?
        var timeout: TimeInterval = 15
    }

    static let network: @Sendable (Request) async -> HTTP.Response? = { request in
        guard let body = request.body else { return await HTTP.get(request.url, headers: request.headers, timeout: request.timeout) }
        return await HTTP.post(request.url, headers: request.headers, json: body, timeout: request.timeout)
    }

    private let send: @Sendable (Request) async -> HTTP.Response?
    private var logins: [String: Login] = [:]
    /// By account: the reset the last request named and its ID, until an answer settles them.
    private var unsettled: [String: (target: String, request: String)] = [:]

    init(send: @escaping @Sendable (Request) async -> HTTP.Response? = ResetClaims.network) {
        self.send = send
    }

    /// Called with each reading: the login to use the account's resets with, or nil when it has none to use.
    func offer(_ login: Login?, for account: String) {
        logins[account] = login
    }

    /// Uses one of the account's resets.
    public func use(_ account: String) async -> ResetOutcome {
        let repeating = unsettled[account] != nil
        switch logins[account] {
        case nil:
            return .notUsed("Couldn't find a reset to use. Refresh the limits and try again.")
        case let .chatGPT(token, accountID, renew):
            let headers = CodexLimits.resetHeaders(token: token, accountID: accountID)
            let target: String
            if let pending = unsettled[account] {
                target = pending.target
            } else {
                // A fresh list, so the reset named is still there: the first to lapse, as the Codex CLI picks.
                guard let list = await send(Request(url: CodexLimits.resetsURL, headers: headers)) else {
                    return .notUsed("Couldn't reach ChatGPT.")
                }
                switch list.status {
                case 200..<300: break
                case 401, 403: return .notUsed("Login expired. \(renew)")
                default: return .notUsed("ChatGPT's list of resets answered HTTP \(list.status).")
                }
                guard let credit = CodexLimits.resetCredits(list.json ?? [:]).first else {
                    return .notUsed("That reset is no longer available.")
                }
                target = credit.id
            }
            let (credit, request) = pendingRequest(for: account, target: target)
            let response = await send(Request(url: CodexLimits.resetsURL + "/consume", headers: headers,
                                              body: ["redeem_request_id": request, "credit_id": credit]))
            return settle(account, request: request, CodexLimits.resetOutcome(response, renew: renew), repeating: repeating)
        case let .anthropic(token, organization, grant, renew):
            // It goes in the address.
            guard UUID(uuidString: organization) != nil else { return .notUsed("Anthropic sent an organization the app doesn't know.") }
            let (target, request) = pendingRequest(for: account, target: grant)
            let response = await send(AnthropicUsage.resetRequest(token: token, organization: organization, grant: target, request: request))
            let outcome = settle(account, request: request, AnthropicUsage.resetOutcome(response, renew: renew), repeating: repeating)
            await AnthropicUsage.shared.forgetResetGrants(account)
            return outcome
        }
    }

    /// The request still waiting for an answer, or a new one for `target`.
    private func pendingRequest(for account: String, target: String) -> (target: String, request: String) {
        if let pending = unsettled[account] { return pending }
        let fresh = (target: target, request: UUID().uuidString.lowercased())
        unsettled[account] = fresh
        return fresh
    }

    /// Forgets the request once its answer settles it. A first try that was turned down used nothing, so it
    /// settles too; a repeat that was turned down doesn't say what came of the try before it.
    private func settle(_ account: String, request: String, _ answer: (outcome: ResetOutcome, settled: Bool), repeating: Bool) -> ResetOutcome {
        var settled = answer.settled
        if !repeating, case .notUsed = answer.outcome { settled = true }
        if settled, unsettled[account]?.request == request { unsettled[account] = nil }
        if repeating, !settled, case .notUsed(let why) = answer.outcome { return .unsure(why) }
        return answer.outcome
    }
}
