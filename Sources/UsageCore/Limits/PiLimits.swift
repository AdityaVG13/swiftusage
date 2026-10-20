import Foundation
import Synchronization

/// Pi runs on the subscriptions it's signed in to, so its limits are theirs: the Claude, ChatGPT and xAI
/// logins in Pi's `auth.json` (`~/.pi/agent`, and `$PI_CODING_AGENT_DIR` now or before). A subscription
/// that another tool is signed in to as well shows once, on that tool's card, marked as shared with Pi.
public struct PiLimits: LimitsSource {
    public let provider = Provider.pi
    private static let renew = "Run `pi` to renew it."
    private static let identities = Mutex<[String: (id: String, name: String)]>([:])

    public init() {}

    struct Login: Equatable {
        enum Service: Equatable {
            case claude, chatGPT, xai
        }

        var service: Service
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
                results.append(await limits(login))
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

    static func identity(for access: String, expired: Bool, profile: AnthropicUsage.Profile? = nil) -> (id: String, name: String) {
        let key = access.sha256Prefix
        if !expired, let profile {
            let identity = (id: profile.id, name: ["Claude", profile.label].compactMap { $0 }.joined(separator: " · "))
            identities.withLock { $0[key] = identity }
            return identity
        }
        return identities.withLock { $0[key] } ?? ("pi-claude:" + key, "Claude")
    }

    private func limits(_ login: Login) async -> AccountLimits {
        let expired = login.expires.map { $0 < Date() } ?? false
        switch login.service {
        case .claude:
            if expired {
                let (id, name) = Self.identity(for: login.access, expired: true)
                return .failed(id, provider, account: name, "Login expired. \(Self.renew)")
            }
            let (id, name) = Self.identity(for: login.access, expired: false, profile: await AnthropicUsage.shared.profile(token: login.access))
            return await AnthropicUsage.shared.limits(id: id, provider: provider, account: name, token: login.access,
                                                      renew: Self.renew, plan: nil)
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
            return Login(service: service, access: access, expires: JSONValue.date(entry["expires"]),
                         accountID: service == .chatGPT ? accountID : nil)
        }
    }
}
