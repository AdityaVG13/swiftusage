import Foundation

/// Cursor's usage events, as its dashboard lists them: each request's tokens and what Cursor priced them at.
/// Cursor keeps them only on its servers, so they're fetched with the login Cursor keeps on this Mac, which is
/// only read, never renewed. They're kept per account in the cache folder, so after the first fetch only the
/// last days are fetched again, and an account that's signed out keeps its history.
public struct CursorServerUsage: Sendable {
    struct Event: Codable, Sendable, Equatable {
        /// Seconds since 1970.
        var time: Double
        var model: String
        var tokens: TokenCounts
        /// Dollars, as Cursor priced the request whether or not the plan covered it.
        var cost: Double?

        enum CodingKeys: String, CodingKey {
            case time = "t", model = "m", tokens = "k", cost = "c"
        }

        init(time: Double, model: String, tokens: TokenCounts, cost: Double?) {
            (self.time, self.model, self.tokens, self.cost) = (time, model, tokens, cost)
        }

        /// One row of `usageEventsDisplay`. Cursor sends numbers as numbers or strings; `inputTokens` leaves out
        /// the cache's reads and writes.
        init?(_ row: [String: Any]) {
            guard let model = (row["model"] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty,
                  let milliseconds = JSONValue.number(row["timestamp"]), milliseconds > 0,
                  let time = Timestamp.seconds(milliseconds / 1000)
            else { return nil }
            let usage = row["tokenUsage"] as? [String: Any] ?? [:]
            func count(_ key: String) -> Int64 {
                JSONValue.number(usage[key]).flatMap { TokenCount.parse($0.rounded(.down)) } ?? 0
            }
            let cents = JSONValue.number(usage["totalCents"]) ?? JSONValue.number(row["chargedCents"])
            self.init(time: time, model: model,
                      tokens: TokenCounts(input: count("inputTokens"), output: count("outputTokens"),
                                          cacheRead: count("cacheReadTokens"), cacheWrite: count("cacheWriteTokens")),
                      cost: cents.flatMap { $0 >= 0 ? $0 / 100 : nil })
        }
    }

    struct Account: Codable, Sendable, Equatable {
        var events: [Event]
    }

    /// An account and the value of its dashboard session cookie.
    struct Login: Sendable {
        var id: String
        var session: String
    }

    static let endpoint = "https://cursor.com/api/dashboard/get-filtered-usage-events"
    /// Fetched at most this often.
    static let interval: TimeInterval = 300
    /// Fetched again each time, for events Cursor lists late or corrects.
    static let overlap: TimeInterval = 2 * 86_400
    static let pageSize = 500
    /// Enough for a quarter of a million events however small the pages Cursor sends.
    static let maxPages = 2500

    /// Where the events are kept, or nil to fetch every one each time.
    let cacheURL: URL?
    let readOnly: Bool
    /// Whether a read waits for the fetch, as the terminal commands do. The app counts what it has and reads
    /// Cursor again once a fetch brings anything new.
    let waits: Bool
    let logins: @Sendable () -> [Login]

    /// Cursor's own logins on this Mac. Without `cached`, events are neither read from nor kept in the cache
    /// folder; with `readOnly`, they're never kept.
    public static func live(cached: Bool = true, readOnly: Bool = false, waits: Bool = false) -> CursorServerUsage {
        CursorServerUsage(cacheURL: cached ? Remembered<Data>.inCaches("cursor-usage.json") : nil, readOnly: readOnly,
                          waits: waits, logins: { CursorLimits.dashboardLogins() })
    }

    func load() -> [String: Account] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Account].self, from: data)) ?? [:]
    }

    func save(_ accounts: [String: Account]) {
        guard let cacheURL, !readOnly, let data = try? JSONEncoder().encode(accounts) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// `known` brought up to date with what Cursor lists for `login` now: every event the first time, then
    /// the last days', which replace the ones kept for them. Nil when Cursor couldn't be asked or didn't list
    /// them all, which leaves what's kept as it was.
    static func update(_ known: Account?, login: Login, now: Double) async -> Account? {
        let since = known?.events.map(\.time).max().map { $0 - overlap }
        guard let fetched = await events(session: login.session, since: since, until: now) else { return nil }
        let kept = since.map { cut in known?.events.filter { $0.time < cut } ?? [] } ?? []
        let recent = since.map { cut in fetched.filter { $0.time >= cut } } ?? fetched
        return Account(events: (kept + recent).sorted { $0.time < $1.time })
    }

    /// Every event between `since` and `until`, page by page, or nil when a page doesn't come back.
    static func events(session: String, since: Double?, until: Double) async -> [Event]? {
        let headers = [
            "Cookie": "WorkosCursorSessionToken=" + session,
            // The endpoint turns away requests from anywhere but its own dashboard.
            "Origin": "https://cursor.com",
            "Referer": "https://cursor.com/settings",
            "Accept": "application/json",
        ]
        var events: [Event] = []
        var rows = 0
        for page in 1...maxPages {
            let body: [String: Any] = [
                "startDate": String(Int64((since ?? 0) * 1000)), "endDate": String(Int64(until * 1000)),
                "page": page, "pageSize": pageSize,
            ]
            guard let response = await HTTP.post(endpoint, headers: headers, json: body, timeout: 30), response.ok,
                  let json = response.json, let listed = json["usageEventsDisplay"] as? [[String: Any]]
            else { return nil }
            events += listed.compactMap(Event.init)
            rows += listed.count
            let total = JSONValue.number(json["totalUsageEventsCount"]).map { Int(saturating: $0) }
            if listed.isEmpty || rows >= total ?? .max { return events }
        }
        return nil
    }
}
