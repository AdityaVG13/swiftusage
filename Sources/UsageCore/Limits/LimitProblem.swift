import Foundation

/// What kind of trouble an account's `problem` reports, for counting failed readings without their
/// wording, which can name an account. Read from the wording the sources share: `Login expired.`,
/// `Couldn't reach …`, `… answered HTTP 500.` and the like.
public enum LimitProblem: String, CaseIterable, Sendable {
    /// macOS has to be told to let the app read the login.
    case needsAccess = "needs_access"
    case loginExpired = "login_expired"
    /// The login the last reading found is gone.
    case loginMissing = "login_missing"
    /// The account has no limits to read, like a team account without a personal one.
    case notAvailable = "not_available"
    case unreachable
    case rateLimited = "rate_limited"
    case serviceUnavailable = "service_unavailable"
    case httpClientError = "http_4xx"
    case httpServerError = "http_5xx"
    /// The answer came in a shape the app doesn't know, as when a provider changes its API.
    case unexpectedResponse = "unexpected_response"
    case other

    /// Kinds the person's own setup explains, rather than the app or the provider failing.
    public var isExpected: Bool {
        switch self {
        case .needsAccess, .loginExpired, .loginMissing, .notAvailable: true
        default: false
        }
    }

    init(_ problem: String, action: LimitAction?) {
        func has(_ phrase: String) -> Bool { problem.localizedCaseInsensitiveContains(phrase) }
        if action != nil {
            self = .needsAccess
        } else if has("couldn't find this login") {
            self = .loginMissing
        } else if has("expired") || has("didn't accept this login") || has("rejected") || has("can't read limits") {
            self = .loginExpired
        } else if has("no personal limit") || has("no active subscription") {
            self = .notAvailable
        } else if has("couldn't reach") {
            self = .unreachable
        } else if has("limiting requests") {
            self = .rateLimited
        } else if has("unavailable right now") {
            self = .serviceUnavailable
        } else if let status = problem.range(of: #"(?<=answered HTTP )\d{3}"#, options: .regularExpression) {
            switch problem[status].first {
            case "4": self = .httpClientError
            case "5": self = .httpServerError
            default: self = .other
            }
        } else if has("unexpected") || has("no limits the app knows") || has("didn't report") {
            self = .unexpectedResponse
        } else {
            self = .other
        }
    }
}

extension AccountLimits {
    /// Nil when the reading worked.
    public var problemKind: LimitProblem? {
        problem.map { LimitProblem($0, action: action) }
    }
}
