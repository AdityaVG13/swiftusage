import Darwin
import Foundation
import SQLite3

/// Renews Cursor logins about to run out. Their tokens last 60 days: the Cursor app renews its own whenever
/// it runs once 53 are left, and the `agent` CLI never renews its own. So a login whose tool hasn't run for
/// nearly two months is renewed in its last three days, the way the Cursor app renews it, and saved back
/// where its tool keeps it, as the new token Cursor hands out serves as access and refresh token both.
///
/// The app's login is renewed only while Cursor isn't running, as Cursor keeps it in memory and goes on
/// with the one it had. Neither tool takes a lock, so the login is read again under the app's own lock just
/// before it's renewed, and saved only over the token it was renewed with.
actor CursorRenewal {
    static let shared = CursorRenewal()
    static let tokenURL = "https://api2.cursor.sh/oauth/token"
    /// Cursor's OAuth client.
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    /// How long before it runs out a login is renewed.
    static let window: TimeInterval = 3 * .day

    /// Where a Cursor login is kept.
    enum Store: Equatable, Sendable {
        /// The Cursor app's `state.vscdb`.
        case app(URL)
        /// The CLI's `~/.cursor/auth.json`.
        case file(URL)
        /// The CLI's keychain items.
        case keychain

        var name: String {
            switch self {
            case .app(let url), .file(let url): url.standardizedFileURL.path
            case .keychain: "keychain"
            }
        }
    }

    /// Reads and writes a login where Cursor keeps it.
    struct Storage: Sendable {
        var read: @Sendable (Store) -> (access: String?, refresh: String?)
        /// Saves a token as the login's access and refresh token. Whether it took.
        var write: @Sendable (Store, String) -> Bool
        var cursorIsRunning: @Sendable () -> Bool

        static let live = Storage(
            read: { store in
                switch store {
                case .app(let url): CursorRenewal.appTokens(url)
                case .file(let url): CursorRenewal.fileTokens(JSONValue.object(file: url))
                case .keychain: (CursorRenewal.keychainToken(CursorRenewal.accessItem), CursorRenewal.keychainToken(CursorRenewal.refreshItem))
                }
            },
            write: { store, token in
                switch store {
                case .app(let url): CursorRenewal.saveAppTokens(token, to: url)
                case .file(let url): CursorRenewal.saveFileTokens(token, to: url)
                case .keychain: [CursorRenewal.accessItem, CursorRenewal.refreshItem].allSatisfy { item in
                    Keychain.save(Keychain.Item(service: item.service, account: Keychain.account(of: item) ?? "cursor-user"), Data(token.utf8))
                }
                }
            },
            cursorIsRunning: { CursorRenewal.cursorIsRunning() })
    }

    static let accessItem = Keychain.Item(service: "cursor-access-token")
    static let refreshItem = Keychain.Item(service: "cursor-refresh-token")

    private let storage: Storage
    private let locks: URL
    /// Tokens Cursor turned down, by hash, left alone until Cursor saves another.
    private var rejected: Set<String> = []

    init(storage: Storage = .live, locks: URL = FileLock.renewals) {
        self.storage = storage
        self.locks = locks
    }

    /// Whether a token is close enough to running out to be renewed.
    static func isDue(_ token: String, now: Date = Date()) -> Bool {
        JWT.expiry(token).map { $0.timeIntervalSince(now) < window } ?? false
    }

    /// A working token for the login in `store`, whose `token` is about to run out or was `turnedAway`.
    func renew(_ store: Store, token: String, turnedAway: Bool = false) async -> Renewal {
        if case .app = store, storage.cursorIsRunning() { return .unchanged }
        guard let lock = await FileLock.renewing("cursor:" + store.name, in: locks) else { return .unchanged }
        defer { lock.release() }
        let kept = storage.read(store)
        guard let stored = kept.access ?? kept.refresh, let refresh = kept.refresh ?? kept.access else { return .unchanged }
        let due = Self.isDue(stored)
        if stored != token, !due { return .renewed(token: stored, expires: JWT.expiry(stored)) }
        if stored == token, !due, !turnedAway { return .unchanged }
        if rejected.contains(refresh.sha256Prefix) { return .rejected }

        let request = ["grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refresh]
        guard let response = await HTTP.post(Self.tokenURL, json: request) else { return .unchanged }
        // Cursor answers a token it won't renew with `shouldLogout`, and HTTP 200.
        if response.json?["shouldLogout"] as? Bool == true {
            rejected.insert(refresh.sha256Prefix)
            return .rejected
        }
        guard response.ok, let renewed = SavedLogin.text(response.json?["access_token"]) else { return .unchanged }
        let now = storage.read(store)
        if (now.refresh ?? now.access) == refresh, !storage.write(store, renewed) {
            NSLog("swiftusage: couldn't save a renewed Cursor login; Cursor will ask to sign in again")
        }
        return .renewed(token: renewed, expires: JWT.expiry(renewed))
    }

    // MARK: - Where Cursor keeps it

    static func fileTokens(_ auth: [String: Any]?) -> (access: String?, refresh: String?) {
        (SavedLogin.text(auth?["accessToken"] ?? auth?["access_token"]), SavedLogin.text(auth?["refreshToken"] ?? auth?["refresh_token"]))
    }

    private static func saveFileTokens(_ token: String, to url: URL) -> Bool {
        guard var auth = JSONValue.object(file: url) else { return false }
        auth[auth["access_token"] != nil ? "access_token" : "accessToken"] = token
        auth[auth["refresh_token"] != nil ? "refresh_token" : "refreshToken"] = token
        return SavedLogin.json(auth).map { SavedLogin.replace(url, with: $0) } ?? false
    }

    private static func keychainToken(_ item: Keychain.Item) -> String? {
        guard case .password(let raw) = Keychain.password(item) else { return nil }
        return SavedLogin.text(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func appTokens(_ url: URL) -> (access: String?, refresh: String?) {
        guard let reader = SQLiteReader(path: url.path) else { return (nil, nil) }
        var values: [String: String] = [:]
        reader.rows("SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/refreshToken')") { row in
            if let key = row.text(0) { values[key] = SavedLogin.text(row.text(1)?.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return (values["cursorAuth/accessToken"], values["cursorAuth/refreshToken"])
    }

    /// Writes both tokens in one transaction, as Cursor stores a renewed login.
    static func saveAppTokens(_ token: String, to url: URL) -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return false }
        sqlite3_busy_timeout(db, 5000)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for key in ["cursorAuth/accessToken", "cursorAuth/refreshToken"] {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            sqlite3_bind_text(statement, 2, token, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return false
            }
        }
        return sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
    }

    /// Whether any process of the Cursor app is running.
    private static func cursorIsRunning() -> Bool {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).contains("/Cursor.app/Contents/") { return true }
        }
        return false
    }
}
