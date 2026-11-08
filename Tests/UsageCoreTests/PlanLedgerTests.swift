import Foundation
import SQLite3
import Testing
@testable import UsageCore

/// The three stores that name the plan a call was billed to, so their usage feeds that plan's card.
struct PlanLedgerTests {
    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftusage-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test func kimiCountsEveryUsageRecordOnceAsACall() async throws {
        let root = try folder("kimi")
        let session = root.appendingPathComponent("wd_proj")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let lines = [
            json(["type": "usage.record", "model": "kimi-code/k3",
                  "usage": ["inputOther": 100, "output": 10, "inputCacheRead": 50, "inputCacheCreation": 5],
                  "usageScope": "turn", "time": 1_784_261_088_440]),
            json(["type": "goal.update", "goal": "x"]),
            json(["type": "usage.record", "model": "kimi-code/k3",
                  "usage": ["inputOther": 20, "output": 2, "inputCacheRead": 0, "inputCacheCreation": 0],
                  "usageScope": "turn", "time": 1_784_261_104_899]),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: session.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)

        let data = await KimiSource(root: root).refresh()
        #expect(data.usage.count == 2)
        #expect(data.usage.reduce(Int64(0)) { $0 + $1.tokens.input } == 120)
        #expect(data.usage.reduce(Int64(0)) { $0 + $1.tokens.output } == 12)
        #expect(data.usage.reduce(Int64(0)) { $0 + $1.tokens.cacheRead } == 50)
        #expect(data.usage.reduce(Int64(0)) { $0 + $1.tokens.cacheWrite } == 5)
        #expect(data.sessionStarts.count == 1)
        #expect(data.messageBuckets.values.reduce(0, +) == 2)
        #expect(data.transcriptCount == 1)
        #expect(data.usage.allSatisfy { $0.model == "kimi-code/k3" })
    }

    @Test func empryoGivesEachPlanOnlyTheCallsBilledToIt() async throws {
        let root = try folder("empryo")
        let records = [
            ["ts": 1_788_561_147_288, "modelId": "subscriptions/claude-opus-5-5", "input": 100, "output": 10,
             "cacheRead": 5, "cacheWrite": 1, "cost": 0.5],
            ["ts": 1_788_561_217_925, "modelId": "subscriptions/gpt-6-astra", "input": 200, "output": 20,
             "cacheRead": 10, "cacheWrite": 2, "cost": 0.25],
            ["ts": 1_788_561_235_151, "modelId": "subscriptions/kimi-code/k3", "input": 300, "output": 30,
             "cacheRead": 15, "cacheWrite": 3, "cost": 0.1],
            ["ts": 1_788_561_249_226, "modelId": "deepseek/deepseek-flash", "input": 400, "output": 40,
             "cacheRead": 0, "cacheWrite": 0, "cost": 0.01],
            ["ts": 1_788_561_264_108, "modelId": "openrouter/anthropic/claude-haiku-4.5", "input": 500,
             "output": 50, "cacheRead": 0, "cacheWrite": 0, "cost": 0.02],
            ["ts": 1_788_561_270_000, "modelId": "opencode-go/gpt-5.6-luna", "input": 600,
             "output": 60, "cacheRead": 0, "cacheWrite": 0, "cost": 0.03],
            ["ts": 1_788_561_280_000, "modelId": "subscriptions/meta-model", "input": 700,
             "output": 70, "cacheRead": 0, "cacheWrite": 0, "cost": 0.04],
            ["ts": 1_788_561_290_000, "input": 80, "output": 0, "cacheRead": 0, "cacheWrite": 0],
        ]
        let text = records.map { json($0) }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("usage-2026-11.jsonl"), atomically: true, encoding: .utf8)

        let reader = EmpryoReader()
        let claude = EmpryoSource(provider: .claude, reader: reader, root: root)
        let codex = EmpryoSource(provider: .codex, reader: reader, root: root)
        let kimi = EmpryoSource(provider: .kimi, reader: reader, root: root)
        let first = await claude.refresh()
        #expect(first.usage.count == 1)
        #expect(first.usage.first?.model == "subscriptions/claude-opus-5-5")
        #expect(first.usage.first?.cost == 0.5)
        #expect(await codex.refresh().usage.first?.model == "subscriptions/gpt-6-astra")
        #expect(await kimi.refresh().usage.first?.model == "subscriptions/kimi-code/k3")
        #expect(await EmpryoSource(provider: .opencode, reader: reader, root: root).refresh().usage.first?.tokens.total == 660)
        #expect(await EmpryoSource(provider: .muse, reader: reader, root: root).refresh().usage.first?.tokens.total == 770)
        let unattributed = try #require(Provider(rawValue: "unattributed"))
        let unknown = await EmpryoSource(provider: unattributed, reader: reader, root: root).refresh()
        #expect(unknown.usage.count == 3)
        #expect(unknown.usage.reduce(Int64(0)) { $0 + $1.tokens.total } == 1070)
        #expect(unknown.usage.contains { $0.model == "unknown" })
        let registered = UsageSources.all(cached: false)
        #expect(registered.contains { $0 is EmpryoSource && $0.provider == unattributed })
        #expect(registered.contains { $0 is HermesSource && $0.provider == unattributed })
        #expect(registered.contains { $0 is EmpryoSource && $0.provider == .opencode })
        #expect(registered.contains { $0 is EmpryoSource && $0.provider == .muse })

        // A call appended to the same file is read on the next pass, and only for its plan.
        let extra = json(["ts": 1_788_561_300_000, "modelId": "subscriptions/claude-fable-5-1",
                          "input": 7, "output": 1, "cacheRead": 0, "cacheWrite": 0, "cost": 0.01]) + "\n"
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("usage-2026-11.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(extra.utf8))
        try handle.close()
        #expect(await claude.refresh().usage.count == 2)
    }

    @Test func empryoNamesThePlanInsideAModelId() {
        #expect(EmpryoReader.plan(for: "subscriptions/claude-opus-5-5") == .claude)
        #expect(EmpryoReader.plan(for: "subscriptions/gpt-6-astra") == .codex)
        #expect(EmpryoReader.plan(for: "subscriptions/grok-4.7") == .grok)
        #expect(EmpryoReader.plan(for: "subscriptions/kimi-code/k3") == .kimi)
        #expect(EmpryoReader.plan(for: "subscriptions/cursor/cursor-grok-4.6-high") == .cursor)
        #expect(EmpryoReader.plan(for: "subscriptions/devin/gpt-5-4-high") == .devin)
        #expect(EmpryoReader.plan(for: "deepseek/deepseek-flash") == nil)
        #expect(EmpryoReader.plan(for: "openrouter/anthropic/claude-haiku-4.5") == nil)
    }

    @Test func hermesFilesUsageUnderThePlanItWasBilledTo() async throws {
        let root = try folder("hermes")
        let database = root.appendingPathComponent("state.db")
        try makeDatabase(at: database.path, statements: [
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at REAL, parent_session_id TEXT)",
            """
            CREATE TABLE session_model_usage (
                session_id TEXT NOT NULL, model TEXT NOT NULL, billing_provider TEXT DEFAULT '',
                billing_base_url TEXT NOT NULL DEFAULT '', billing_mode TEXT NOT NULL DEFAULT '',
                task TEXT NOT NULL DEFAULT '', api_call_count INTEGER NOT NULL DEFAULT 0,
                input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0, cache_write_tokens INTEGER NOT NULL DEFAULT 0,
                reasoning_tokens INTEGER NOT NULL DEFAULT 0, estimated_cost_usd REAL NOT NULL DEFAULT 0,
                actual_cost_usd REAL NOT NULL DEFAULT 0, first_seen REAL, last_seen REAL,
                PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task))
            """,
            "INSERT INTO sessions VALUES ('main', 1787530903, NULL)",
            "INSERT INTO sessions VALUES ('child', 1787530904, 'main')",
            "INSERT INTO sessions VALUES ('zai', 1787531000, NULL)",
            "INSERT INTO sessions VALUES ('kimi', 1790848800, NULL)",
            """
            INSERT INTO session_model_usage (session_id, model, billing_provider, api_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, first_seen, last_seen)
            VALUES ('kimi', 'k3', 'kimi-coding', 4, 100, 0, 0, 0, 1790848800, 1792317600)
            """,
            """
            INSERT INTO session_model_usage (session_id, model, billing_provider, api_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen)
            VALUES ('main', 'gpt-6.1-sol', 'openai-codex', 3, 100, 10, 50, 5, 1787532000)
            """,
            """
            INSERT INTO session_model_usage (session_id, model, billing_provider, api_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen)
            VALUES ('child', 'gpt-6.1-sol', 'openai-codex', 2, 20, 2, 0, 0, 1787532100)
            """,
            """
            INSERT INTO session_model_usage (session_id, model, billing_provider, api_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen)
            VALUES ('zai', 'glm-5.3', 'zai', 1, 30, 3, 7, 0, 1787532200)
            """,
            """
            INSERT INTO session_model_usage (session_id, model, billing_provider, api_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen)
            VALUES ('zai', 'glm-5.3', '', 9, 999, 99, 0, 0, 1787532200)
            """,
            """
            INSERT INTO session_model_usage (session_id, model, billing_provider, api_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen)
            VALUES ('zai', 'unknown-route-model', 'gateway-x', 1, 7, 0, 0, 0, 1787532200)
            """,
            """
            INSERT INTO session_model_usage (session_id, model, billing_provider, api_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen)
            VALUES ('zai', 'null-route-model', NULL, 1, 11, 0, 0, 0, 1787532200)
            """,
        ])

        let reader = HermesReader()
        let codex = await HermesSource(provider: .codex, reader: reader, database: database).refresh()
        #expect(codex.usage.count == 2)
        #expect(codex.usage.reduce(Int64(0)) { $0 + $1.tokens.input } == 120)
        #expect(codex.usage.reduce(Int64(0)) { $0 + $1.tokens.cacheRead } == 50)
        // The subagent's calls are tokens but not a message or a session of their own.
        #expect(codex.usage.reduce(0) { $0 + $1.aggregateCalls } == 3)
        #expect(codex.sessionStarts.count == 1)
        #expect(codex.transcriptCount == 1)

        let zai = await HermesSource(provider: .zai, reader: reader, database: database).refresh()
        #expect(zai.usage.count == 1)
        #expect(zai.usage.first?.model == "glm-5.3")
        // A blank billing provider must not be attributed to Z.AI.
        #expect(zai.usage.reduce(Int64(0)) { $0 + $1.tokens.input } == 30)
        let unattributed = try #require(Provider(rawValue: "unattributed"))
        let unknown = await HermesSource(provider: unattributed, reader: reader, database: database).refresh()
        #expect(unknown.usage.count == 3)
        #expect(unknown.usage.reduce(Int64(0)) { $0 + $1.tokens.total } == 1116)
        #expect(unknown.sessionStarts.count == 1)

        let kimi = await HermesSource(provider: .kimi, reader: reader, database: database).refresh()
        let utc = DayClock(timeZone: TimeZone(identifier: "UTC")!)
        let now = Date(timeIntervalSince1970: 1792317600)
        let all = StatsBuilder.build(kimi, range: .all, now: now, clock: utc)
        let week = StatsBuilder.build(kimi, range: .days7, now: now, clock: utc)
        #expect(kimi.usage.count == 1)
        #expect(all.totalTokens == 100 && all.unallocatedTokens == 100)
        #expect(all.messages == 4 && all.unallocatedMessages == 4)
        #expect(week.totalTokens == 0 && week.excludedUncertainTokens == 100)
        #expect(week.messages == 0 && week.excludedUncertainMessages == 4)
    }

    @Test func allProvidersExcludeUnattributedButKeepItsOwnStats() throws {
        let unattributed = try #require(Provider(rawValue: "unattributed"))
        let now = Date(timeIntervalSince1970: 1_792_317_600)
        let bucket = FileRecord.bucket(now.timeIntervalSince1970)
        var known = UsageData(), unknown = UsageData()
        known.usage = [UsageRecord(bucket: bucket, model: "known", tokens: TokenCounts(input: 100))]
        unknown.usage = [UsageRecord(bucket: bucket, model: "unknown", tokens: TokenCounts(input: 300))]
        let clock = DayClock(timeZone: TimeZone(identifier: "UTC")!)
        let knownStats = StatsBuilder.build(known, range: .all, now: now, clock: clock)
        let unknownStats = StatsBuilder.build(unknown, range: .all, now: now, clock: clock)
        let combined = RangeStats.mergedProviders([.codex: knownStats, unattributed: unknownStats], range: .all, today: knownStats.today)
        #expect(unknownStats.totalTokens == 300)
        #expect(combined.totalTokens == 100)
        #expect(combined.models.map(\.id) == knownStats.models.map(\.id))
        #expect(combined.days == knownStats.days)
    }

    private func makeDatabase(at path: String, statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "PlanLedgerTests", code: 1)
        }
        defer { sqlite3_close(db) }
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                throw NSError(domain: "PlanLedgerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }
}
