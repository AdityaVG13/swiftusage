import Foundation
import SQLite3
import Synchronization
import Testing
@testable import UsageCore

/// The requests a stubbed dashboard was sent.
final class Requests: Sendable {
    private let sent = Mutex<[URLRequest]>([])
    var all: [URLRequest] { sent.withLock { $0 } }
    func append(_ request: URLRequest) { sent.withLock { $0.append(request) } }
}

struct CursorServerUsageTests {
    static let day: Double = 86_400
    static let start = Timestamp.parse("2026-10-10T12:00:00Z")!

    /// One row of `usageEventsDisplay`, numbers sent as strings the way Cursor sends some of them.
    static func event(_ time: Double, model: String = "claude-4.5-sonnet", input: Int = 100, cents: Any? = 2.5) -> [String: Any] {
        var usage: [String: Any] = ["inputTokens": input, "outputTokens": 10, "cacheReadTokens": "1000"]
        if let cents { usage["totalCents"] = cents }
        return ["timestamp": String(Int64(time * 1000)), "model": model, "kind": "USAGE_EVENT_KIND_USAGE_BASED",
                "chargedCents": 0, "tokenUsage": usage]
    }

    /// Cursor's dashboard: `events` between the request's dates, newest first, `perPage` at a time whatever
    /// page size is asked for.
    static func dashboard(_ events: [[String: Any]], perPage: Int, requests: Requests) -> @Sendable (URLRequest) async -> HTTP.Response? {
        let events = events.map { try! JSONSerialization.data(withJSONObject: $0) }
        return { request in
            requests.append(request)
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            let from = Double(body["startDate"] as? String ?? "") ?? 0, to = Double(body["endDate"] as? String ?? "") ?? 0
            let rows = events.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] }
                .filter { (from...to).contains(Double($0["timestamp"] as! String)!) }
                .sorted { Double($0["timestamp"] as! String)! > Double($1["timestamp"] as! String)! }
            let page = Array(rows.dropFirst(((body["page"] as? Int ?? 1) - 1) * perPage).prefix(perPage))
            let answer = try! JSONSerialization.data(withJSONObject: ["totalUsageEventsCount": rows.count, "usageEventsDisplay": page])
            return HTTP.Response(status: 200, headers: [:], data: answer)
        }
    }

    static func server(cache: URL, waits: Bool = true) -> CursorServerUsage {
        CursorServerUsage(cacheURL: cache, readOnly: false, waits: waits,
                          logins: { [CursorServerUsage.Login(id: "cursor:a", session: "user_a%3A%3Atoken")] })
    }

    @Test func everyEventIsFetchedPageByPageAndKept() async throws {
        let home = try TempProjects()
        let cache = home.root.appendingPathComponent("cursor-usage.json")
        let events = (0..<5).map { Self.event(Self.start + Double($0) * Self.day / 2) }
            + [Self.event(Self.start, model: "auto", cents: nil), Self.event(Self.start, model: " ")]
        let requests = Requests()
        let source = CursorSource(chatsURL: home.root.appendingPathComponent("chats"), ideStateURL: home.root.appendingPathComponent("missing.vscdb"),
                                  server: Self.server(cache: cache))
        let data = await HTTP.$transport.withValue(Self.dashboard(events, perPage: 2, requests: requests)) { await source.refresh() }

        // Cursor sends fewer rows than asked for, so it's asked until every listed event is in; one without a
        // model isn't a request.
        #expect(requests.all.count == 4)
        let request = try #require(requests.all.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=user_a%3A%3Atoken")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
        #expect(data.usage.count == 6)
        #expect(data.usage.allSatisfy { $0.tokens == TokenCounts(input: 100, output: 10, cacheRead: 1000) })
        #expect(abs(data.usage.compactMap(\.cost).reduce(0, +) - 5 * 0.025) < 1e-9)

        // A relaunch that can't reach Cursor still has them.
        let offline = CursorSource(chatsURL: home.root.appendingPathComponent("chats"), ideStateURL: home.root.appendingPathComponent("missing.vscdb"),
                                   server: Self.server(cache: cache))
        let kept = await HTTP.$transport.withValue({ _ in HTTP.Response(status: 401, headers: [:], data: Data()) }) { await offline.refresh() }
        #expect(kept.usage.count == 6)
    }

    @Test func aLaterFetchAsksForTheLastDaysAndTakesTheirCorrections() async throws {
        let login = CursorServerUsage.Login(id: "cursor:a", session: "s")
        let old = CursorServerUsage.Event(time: Self.start, model: "auto", tokens: TokenCounts(input: 1), cost: nil)
        let recent = CursorServerUsage.Event(time: Self.start + 5 * Self.day, model: "auto", tokens: TokenCounts(input: 2), cost: nil)
        let known = CursorServerUsage.Account(events: [old, recent])
        // Cursor now lists the recent event with its final count, and a newer one.
        let listed = [Self.event(Self.start + 5 * Self.day, model: "auto", input: 3), Self.event(Self.start + 6 * Self.day, model: "auto", input: 4)]
        let requests = Requests()
        let updated = await HTTP.$transport.withValue(Self.dashboard(listed + [Self.event(Self.start, model: "auto", input: 9)], perPage: 10, requests: requests)) {
            await CursorServerUsage.update(known, login: login, now: Self.start + 7 * Self.day)
        }
        let body = try #require(requests.all.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["startDate"] as? String == String(Int64((Self.start + 3 * Self.day) * 1000)))
        #expect(updated?.events.map(\.tokens.input) == [1, 3, 4])

        let refused = await HTTP.$transport.withValue({ _ in HTTP.Response(status: 401, headers: [:], data: Data()) }) {
            await CursorServerUsage.update(known, login: login, now: Self.start + 7 * Self.day)
        }
        #expect(refused == nil)
    }

    @Test func cursorsEventsTakeTheIDEsTokenCountsPlace() async throws {
        let home = try TempProjects()
        let state = home.root.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        #expect(sqlite3_open(state.path, &db) == SQLITE_OK)
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        run("CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
        run(#"INSERT INTO cursorDiskKV VALUES ('composerData:c', '{"createdAt":\#(Int64(Self.start * 1000)),"fullConversationHeadersOnly":[{}]}')"#)
        run(#"INSERT INTO cursorDiskKV VALUES ('bubbleId:c:b', '{"type":2,"createdAt":\#(Int64(Self.start * 1000)),"tokenCount":{"inputTokens":7,"outputTokens":3}}')"#)
        sqlite3_close(db)

        let local = await CursorSource(chatsURL: home.root.appendingPathComponent("chats"), ideStateURL: state).refresh()
        #expect(local.usage.map(\.tokens.total) == [10])

        let requests = Requests()
        let source = CursorSource(chatsURL: home.root.appendingPathComponent("chats"), ideStateURL: state,
                                  server: Self.server(cache: home.root.appendingPathComponent("cursor-usage.json")))
        let data = await HTTP.$transport.withValue(Self.dashboard([Self.event(Self.start)], perPage: 10, requests: requests)) { await source.refresh() }
        #expect(data.usage.map(\.tokens.total) == [1110])
        #expect(data.messageBuckets.values.reduce(0, +) == 1)
    }

    @Test func theAppCountsWhatItHasAndHearsWhenMoreArrives() async throws {
        let home = try TempProjects()
        let requests = Requests()
        let source = CursorSource(chatsURL: home.root.appendingPathComponent("chats"), ideStateURL: home.root.appendingPathComponent("missing.vscdb"),
                                  server: Self.server(cache: home.root.appendingPathComponent("cursor-usage.json"), waits: false))
        let arrivals = NotificationCenter.default.notifications(named: CursorSource.serverUsageDidChange, object: source)
        let after = await HTTP.$transport.withValue(Self.dashboard([Self.event(Self.start)], perPage: 10, requests: requests)) { () async -> UsageData in
            let first = await source.refresh()
            #expect(first.usage.isEmpty)
            for await _ in arrivals { break }
            return await source.refresh()
        }
        #expect(after.usage.count == 1)
        // Read again within five minutes, Cursor isn't asked again.
        #expect(requests.all.count == 1)
    }
}
