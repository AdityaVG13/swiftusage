import CryptoKit
import Foundation

/// Factory Droid's plan limits, read with the login its CLI keeps. The CLI seals its credentials with
/// AES-GCM as `iv:tag:ciphertext`, base64, under a 32-byte key it keeps in the login keychain ("Factory
/// CLI", `auth-encryption-key-security-cli`); a copy told not to use the keychain keeps `auth.v2.keyring`
/// under "Factory CLI" / `auth-encryption-key`, and one with no keychain at all keeps `auth.v2.file` beside
/// the plain `auth.v2.key`. The sealed login holds the access token and the region it belongs to.
///
/// `GET /api/billing/limits` reports the plan's 5-hour, weekly and monthly windows, whether a plan is on,
/// and the extra-usage balance. The login is only read, never renewed or written back: Droid refreshes it
/// itself when it runs.
public struct DroidLimits: LimitsSource {
    public let provider = Provider.droid
    private static let global = URL(string: "https://api.factory.ai")!
    private static let europe = URL(string: "https://api.eu.factory.ai")!

    public init() {}

    public func fetch() async -> [AccountLimits] {
        await fetch(home: .home)
    }

    func fetch(home: URL) async -> [AccountLimits] {
        let root = (URL.environment("FACTORY_HOME_OVERRIDE") ?? home).appendingPathComponent(".factory")
        switch Self.credentials(root: root) {
        case .none:
            return []
        case let .waiting(item, store):
            Keychain.wait("droid:" + store, on: item)
            return [AccountLimits(id: "droid:" + store, provider: .droid,
                                  problem: "To see these limits, allow access to Droid's login and choose Always Allow.",
                                  action: .allowKeychain)]
        case let .found(login):
            return [await Self.limits(login, plan: Self.plan(root: root))]
        }
    }

    struct Login: Sendable {
        var token: String
        var base: URL
        /// The account the plan belongs to, when the login names one.
        var account: String?
        var id: String
    }

    enum Credentials {
        case found(Login)
        /// The sealed file is there, but its key needs the person to allow it.
        case waiting(Keychain.Item, store: String)
        case none

        var login: Login? { if case let .found(login) = self { login } else { nil } }
    }

    // MARK: - The login

    enum KeyReading {
        case key(Data)
        case needsPermission
        case missing
    }

    static func credentials(root: URL) -> Credentials {
        // The login keychain first, as the CLI writes that unless it was told not to.
        if let sealed = try? String(contentsOf: root.appendingPathComponent("auth.v2.loginkeychain"), encoding: .utf8) {
            let item = Keychain.Item(service: "Factory CLI", account: "auth-encryption-key-security-cli")
            switch key(from: item) {
            case .key(let key): return opened(sealed, key: key, store: "loginkeychain")
            case .needsPermission: return .waiting(item, store: "loginkeychain")
            case .missing: break
            }
        }
        if let sealed = try? String(contentsOf: root.appendingPathComponent("auth.v2.keyring"), encoding: .utf8) {
            let item = Keychain.Item(service: "Factory CLI", account: "auth-encryption-key")
            switch key(from: item) {
            case .key(let key): return opened(sealed, key: key, store: "keyring")
            case .needsPermission: return .waiting(item, store: "keyring")
            case .missing: break
            }
        }
        if let sealed = try? String(contentsOf: root.appendingPathComponent("auth.v2.file"), encoding: .utf8),
           let written = try? String(contentsOf: root.appendingPathComponent("auth.v2.key"), encoding: .utf8),
           let key = written.decoded {
            return opened(sealed, key: key, store: "file")
        }
        return .none
    }

    /// A keychain item's password is the base64 key.
    private static func key(from item: Keychain.Item) -> KeyReading {
        switch Keychain.password(item) {
        case .password(let base64):
            guard let key = base64.decoded else { return .missing }
            return .key(key)
        case .missing: return .missing
        case .needsPermission: return .needsPermission
        }
    }

    private static func opened(_ sealed: String, key: Data, store: String) -> Credentials {
        guard let auth = open(sealed, key: key) else { return .none }
        guard let token = auth["access_token"] as? String, !token.isEmpty else { return .none }
        let claims = JWT.claims(token)
        let region = (auth["whoami"] as? [String: Any])?["inferenceRegion"] as? String
        let account = claims?["email"] as? String ?? auth["active_organization_id"] as? String
        let id = account.map { "droid:" + $0 } ?? "droid:" + store
        return .found(Login(token: token, base: region == "eu" ? europe : global, account: account, id: id))
    }

    /// The sealed text: base64 nonce, base64 tag and base64 ciphertext, in that order.
    static func open(_ sealed: String, key: Data) -> [String: Any]? {
        let parts = sealed.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let nonce = Data(base64Encoded: String(parts[0])),
              let tag = Data(base64Encoded: String(parts[1])),
              let ciphertext = Data(base64Encoded: String(parts[2])),
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key))
        else { return nil }
        return JSONValue.object(plain)
    }

    /// The tier the organization's managed settings name, as the CLI caches them.
    static func plan(root: URL) -> String? {
        for name in ["org-managed-settings.cache.json", "org-managed-settings.json"] {
            guard let object = JSONValue.object(file: root.appendingPathComponent(name)),
                  let tier = object["factoryTier"] as? String, !tier.isEmpty else { continue }
            return tier.prefix(1).uppercased() + String(tier.dropFirst())
        }
        return nil
    }

    // MARK: - The limits

    static func limits(_ login: Login, plan: String?) async -> AccountLimits {
        if let expiry = JWT.expiry(login.token), expiry <= Date() {
            return .failed(login.id, .droid, account: login.account, plan: plan, "Login expired. Run `droid` to sign in again.")
        }
        let headers = ["Authorization": "Bearer " + login.token, "Accept": "application/json"]
        guard let response = await HTTP.get(login.base.absoluteString + "/api/billing/limits", headers: headers) else {
            return .failed(login.id, .droid, account: login.account, plan: plan, "Couldn't reach Factory.")
        }
        switch response.status {
        case 200..<300: break
        case 401, 403: return .failed(login.id, .droid, account: login.account, plan: plan, "Factory turned this login away. Run `droid` to sign in again.")
        case 429: return .failed(login.id, .droid, account: login.account, plan: plan, "Factory is limiting requests. Try again in a little while.")
        case 500...: return .failed(login.id, .droid, account: login.account, plan: plan, "Factory's usage service is unavailable right now.")
        default: return .failed(login.id, .droid, account: login.account, plan: plan, "Factory's usage API answered HTTP \(response.status).")
        }
        guard let body = response.json else {
            return .failed(login.id, .droid, account: login.account, plan: plan, "Factory's usage API sent something unexpected.")
        }
        return limits(body, id: login.id, account: login.account, plan: plan)
    }

    /// One answer from `GET /api/billing/limits`: the plan's three windows, whether it's on, and the
    /// extra-usage balance. The `core` windows are the models Droid falls back to and carry no plan limit.
    static func limits(_ body: [String: Any], id: String, account: String?, plan: String?) -> AccountLimits {
        var result = AccountLimits(id: id, provider: .droid, account: account, plan: plan)
        let standard = (body["limits"] as? [String: Any])?["standard"] as? [String: Any]
        let windows: [(key: String, id: String, label: String, period: TimeInterval)] = [
            ("fiveHour", "5-hour", "5-hour", 5 * .hour),
            ("weekly", "weekly", "Weekly", 7 * .day),
            ("monthly", "monthly", "This month", 30 * .day),
        ]
        for window in windows {
            guard let entry = standard?[window.key] as? [String: Any],
                  let used = JSONValue.number(entry["usedPercent"]) else { continue }
            result.meters.append(.percent(window.id, window.label, used: used,
                                          resetsAt: JSONValue.date(entry["windowEnd"]), period: window.period))
        }
        if let cents = JSONValue.number(body["extraUsageBalanceCents"]), cents > 0 {
            result.notes.append(LimitNote(id: "extra-usage", label: "Extra usage", value: Format.dollars(cents / 100)))
        }
        if body["hasActiveSubscription"] as? Bool == false {
            result.problem = "No Factory plan is on this account."
        } else if !result.hasValues {
            result.problem = "Factory's usage API sent something unexpected."
        }
        return result
    }
}

private extension String {
    /// The base64 text as bytes, or nil when it isn't base64.
    var decoded: Data? {
        Data(base64Encoded: trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
