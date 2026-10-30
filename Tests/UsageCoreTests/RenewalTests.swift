import Foundation
import SQLite3
import Synchronization
import Testing
@testable import UsageCore

/// Renewing the logins of Grok, Codex and Cursor, and Devin's second key. Claude Code's are in `LimitsTests`.
struct RenewalTests {
    /// A folder that's gone after the test.
    final class Folder: Sendable {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftusage-renewal-\(UUID().uuidString)")

        init() {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ path: String, _ text: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func json(_ path: String) -> [String: Any] {
            JSONValue.object(file: url.appendingPathComponent(path)) ?? [:]
        }
    }

    /// The requests a test's answers were asked for.
    final class Requests: Sendable {
        let sent = Mutex<[URLRequest]>([])

        func to(_ path: String) -> [URLRequest] {
            sent.withLock { $0.filter { $0.url?.path == path } }
        }

        func bodies(to path: String) -> [[String: Any]] {
            to(path).map { JSONValue.object($0.httpBody) ?? [:] }
        }

        func form(to path: String) -> [String: String] {
            let body = to(path).first?.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return Dictionary(body.split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                return (parts[0], parts.count > 1 ? parts[1] : "")
            }) { $1 }
        }

        func bearers(to path: String) -> [String?] {
            to(path).map { $0.value(forHTTPHeaderField: "Authorization") }
        }
    }

    /// Answers each request from `answer`, by its path, recording it.
    func answering<T>(_ requests: Requests, _ answer: @escaping @Sendable (URLRequest) -> (Int, String), _ body: () async -> T) async -> T {
        await HTTP.$transport.withValue({ request in
            requests.sent.withLock { $0.append(request) }
            let (status, text) = answer(request)
            return HTTP.Response(status: status, headers: [:], data: Data(text.utf8))
        }) {
            await body()
        }
    }

    /// A token with `claims`, unsigned.
    static func jwt(_ claims: [String: Any]) -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: claims))!.base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
    }

    static func expiring(in seconds: TimeInterval, _ claims: [String: Any] = [:]) -> String {
        jwt(claims.merging(["exp": Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)]) { $1 })
    }

    // MARK: Grok

    static let grokKey = "https://auth.x.ai::client-1"

    func grokLogin(key: String = "old-key", refresh: String = "old-refresh", expires: String = "2026-01-01T00:00:00.000000Z") -> String {
        #"""
        {"\#(Self.grokKey)":{"key":"\#(key)","auth_mode":"oidc","email":"a@x.ai","user_id":"u1","team_id":"t1",
         "refresh_token":"\#(refresh)","expires_at":"\#(expires)","oidc_issuer":"https://auth.x.ai","oidc_client_id":"client-1"}}
        """#
    }

    @Sendable static func grokAnswer(_ request: URLRequest) -> (Int, String) {
        switch request.url?.path {
        case "/.well-known/openid-configuration": (200, #"{"token_endpoint":"https://auth.x.ai/oauth2/token"}"#)
        case "/oauth2/token": (200, #"{"access_token":"new-key","refresh_token":"new-refresh","expires_in":21600,"token_type":"Bearer"}"#)
        case "/v1/billing": (200, #"{"config":{"creditUsagePercent":12,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"}}}"#)
        default: (200, "{}")
        }
    }

    @Test func grokRenewsAnExpiredLoginUnderItsLockAndSavesItBack() async throws {
        let grok = Folder()
        try grok.write("auth.json", grokLogin())
        let requests = Requests()
        let cards = await answering(requests, Self.grokAnswer) {
            await GrokLimits().fetch(folder: grok.url, renewal: GrokRenewal(folder: grok.url))
        }
        #expect(cards.first?.meters.first?.used == 12)
        #expect(cards.first?.problem == nil)
        #expect(requests.bearers(to: "/v1/billing") == ["Bearer new-key"])

        // Asked as Grok asks, of the endpoint xAI's discovery document names.
        #expect(requests.form(to: "/oauth2/token") == ["grant_type": "refresh_token", "client_id": "client-1", "refresh_token": "old-refresh"])

        // Saved back with everything else kept as it was, only its owner able to read it.
        let saved = grok.json("auth.json")[Self.grokKey] as? [String: Any] ?? [:]
        #expect(saved["key"] as? String == "new-key")
        #expect(saved["refresh_token"] as? String == "new-refresh")
        #expect(JSONValue.date(saved["expires_at"]).map { abs($0.timeIntervalSinceNow - 21600) < 60 } == true)
        #expect(saved["email"] as? String == "a@x.ai")
        #expect(saved["team_id"] as? String == "t1")
        #expect(saved["oidc_client_id"] as? String == "client-1")
        let file = grok.url.appendingPathComponent("auth.json").path
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)

        // Grok's lock stays where it is, released, with who held it last.
        let lockFile = grok.url.appendingPathComponent("auth.json.lock")
        #expect(try String(contentsOf: lockFile, encoding: .utf8).hasPrefix("\(getpid()):"))
        let descriptor = open(lockFile.path, O_RDWR)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: grok.url.path)) == ["auth.json", "auth.json.lock"])
    }

    @Test func grokWaitsOnItsLockAndTakesTheLoginGrokRenewedMeanwhile() async throws {
        let grok = Folder()
        try grok.write("auth.json", grokLogin())
        let renewal = GrokRenewal(folder: grok.url, lockWait: .milliseconds(300))
        let requests = Requests()

        // While Grok holds its lock, the login is left to it.
        let descriptor = open(grok.url.appendingPathComponent("auth.json.lock").path, O_RDWR | O_CREAT, 0o644)
        #expect(flock(descriptor, LOCK_EX) == 0)
        let held = await answering(requests, Self.grokAnswer) { await renewal.renew(Self.grokKey, token: "old-key") }
        #expect(held == .unchanged)

        // Once it's done, the login it saved is taken without renewing it again.
        try grok.write("auth.json", grokLogin(key: "theirs", refresh: "their-refresh", expires: SavedLogin.timestamp(Date().addingTimeInterval(3600))))
        close(descriptor)
        let taken = await answering(requests, Self.grokAnswer) { await renewal.renew(Self.grokKey, token: "old-key") }
        guard case .renewed("theirs", _) = taken else {
            Issue.record("Not theirs: \(taken)")
            return
        }
        #expect(requests.sent.withLock { $0.isEmpty })
    }

    @Test func grokLeavesARefreshTokenXAITurnedDownAlone() async throws {
        let grok = Folder()
        try grok.write("auth.json", grokLogin())
        let renewal = GrokRenewal(folder: grok.url)
        let requests = Requests()
        let answer: @Sendable (URLRequest) -> (Int, String) = { request in
            request.url?.path == "/oauth2/token" ? (400, #"{"error":"invalid_grant","error_description":"Invalid or unknown refresh token"}"#) : Self.grokAnswer(request)
        }
        let cards = await answering(requests, answer) { await GrokLimits().fetch(folder: grok.url, renewal: renewal) }
        #expect(cards.first?.problem == "Login expired. Run `grok` to renew it.")
        let again = await answering(requests, answer) { await GrokLimits().fetch(folder: grok.url, renewal: renewal) }
        #expect(again.first?.problem == "Login expired. Run `grok` to renew it.")
        #expect(requests.to("/oauth2/token").count == 1)
        // Left in place for `grok login`, as Grok leaves it.
        #expect((grok.json("auth.json")[Self.grokKey] as? [String: Any])?["refresh_token"] as? String == "old-refresh")
    }

    @Test func grokRenewsALoginXAITurnedAwayAndAsksAgain() async throws {
        let grok = Folder()
        try grok.write("auth.json", grokLogin(expires: SavedLogin.timestamp(Date().addingTimeInterval(3600))))
        let requests = Requests()
        let cards = await answering(requests, { request in
            if request.url?.path == "/v1/billing", request.value(forHTTPHeaderField: "Authorization") == "Bearer old-key" { return (401, "{}") }
            return Self.grokAnswer(request)
        }) {
            await GrokLimits().fetch(folder: grok.url, renewal: GrokRenewal(folder: grok.url))
        }
        #expect(cards.first?.meters.first?.used == 12)
        #expect(requests.bearers(to: "/v1/billing") == ["Bearer old-key", "Bearer new-key"])
    }

    // MARK: Codex

    static let codexAccess = expiring(in: -3600, ["https://api.openai.com/profile": ["email": "a@b.c"]])
    static let codexRenewed = expiring(in: 10 * .day, ["https://api.openai.com/profile": ["email": "a@b.c"]])

    func codexLogin(access: String = codexAccess, refresh: String = "old-refresh") -> String {
        #"""
        {"auth_mode":"chatgpt","OPENAI_API_KEY":null,"last_refresh":"2026-08-09T22:04:40.613368Z",
         "tokens":{"id_token":"old-id","access_token":"\#(access)","refresh_token":"\#(refresh)","account_id":"acct-1"}}
        """#
    }

    @Sendable static func codexAnswer(_ request: URLRequest) -> (Int, String) {
        switch request.url?.path {
        case "/oauth/token": (200, #"{"id_token":"new-id","access_token":"\#(codexRenewed)","refresh_token":"new-refresh"}"#)
        case "/backend-api/wham/usage": (200, #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":18000}}}"#)
        default: (404, "{}")
        }
    }

    @Test func codexRenewsAnExpiredLoginAndSavesItBack() async throws {
        let home = Folder()
        try home.write(".codex/auth.json", codexLogin())
        let locks = Folder()
        let requests = Requests()
        let cards = await answering(requests, Self.codexAnswer) {
            await CodexLimits().fetch(home: home.url, configured: [], keychain: { _ in .missing }, renewal: CodexRenewal(locks: locks.url))
        }
        #expect(cards.first?.meters.first?.used == 7)
        #expect(requests.bearers(to: "/backend-api/wham/usage") == ["Bearer " + Self.codexRenewed])
        #expect(requests.bodies(to: "/oauth/token").first as? [String: String]
            == ["grant_type": "refresh_token", "client_id": CodexRenewal.clientID, "refresh_token": "old-refresh"])

        let saved = home.json(".codex/auth.json")
        let tokens = saved["tokens"] as? [String: Any] ?? [:]
        #expect(tokens["access_token"] as? String == Self.codexRenewed)
        #expect(tokens["refresh_token"] as? String == "new-refresh")
        #expect(tokens["id_token"] as? String == "new-id")
        #expect(tokens["account_id"] as? String == "acct-1")
        #expect(saved["auth_mode"] as? String == "chatgpt")
        #expect(saved["OPENAI_API_KEY"] is NSNull)
        #expect(JSONValue.date(saved["last_refresh"]).map { abs($0.timeIntervalSinceNow) < 60 } == true)
        let file = home.url.appendingPathComponent(".codex/auth.json").path
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func codexTakesALoginCodexRenewedMeanwhileAndDoesntSaveOverANewSignIn() async throws {
        let home = Folder()
        let codex = home.url.appendingPathComponent(".codex")
        let locks = Folder()
        let requests = Requests()

        // Codex renewed it since it was read: that login is taken as it is.
        try home.write(".codex/auth.json", codexLogin(access: Self.codexRenewed, refresh: "their-refresh"))
        let taken = await answering(requests, Self.codexAnswer) {
            await CodexRenewal(locks: locks.url).renew(home: codex, token: Self.codexAccess)
        }
        #expect(taken == .renewed(token: Self.codexRenewed, expires: JWT.expiry(Self.codexRenewed)))
        #expect(requests.to("/oauth/token").isEmpty)

        // Signed in again while it was being renewed: the new sign-in stays.
        try home.write(".codex/auth.json", codexLogin())
        let signedIn = codexLogin(access: "signed-in", refresh: "signed-in-refresh")
        let renewed = await answering(requests, { request in
            if request.url?.path == "/oauth/token" { try? home.write(".codex/auth.json", signedIn) }
            return Self.codexAnswer(request)
        }) {
            await CodexRenewal(locks: locks.url).renew(home: codex, token: Self.codexAccess)
        }
        #expect(renewed == .renewed(token: Self.codexRenewed, expires: JWT.expiry(Self.codexRenewed)))
        #expect((home.json(".codex/auth.json")["tokens"] as? [String: Any])?["refresh_token"] as? String == "signed-in-refresh")
    }

    @Test func codexLeavesARefreshTokenOpenAITurnedDownAlone() async throws {
        let home = Folder()
        try home.write(".codex/auth.json", codexLogin())
        let locks = Folder()
        let renewal = CodexRenewal(locks: locks.url)
        let requests = Requests()
        let answer: @Sendable (URLRequest) -> (Int, String) = { request in
            request.url?.path == "/oauth/token" ? (400, #"{"error":{"code":"refresh_token_reused","message":"Already used"}}"#) : Self.codexAnswer(request)
        }
        for _ in 0..<2 {
            let cards = await answering(requests, answer) {
                await CodexLimits().fetch(home: home.url, configured: [], keychain: { _ in .missing }, renewal: renewal)
            }
            #expect(cards.first?.problem == "Login expired. Run `codex` to renew it.")
        }
        #expect(requests.to("/oauth/token").count == 1)
        #expect((home.json(".codex/auth.json")["tokens"] as? [String: Any])?["refresh_token"] as? String == "old-refresh")
    }

    @Test func codexLeavesKeychainLoginsAlone() async throws {
        let home = Folder()
        try home.write(".codex/config.toml", "cli_auth_credentials_store = \"keyring\"\n")
        let locks = Folder()
        let requests = Requests()
        let cards = await answering(requests, Self.codexAnswer) {
            await CodexLimits().fetch(home: home.url, configured: [], keychain: { _ in
                .password(#"{"tokens":{"access_token":"\#(Self.codexAccess)","refresh_token":"r","account_id":"acct-1"}}"#)
            }, renewal: CodexRenewal(locks: locks.url))
        }
        #expect(cards.first?.problem == "Login expired. Run `codex` to renew it.")
        #expect(requests.sent.withLock { $0.isEmpty })
    }

    // MARK: Cursor

    static let cursorDue = expiring(in: 1 * .day, ["sub": "auth0|user-1"])
    static let cursorRenewed = expiring(in: 60 * .day, ["sub": "auth0|user-1"])

    @Sendable static func cursorAnswer(_ request: URLRequest) -> (Int, String) {
        switch request.url?.path {
        case "/oauth/token": (200, #"{"access_token":"\#(cursorRenewed)","id_token":"","shouldLogout":false}"#)
        case let path? where path.hasSuffix("GetPlanInfo"): (200, #"{"planInfo":{"planName":"Pro"}}"#)
        case let path? where path.hasSuffix("GetCurrentPeriodUsage"): (200, #"{"planUsage":{"totalPercentUsed":25}}"#)
        default: (404, "{}")
        }
    }

    func cursorApp(_ home: Folder, token: String) throws -> URL {
        let state = home.url.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(state.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)'), ('cursorAuth/refreshToken', '\(token)'),
                ('cursorAuth/cachedEmail', 'a@b.c'), ('other', 'kept');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return state
    }

    func appValues(_ state: URL) -> [String: String] {
        var values: [String: String] = [:]
        SQLiteReader(path: state.path)?.rows("SELECT key, value FROM ItemTable") { row in
            if let key = row.text(0) { values[key] = row.text(1) }
        }
        return values
    }

    static func cursorRenewal(running: Bool = false, locks: URL) -> CursorRenewal {
        let live = CursorRenewal.Storage.live
        // The app's database and the CLI's file are the test's own; the keychain is never reached.
        return CursorRenewal(storage: .init(read: { store in store == .keychain ? (nil, nil) : live.read(store) },
                                            write: { store, token in store == .keychain ? false : live.write(store, token) },
                                            cursorIsRunning: { running }), locks: locks)
    }

    @Test func cursorRenewsALoginInItsLastDaysAndSavesItWhereItsToolKeepsIt() async throws {
        let home = Folder()
        let state = try cursorApp(home, token: Self.cursorDue)
        let locks = Folder()
        let requests = Requests()
        let cards = await answering(requests, Self.cursorAnswer) {
            await LimitsTests.cursor(renewal: Self.cursorRenewal(locks: locks.url)).fetch(home: home.url) { _ in .missing }
        }
        #expect(cards.first?.meters.first?.used == 25)
        #expect(requests.bearers(to: "/aiserver.v1.DashboardService/GetCurrentPeriodUsage") == ["Bearer " + Self.cursorRenewed])
        #expect(requests.bodies(to: "/oauth/token").first as? [String: String]
            == ["grant_type": "refresh_token", "client_id": CursorRenewal.clientID, "refresh_token": Self.cursorDue])
        // Saved as Cursor saves it: the new token as both.
        let values = appValues(state)
        #expect(values["cursorAuth/accessToken"] == Self.cursorRenewed)
        #expect(values["cursorAuth/refreshToken"] == Self.cursorRenewed)
        #expect(values["other"] == "kept")

        // The CLI's file, which the CLI never renews itself.
        try FileManager.default.removeItem(at: state)
        try home.write(".cursor/auth.json", #"{"accessToken":"\#(Self.cursorDue)","refreshToken":"\#(Self.cursorDue)","apiKey":null}"#)
        let fromFile = await answering(requests, Self.cursorAnswer) {
            await LimitsTests.cursor(renewal: Self.cursorRenewal(locks: locks.url)).fetch(home: home.url) { _ in .missing }
        }
        #expect(fromFile.first?.meters.first?.used == 25)
        let auth = home.json(".cursor/auth.json")
        #expect(auth["accessToken"] as? String == Self.cursorRenewed)
        #expect(auth["refreshToken"] as? String == Self.cursorRenewed)
        #expect(auth["apiKey"] is NSNull)
    }

    @Test func cursorLeavesTheAppsLoginToCursorWhileItRuns() async throws {
        let home = Folder()
        let state = try cursorApp(home, token: Self.cursorDue)
        let locks = Folder()
        let requests = Requests()
        let cards = await answering(requests, Self.cursorAnswer) {
            await LimitsTests.cursor(renewal: Self.cursorRenewal(running: true, locks: locks.url)).fetch(home: home.url) { _ in .missing }
        }
        // Not run out yet, so it's still read.
        #expect(cards.first?.meters.first?.used == 25)
        #expect(requests.to("/oauth/token").isEmpty)
        #expect(appValues(state)["cursorAuth/accessToken"] == Self.cursorDue)
        // Not renewed long before it's due either.
        #expect(!CursorRenewal.isDue(Self.cursorRenewed))
    }

    @Test func cursorStopsRenewingALoginItWasToldToSignOut() async throws {
        let home = Folder()
        let state = try cursorApp(home, token: Self.cursorDue)
        let locks = Folder()
        let renewal = Self.cursorRenewal(locks: locks.url)
        let requests = Requests()
        let answer: @Sendable (URLRequest) -> (Int, String) = { request in
            request.url?.path == "/oauth/token" ? (200, #"{"access_token":"","id_token":"","shouldLogout":true}"#) : Self.cursorAnswer(request)
        }
        for _ in 0..<2 {
            let outcome = await answering(requests, answer) { await renewal.renew(.app(state), token: Self.cursorDue) }
            #expect(outcome == .rejected)
        }
        #expect(requests.to("/oauth/token").count == 1)
        #expect(appValues(state)["cursorAuth/accessToken"] == Self.cursorDue)
    }

    // MARK: Devin

    @Test func devinTriesTheAppsKeyWhenTheCLIsIsTurnedAway() async throws {
        let home = Folder()
        try home.write(".local/share/devin/credentials.toml", "windsurf_api_key = \"cli-key\"\n")
        let state = home.url.appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(state.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, #"CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '{"apiKey":"app-key"}');"#, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let requests = Requests()
        let cards = await answering(requests, { request in
            let key = (JSONValue.object(request.httpBody)?["metadata"] as? [String: Any])?["apiKey"] as? String
            return key == "cli-key" ? (401, "{}") : (200, #"{"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":80}}}"#)
        }) {
            await DevinLimits().fetch(home: home.url, configured: [])
        }
        #expect(cards.first?.id == "devin:" + "app-key".sha256Prefix)
        #expect(cards.first?.meters.first?.used == 20)
        #expect(requests.sent.withLock { $0.count } == 2)

        // Turned away with every key, the card says how to sign in again.
        let expired = await answering(requests, { _ in (401, "{}") }) { await DevinLimits().fetch(home: home.url, configured: []) }
        #expect(expired.first?.id == "devin:" + "cli-key".sha256Prefix)
        #expect(expired.first?.problem == "Login expired. Run `devin auth login` to sign in again.")
    }
}
