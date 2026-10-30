import Foundation

/// Renews Codex logins whose access token has run out. They last ten days and Codex renews them only when
/// it runs, so the login in a Codex home that hasn't been used for that long reads as expired although its
/// refresh token still works. OpenAI hands out a new refresh token with each renewal and turns away one
/// that's used twice, so the renewed login is saved back to the home's `auth.json`, with everything else
/// kept there as it was.
///
/// Codex takes no lock across processes: each Codex reads `auth.json` again before it renews and takes a
/// login another process saved there. So the app reads it again under its own lock, just before renewing,
/// and saves only over the refresh token it renewed with. Logins Codex keeps in the keychain are left
/// alone, as macOS would ask before letting the app change them.
actor CodexRenewal {
    static let shared = CodexRenewal()
    static let tokenURL = "https://auth.openai.com/oauth/token"
    /// Codex's OAuth client.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let locks: URL
    /// Refresh tokens OpenAI turned down, by hash, left alone until Codex saves another.
    private var rejected: Set<String> = []

    init(locks: URL = FileLock.renewals) {
        self.locks = locks
    }

    /// A working token for the login in `home`'s `auth.json`, whose `token` has run out or was `turnedAway`
    /// before its time.
    func renew(home: URL, token: String, turnedAway: Bool = false) async -> Renewal {
        let file = home.appendingPathComponent("auth.json")
        guard let lock = await FileLock.renewing("codex:" + home.standardizedFileURL.path, in: locks) else { return .unchanged }
        defer { lock.release() }
        guard let tokens = JSONValue.object(file: file)?["tokens"] as? [String: Any], let stored = SavedLogin.text(tokens["access_token"]),
              let refresh = SavedLogin.text(tokens["refresh_token"]) else { return .unchanged }
        let expires = JWT.expiry(stored)
        let current = expires.map { $0 > Date() } ?? true
        if stored != token, current { return .renewed(token: stored, expires: expires) }
        if stored == token, current, !turnedAway { return .unchanged }
        if rejected.contains(refresh.sha256Prefix) { return .rejected }

        let request = ["grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": refresh]
        guard let response = await HTTP.post(Self.tokenURL, headers: ["Accept": "application/json"], json: request) else { return .unchanged }
        guard response.ok, let answer = response.json, let renewed = SavedLogin.text(answer["access_token"]) else {
            // As Codex tells them: a 401, `invalid_grant`, or a refresh token that has expired, been used or been revoked.
            let error = response.json?["error"]
            let code = (error as? [String: Any])?["code"] as? String ?? error as? String ?? ""
            if response.status == 401 || (response.status == 400 && (code == "invalid_grant" || code.hasPrefix("refresh_token_"))) {
                rejected.insert(refresh.sha256Prefix)
                return .rejected
            }
            return .unchanged
        }
        var changes: [String: Any] = ["access_token": renewed, "refresh_token": SavedLogin.text(answer["refresh_token"]) ?? refresh]
        if let identity = SavedLogin.text(answer["id_token"]) { changes["id_token"] = identity }

        if var saved = JSONValue.object(file: file), var now = saved["tokens"] as? [String: Any], SavedLogin.text(now["refresh_token"]) == refresh {
            now.merge(changes) { $1 }
            saved["tokens"] = now
            saved["last_refresh"] = SavedLogin.timestamp(Date())
            if !(SavedLogin.json(saved).map { SavedLogin.replace(file, with: $0) } ?? false) {
                NSLog("swiftusage: couldn't save a renewed Codex login in \(home.lastPathComponent); Codex will ask to sign in again")
            }
        }
        return .renewed(token: renewed, expires: JWT.expiry(renewed))
    }
}
