import Foundation

/// Renews Grok CLI logins whose access token has run out. They last six hours, so the login of a Grok that
/// hasn't run since then reads as expired although its refresh token still works. xAI hands out a new
/// refresh token with each renewal and retires the one it was asked with, so the renewed login is saved
/// back to `~/.grok/auth.json`, with everything else kept there as it was.
///
/// It's done the way the Grok CLI does it: holding its lock on `auth.json.lock`, reading the login again
/// once it's held, since Grok may have renewed it meanwhile, and saving only over the refresh token it was
/// renewed with. A login xAI turns down is left in place for `grok login` to replace.
actor GrokRenewal {
    static let shared = GrokRenewal()

    private let folder: URL
    private let lockWait: Duration
    /// Refresh tokens xAI turned down, by hash, left alone until Grok saves another.
    private var rejected: Set<String> = []
    /// Each issuer's token endpoint, as its discovery document names it.
    private var endpoints: [String: String] = [:]

    init(folder: URL = URL.home.appendingPathComponent(".grok"), lockWait: Duration = .seconds(10)) {
        self.folder = folder
        self.lockWait = lockWait
    }

    /// A working token for the login under `key` in `auth.json`, whose `token` has run out or was
    /// `turnedAway` before its time.
    func renew(_ key: String, token: String, turnedAway: Bool = false) async -> Renewal {
        let file = folder.appendingPathComponent("auth.json")
        guard let lock = await FileLock.take(folder.appendingPathComponent("auth.json.lock"), within: lockWait) else { return .unchanged }
        defer { lock.release() }
        guard let entry = JSONValue.object(file: file)?[key] as? [String: Any], let stored = SavedLogin.text(entry["key"]),
              let refresh = SavedLogin.text(entry["refresh_token"]) ?? SavedLogin.text(entry["refresh"]) else { return .unchanged }
        let expires = JSONValue.date(entry["expires_at"] ?? entry["expires"]) ?? JWT.expiry(stored)
        let current = expires.map { $0 > Date() } ?? true
        if stored != token, current { return .renewed(token: stored, expires: expires) }
        if stored == token, current, !turnedAway { return .unchanged }
        if rejected.contains(refresh.sha256Prefix) { return .rejected }

        let issuer = SavedLogin.text(entry["oidc_issuer"]) ?? "https://auth.x.ai"
        // Keys are `<issuer>::<client>`.
        guard let client = SavedLogin.text(entry["oidc_client_id"]) ?? key.components(separatedBy: "::").last.flatMap(SavedLogin.text),
              let endpoint = await tokenEndpoint(issuer),
              let response = await HTTP.postForm(endpoint, form: ["grant_type": "refresh_token", "client_id": client, "refresh_token": refresh], timeout: 10)
        else { return .unchanged }
        guard response.ok, let answer = response.json, let renewed = SavedLogin.text(answer["access_token"]) else {
            if [400, 401].contains(response.status), response.json?["error"] as? String == "invalid_grant" {
                rejected.insert(refresh.sha256Prefix)
                return .rejected
            }
            return .unchanged
        }
        let renewedExpires = JSONValue.number(answer["expires_in"]).map { Date().addingTimeInterval($0) } ?? JWT.expiry(renewed)
        var changes: [String: Any] = ["key": renewed, "refresh_token": SavedLogin.text(answer["refresh_token"]) ?? refresh]
        if let renewedExpires { changes["expires_at"] = SavedLogin.timestamp(renewedExpires) }
        if entry["id_token"] != nil, let identity = SavedLogin.text(answer["id_token"]) { changes["id_token"] = identity }

        // Still under the lock, so nothing else wrote it since it was read.
        if var saved = JSONValue.object(file: file), var now = saved[key] as? [String: Any],
           (SavedLogin.text(now["refresh_token"]) ?? SavedLogin.text(now["refresh"])) == refresh {
            if now["refresh_token"] == nil { now["refresh"] = changes.removeValue(forKey: "refresh_token") }
            now.merge(changes) { $1 }
            saved[key] = now
            if !(SavedLogin.json(saved).map { SavedLogin.replace(file, with: $0) } ?? false) {
                NSLog("swiftusage: couldn't save a renewed Grok login; Grok will ask to sign in again")
            }
        }
        return .renewed(token: renewed, expires: renewedExpires)
    }

    private func tokenEndpoint(_ issuer: String) async -> String? {
        if let known = endpoints[issuer] { return known }
        let base = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        guard let endpoint = await HTTP.get(base + "/.well-known/openid-configuration", timeout: 10)?.json?["token_endpoint"] as? String,
              endpoint.hasPrefix("https://") else { return nil }
        endpoints[issuer] = endpoint
        return endpoint
    }
}
