import Foundation
import Synchronization

/// Pi runs on the subscriptions it's signed in to, so its limits are theirs: the Claude, ChatGPT and xAI
/// logins in Pi's `auth.json` (`~/.pi/agent`, and `$PI_CODING_AGENT_DIR` now or before). A subscription
/// that another tool is signed in to as well shows once, on that tool's card, marked as shared with Pi.
public struct PiLimits: LimitsSource {
    public let provider = Provider.pi
    private static let renew = "Run `pi` to renew it."
    /// Whose each Claude login is, by where it's kept (an `auth.json` and its entry), so an expired one keeps
    /// its account's card after a relaunch.
    private let identities: Remembered<Identity>

    struct Identity: Codable, Sendable, Equatable {
        var id: String
        var name: String
        /// The hash of the token it was learned from. A token Pi wrote over it later, perhaps for another
        /// account, isn't taken to be this one's until it's been read.
        var token: String
    }

    public init() {
        self.init(identitiesURL: Remembered<Identity>.inCaches("pi-accounts.json"))
    }

    init(identitiesURL: URL) {
        identities = Remembered(identitiesURL)
    }

    struct Login: Equatable {
        enum Service: Equatable {
            case claude, chatGPT, xai
        }

        var service: Service
        /// Its entry in `auth.json`, such as `anthropic`.
        var key: String
        var access: String
        var expires: Date?
        var accountID: String?
    }

    public func fetch() async -> [AccountLimits] {
        await fetch(folders: Self.folders())
    }

    func fetch(folders: [URL]) async -> [AccountLimits] {
        var results: [AccountLimits] = []
        for folder in folders {
            guard let auth = JSONValue.object(file: folder.appendingPathComponent("auth.json")) else { continue }
            for login in Self.logins(auth) {
                results.append(await limits(login, slot: folder.standardizedFileURL.path + "#" + login.key))
            }
        }
        return results
    }

    /// The folders `PI_CODING_AGENT_DIR` names now or has named before, then Pi's own, which it uses
    /// whenever that isn't set.
    static func folders(home: URL = .home, configured: [String] = EnvironmentFolders.seen("PI_CODING_AGENT_DIR")) -> [URL] {
        let folders = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } + [home.appendingPathComponent(".pi/agent")]
        var seen: Set<String> = []
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    func identity(for access: String, in slot: String, expired: Bool, profile: AnthropicUsage.Profile? = nil) -> Identity {
        let token = access.sha256Prefix
        if !expired, let profile {
            let identity = Identity(id: profile.id, name: ["Claude", profile.label].compactMap { $0 }.joined(separator: " · "), token: token)
            identities.set(identity, for: slot)
            return identity
        }
        if let known = identities[slot], known.token == token { return known }
        return Identity(id: "pi-claude:" + token, name: "Claude", token: token)
    }

    private func limits(_ login: Login, slot: String) async -> AccountLimits {
        let expired = login.expires.map { $0 < Date() } ?? false
        switch login.service {
        case .claude:
            if expired {
                let identity = identity(for: login.access, in: slot, expired: true)
                return .failed(identity.id, provider, account: identity.name, "Login expired. \(Self.renew)")
            }
            var identity = identity(for: login.access, in: slot, expired: false, profile: await AnthropicUsage.shared.profile(token: login.access))
            var result = await AnthropicUsage.shared.limits(id: identity.id, provider: provider, account: identity.name, token: login.access,
                                                            renew: Self.renew, plan: nil)
            // Without its profile the account has only a stand-in ID, which a later reading would leave behind as
            // a missing login. The lookup the limits reading makes may have found it; else nothing read is kept
            // under the stand-in.
            if result.hasValues, identity.id.hasPrefix("pi-claude:") {
                guard let profile = await AnthropicUsage.shared.knownProfile(token: login.access) else {
                    return .failed(identity.id, provider, account: identity.name, plan: result.plan, "Couldn't reach Anthropic.")
                }
                identity = self.identity(for: login.access, in: slot, expired: false, profile: profile)
                result.id = identity.id
                result.account = identity.name
            }
            return result
        case .chatGPT:
            var result = await CodexLimits.limits(token: login.access, accountID: login.accountID, provider: provider, renew: Self.renew)
            result.account = ["ChatGPT", result.account].compactMap { $0 }.joined(separator: " · ")
            return result
        case .xai:
            let claims = JWT.claims(login.access)
            let id = "grok:" + ((claims?["sub"] as? String) ?? login.access.sha256Prefix)
            let email = claims?["email"] as? String
            let name = ["Grok", email].compactMap { $0 }.joined(separator: " · ")
            if expired { return .failed(id, provider, account: name, "Login expired. \(Self.renew)") }
            return await GrokLimits.limits(token: login.access, id: id, account: name, provider: provider, renew: Self.renew)
        }
    }

    /// Subscription logins, saved by provider as `{"type": "oauth", "access", "refresh", "expires"}` with
    /// `expires` in milliseconds. Numbered copies (`openai-codex-2`) are further accounts.
    static func logins(_ auth: [String: Any]) -> [Login] {
        auth.sorted { $0.key < $1.key }.compactMap { key, value -> Login? in
            guard let entry = value as? [String: Any], entry["type"] as? String == "oauth",
                  let access = entry["access"] as? String, !access.isEmpty else { return nil }
            let base = key.replacingOccurrences(of: "-\\d+$", with: "", options: .regularExpression)
            let service: Login.Service
            switch base {
            case "anthropic": service = .claude
            case "openai-codex": service = .chatGPT
            case "xai": service = .xai
            default: return nil
            }
            let accountID = entry["accountId"] as? String
                ?? JWT.claims(access)?[path: "https://api.openai.com/auth", "chatgpt_account_id"] as? String
            return Login(service: service, key: key, access: access, expires: JSONValue.date(entry["expires"]),
                         accountID: service == .chatGPT ? accountID : nil)
        }
    }
}
