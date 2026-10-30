import Foundation

extension ClaudeLimits {
    /// Where Claude Code keeps a folder's login.
    enum Store: Hashable, Sendable {
        case keychain(Keychain.Item)
        case file(URL)
    }
}

/// Renews Claude Code logins whose access token has run out. Claude Code's last eight hours, so the login of
/// an account that hasn't been used for a while reads as expired although its refresh token still works.
/// Anthropic hands out a new refresh token with each renewal and retires the one it was asked with, so a
/// renewed login is saved back where Claude Code keeps it, with everything else kept there as it was;
/// otherwise Claude Code would be left holding a refresh token that no longer works.
///
/// It's done the way Claude Code 2.1 does it, so the two never renew one login at once: under its renewal
/// locks (`<folder>/.oauth_refresh.lock`, and `<folder>.lock`, which older versions take), reading the login
/// again once they're held, since another process may have renewed it meanwhile, then saving under its
/// storage lock (`<folder>/.storage-write`) only over the refresh token it was renewed with.
actor ClaudeRenewal {
    static let shared = ClaudeRenewal()

    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    /// Claude Code's OAuth client, for a login saved without one of its own.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Claude Code's scopes, for a login saved without its own.
    static let scopes = ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload", "user:plugins"]

    enum Outcome: Equatable {
        case renewed(token: String, refresh: String, expires: Date?)
        /// Anthropic turned the refresh token down: only signing in again helps.
        case rejected
        /// Not this time: Anthropic unreachable, another process holding the lock, or nowhere to save it.
        case unchanged
    }

    /// Reads and writes a login where Claude Code keeps it.
    struct Storage: Sendable {
        var read: @Sendable (ClaudeLimits.Store) -> Data?
        var write: @Sendable (ClaudeLimits.Store, Data) -> Bool

        static let live = Storage(
            read: { store in
                switch store {
                case .keychain(let item):
                    guard case .password(let raw) = Keychain.password(item) else { return nil }
                    return Data(raw.utf8)
                case .file(let url):
                    return try? Data(contentsOf: url)
                }
            },
            write: { store, data in
                switch store {
                case .keychain(let item): Keychain.save(item, data)
                case .file(let url): ClaudeRenewal.replace(url, with: data)
                }
            })
    }

    private let storage: Storage
    /// How often the renewal locks are tried while another process holds them, as Claude Code tries them.
    private let lockAttempts: Int
    /// Refresh tokens Anthropic turned down, by hash, left alone until Claude Code saves another.
    private var rejected: Set<String> = []

    init(storage: Storage = .live, lockAttempts: Int = 5) {
        self.storage = storage
        self.lockAttempts = lockAttempts
    }

    /// A working token for `login`, whose own has run out or was `turnedAway` before its time.
    func renew(_ login: ClaudeLimits.Login, turnedAway: Bool = false) async -> Outcome {
        guard let store = login.store, let token = login.token, let locks = await renewalLocks(login.folder) else { return .unchanged }
        defer { locks.reversed().forEach { $0.release() } }
        guard let oauth = read(store)?["claudeAiOauth"] as? [String: Any],
              let access = (oauth["accessToken"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
              let refresh = (oauth["refreshToken"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return .unchanged }
        let expires = JSONValue.date(oauth["expiresAt"])
        let current = expires.map { $0 > Date() } ?? true
        if access != token, current { return .renewed(token: access, refresh: refresh, expires: expires) }
        if access == token, current, !turnedAway { return .unchanged }
        if rejected.contains(refresh.sha256Prefix) { return .rejected }

        let request: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": (oauth["clientId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.clientID,
            "scope": ((oauth["scopes"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? Self.scopes).joined(separator: " "),
        ]
        let headers = ["Accept": "application/json", "User-Agent": AnthropicUsage.baseHeaders["User-Agent"] ?? ""]
        guard let response = await HTTP.post(Self.tokenURL, headers: headers, json: request) else { return .unchanged }
        guard response.ok, let answer = response.json, let renewedToken = (answer["access_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            if [400, 401].contains(response.status), response.json?["error"] as? String == "invalid_grant" {
                rejected.insert(refresh.sha256Prefix)
                return .rejected
            }
            return .unchanged
        }
        let renewedRefresh = (answer["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refresh
        let now = Date()
        let renewedExpires = now.addingTimeInterval(JSONValue.number(answer["expires_in"]) ?? .hour)
        func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        var changes: [String: Any] = ["accessToken": renewedToken, "refreshToken": renewedRefresh, "expiresAt": milliseconds(renewedExpires)]
        if let granted = (answer["scope"] as? String)?.split(separator: " ").map(String.init), !granted.isEmpty {
            changes["scopes"] = granted
        }
        if let lasts = JSONValue.number(answer["refresh_token_expires_in"]) {
            changes["refreshTokenExpiresAt"] = milliseconds(now.addingTimeInterval(lasts))
        }
        if !(await save(changes, renewedFrom: refresh, to: store, folder: login.folder)) {
            NSLog("swiftusage: couldn't save a renewed Claude Code login in \(login.folder.lastPathComponent); Claude Code will ask to sign in again")
        }
        return .renewed(token: renewedToken, refresh: renewedRefresh, expires: renewedExpires)
    }

    /// Writes `changes` into the saved login, keeping everything else kept beside it, unless a login other
    /// than the one renewed from `refresh` has been saved since, such as a new sign-in. Whether it took.
    private func save(_ changes: [String: Any], renewedFrom refresh: String, to store: ClaudeLimits.Store, folder: URL) async -> Bool {
        guard let lock = await storageLock(folder) else { return false }
        defer { lock.release() }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100 * attempt)) }
            guard var saved = read(store), var oauth = saved["claudeAiOauth"] as? [String: Any] else { continue }
            let there = oauth["refreshToken"] as? String ?? ""
            guard there.isEmpty || there == refresh else { return false }
            oauth.merge(changes) { $1 }
            saved["claudeAiOauth"] = oauth
            guard let data = Self.asciiJSON(saved) else { return false }
            _ = storage.write(store, data)
            if (read(store)?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == changes["accessToken"] as? String { return true }
        }
        return false
    }

    /// Compact JSON with every character past ASCII written as `\uXXXX`: `security -w`, which Claude Code
    /// reads its login with, prints a password holding any other byte as hex.
    static func asciiJSON(_ object: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var ascii = ""
        for unit in text.utf16 {
            if unit < 0x80 {
                ascii.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                ascii += String(format: "\\u%04x", unit)
            }
        }
        return Data(ascii.utf8)
    }

    private func read(_ store: ClaudeLimits.Store) -> [String: Any]? {
        JSONValue.object(storage.read(store))
    }

    /// Claude Code's renewal locks, all or none, tried a second or two apart while another process holds one.
    private func renewalLocks(_ folder: URL) async -> [FolderLock]? {
        var resolved = folder.path
        if let real = realpath(folder.path, nil) {
            resolved = String(cString: real)
            free(real)
        }
        let locks = [FolderLock(url: folder.appendingPathComponent(".oauth_refresh.lock"), stale: 60),
                     FolderLock(url: URL(fileURLWithPath: resolved + ".lock"), stale: 60)]
        for attempt in 1...max(lockAttempts, 1) {
            var held: [FolderLock] = []
            for lock in locks {
                guard lock.take() else { break }
                held.append(lock)
            }
            if held.count == locks.count { return held }
            held.reversed().forEach { $0.release() }
            if attempt < lockAttempts { try? await Task.sleep(for: .milliseconds(Int.random(in: 1000...2000))) }
        }
        return nil
    }

    /// Claude Code's lock on what it keeps, waited on past the 15 seconds after which it counts as left
    /// behind, since a renewed login has to be saved.
    private func storageLock(_ folder: URL) async -> FolderLock? {
        let lock = FolderLock(url: folder.appendingPathComponent(".storage-write"), stale: 15)
        let deadline = ContinuousClock.now + .seconds(20)
        var wait = Duration.milliseconds(100)
        while !lock.take() {
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, .seconds(1))
        }
        return lock
    }

    /// Replaces a file with a copy only its owner can read, swapped in whole.
    static func replace(_ url: URL, with data: Data) -> Bool {
        let copy = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).swiftusage-\(UUID().uuidString)")
        let descriptor = open(copy.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.close()
        } catch {
            unlink(copy.path)
            return false
        }
        guard rename(copy.path, url.path) == 0 else {
            unlink(copy.path)
            return false
        }
        return true
    }
}

/// A lock as proper-lockfile, which Claude Code uses, makes one: a folder held while it exists, and taken
/// over once nothing has touched it for `stale` seconds, its holder gone.
struct FolderLock {
    var url: URL
    var stale: TimeInterval

    func take(now: Date = Date()) -> Bool {
        if mkdir(url.path, 0o777) == 0 { return true }
        guard errno == EEXIST, let touched = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(touched) > stale else { return false }
        rmdir(url.path)
        return mkdir(url.path, 0o777) == 0
    }

    func release() {
        rmdir(url.path)
    }
}
