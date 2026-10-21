import CommonCrypto
import Foundation
import Security

/// The login Claude Desktop keeps, for accounts no Claude Code folder is signed in to: an access token per
/// organization in `config.json`'s `oauth:tokenCacheV2`, encrypted the way Electron encrypts its storage,
/// with a key in the keychain item "Claude Safe Storage". Only the access token is read; Desktop renews
/// it itself.
///
/// The keychain item belongs to Claude Desktop, so macOS asks before another app can read it, until the
/// person chooses Always Allow. That only happens when they ask for it from the account's card; every other
/// read first checks the item's access list and says so when it isn't allowed yet.
public enum ClaudeDesktop {
    static var folder: URL { .home.appendingPathComponent("Library/Application Support/Claude") }
    /// Claude Desktop's own client, whose tokens can read limits.
    private static let desktopClient = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let storageItem = Keychain.Item(service: "Claude Safe Storage", account: "Claude Key")

    enum StorageKey: Equatable {
        case key(String)
        case needsPermission
        case missing
    }

    struct Login: Equatable {
        var organization: String
        var token: String
        var expires: Date
        var subscription: String?
        var tier: String?
    }

    /// Asks macOS for access to Claude Desktop's storage key, which shows its permission prompt. Blocks
    /// until the person answers, so call it off the main thread. Returns whether access was given.
    public static func requestAccess() -> Bool {
        if case .key = storageKey(asking: true) { return true }
        return false
    }

    static func storageKey(asking: Bool) -> StorageKey {
        // Asking macOS not to show its prompt doesn't stop it, so a read that would ask doesn't happen.
        if !asking {
            guard !Keychain.isRefused(storageItem) else { return .needsPermission }
            switch Keychain.access(storageItem, by: .app) {
            case .allowed: break
            case .missing: return .missing
            case .needsPermission: return .needsPermission
            }
        }
        var query = storageItem.query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            Keychain.setRefused(storageItem, false)
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return .missing }
            return .key(key)
        case errSecItemNotFound:
            return .missing
        default:
            // The person declined, or the keychain couldn't be read. A build whose signature changed since
            // Always Allow is asked about on every read, so later readings wait for the person to ask.
            Keychain.setRefused(storageItem, true)
            return .needsPermission
        }
    }

    static func limits(skippingAccounts known: Set<String>, ids seen: Set<String>) async -> [AccountLimits] {
        guard let config = JSONValue.object(file: folder.appendingPathComponent("config.json")),
              let account = (config["lastKnownAccountUuid"] as? String)?.lowercased(),
              config["oauth:tokenCacheV2"] != nil || config["oauth:tokenCache"] != nil,
              !known.contains(account) else { return [] }
        let waiting = "claude-desktop:" + account
        let key: String
        switch storageKey(asking: false) {
        case .missing:
            return []
        case .needsPermission:
            return [AccountLimits(id: waiting, provider: .claude, account: "Claude Desktop",
                                  problem: "To see these limits, allow access to Claude Desktop's login and choose Always Allow.", action: .allowClaudeDesktop)]
        case .key(let found):
            key = found
        }

        let logins = logins(config: config, key: key, account: account)
        guard !logins.isEmpty else {
            return [.failed(waiting, .claude, account: "Claude Desktop", "Claude Desktop's login has expired. Open Claude Desktop to renew it.")]
        }
        var results: [AccountLimits] = []
        var seen = seen
        for login in logins {
            let profile = await AnthropicUsage.shared.profile(token: login.token)
            let id = profile?.id ?? "claude:\(account)|\(login.organization)"
            guard seen.insert(id).inserted else { continue }
            results.append(await AnthropicUsage.shared.limits(id: id, provider: .claude, account: profile?.label ?? "Claude Desktop", token: login.token,
                                                              renew: "Open Claude Desktop to renew it.",
                                                              plan: ClaudeLimits.plan(login.subscription, login.tier)))
        }
        return results
    }

    /// The best usable token for each organization: Desktop's own client with both the profile and
    /// inference scopes first, then the most scopes, then the latest expiry. Entries saved for another
    /// account, or without the scope that reads limits, are left out.
    static func logins(config: [String: Any], key: String, account: String, now: Date = Date()) -> [Login] {
        var entries: [String: Any] = [:]
        // The older cache first, so the current one replaces its copies.
        for name in ["oauth:tokenCache", "oauth:tokenCacheV2"] {
            guard let encoded = config[name] as? String, let sealed = Data(base64Encoded: encoded),
                  let plain = decrypt(sealed, password: key),
                  let cache = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { continue }
            for (name, value) in cache {
                // `acct:<account>|<client>:<org>:<api>:<scopes>`, or the same without the account.
                var rest = name[...]
                if rest.hasPrefix("acct:") {
                    guard let bar = rest.firstIndex(of: "|"), rest[rest.index(rest.startIndex, offsetBy: 5)..<bar].lowercased() == account else { continue }
                    rest = rest[rest.index(after: bar)...]
                }
                entries[String(rest)] = value
            }
        }

        var best: [String: (rank: (Int, Int, Int, Double), login: Login)] = [:]
        for (name, value) in entries {
            guard let entry = value as? [String: Any], let token = entry["token"] as? String, !token.isEmpty,
                  let expires = JSONValue.date(entry["expiresAt"]), expires > now.addingTimeInterval(120) else { continue }
            // `<client>:<org>:https://api.anthropic.com:<scopes>`, where the scopes have colons of their own
            // (`user:profile`) and are everything after the API's address.
            let parts = name.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let api = parts[2]
            let host = api.range(of: "://")?.upperBound ?? api.startIndex
            guard let colon = api[host...].firstIndex(of: ":") else { continue }
            let scopes = Set(api[api.index(after: colon)...].split(separator: " ").map(String.init))
            guard scopes.contains("user:profile") else { continue }
            let both = scopes.contains("user:inference")
            let rank = (parts[0] == desktopClient && both ? 1 : 0, both ? 1 : 0, scopes.count, expires.timeIntervalSince1970)
            let organization = parts[1].lowercased()
            if let existing = best[organization], existing.rank >= rank { continue }
            best[organization] = (rank, Login(organization: organization, token: token, expires: expires,
                                              subscription: entry["subscriptionType"] as? String, tier: entry["rateLimitTier"] as? String))
        }
        return best.values.map(\.login).sorted { $0.organization < $1.organization }
    }

    /// Electron's storage encryption on macOS: `v10`, then AES-128-CBC with a key derived from the
    /// keychain password (PBKDF2-SHA1, salt `saltysalt`, 1003 rounds) and an IV of 16 spaces.
    static func decrypt(_ sealed: Data, password: String) -> Data? {
        guard sealed.count > 3, sealed.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = sealed.dropFirst(3)
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let derived = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        guard derived == kCCSuccess else { return nil }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plain = Data(count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let status = plain.withUnsafeMutableBytes { plainBytes in
            cipher.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                                cipherBytes.baseAddress, cipher.count, plainBytes.baseAddress, plainBytes.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return plain.prefix(written)
    }
}
