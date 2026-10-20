import Foundation
import Testing
@testable import UsageCore

struct ProviderTests {
    let utc = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let now = Date(timeIntervalSince1970: Timestamp.parse("2026-10-18T20:00:00Z")!)

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: Codex

    private func codexUsage(_ input: Int, cached: Int, output: Int) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": 1, "total_tokens": input + output]
    }

    private func codexTokenCount(_ time: String, last: [String: Any], total: [String: Any]) -> String {
        json(["timestamp": time, "type": "event_msg", "payload": ["type": "token_count", "info": ["last_token_usage": last, "total_token_usage": total]]])
    }

    @Test func codexCountsEachResponseOnceAndSkipsForkReplays() async throws {
        let home = try TempProjects()
        let thread = "01a00000-0000-7000-8000-000000000001"
        let fork = "01b00000-0000-7000-8000-000000000002"
        let first = codexUsage(1000, cached: 600, output: 50)
        let second = codexUsage(2000, cached: 1500, output: 70)
        try home.write("sessions/2026/10/18/rollout-2026-10-18T10-00-00-\(thread).jsonl", [
            json(["timestamp": "2026-10-18T10:00:00Z", "type": "session_meta", "payload": ["id": thread, "timestamp": "2026-10-18T10:00:00Z", "source": "cli"]]),
            json(["timestamp": "2026-10-18T10:00:01Z", "type": "turn_context", "payload": ["turn_id": "01a00000-0001-7000-8000-000000000000", "model": "gpt-5.5"]]),
            json(["timestamp": "2026-10-18T10:00:02Z", "type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "UserMessage", "id": "item-1"]]]),
            codexTokenCount("2026-10-18T10:00:03Z", last: first, total: first),
            // Repeated with nothing new: not another response.
            codexTokenCount("2026-10-18T10:00:04Z", last: first, total: first),
            codexTokenCount("2026-10-18T10:00:05Z", last: second, total: codexUsage(3000, cached: 2100, output: 120)),
        ])
        // A fork replays its parent's turn (older turn ID), then has one of its own with per-response records.
        try home.write("archived_sessions/rollout-2026-10-18T11-00-00-\(fork).jsonl", [
            json(["timestamp": "2026-10-18T11:00:00Z", "type": "session_meta", "payload": ["id": fork, "timestamp": "2026-10-18T11:00:00Z", "forked_from_id": thread]]),
            json(["timestamp": "2026-10-18T11:00:00Z", "type": "session_meta", "payload": ["id": thread, "timestamp": "2026-10-18T10:00:00Z"]]),
            json(["timestamp": "2026-10-18T11:00:00Z", "type": "turn_context", "payload": ["turn_id": "01a00000-0001-7000-8000-000000000000", "model": "gpt-5.5"]]),
            json(["timestamp": "2026-10-18T11:00:00Z", "type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "UserMessage", "id": "item-1"]]]),
            codexTokenCount("2026-10-18T11:00:00Z", last: first, total: first),
            json(["timestamp": "2026-10-18T11:00:01Z", "type": "turn_context", "payload": ["turn_id": "01b00000-0001-7000-8000-000000000000", "model": "gpt-6"]]),
            json(["timestamp": "2026-10-18T11:00:02Z", "type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "UserMessage", "id": "item-1"]]]),
            json(["timestamp": "2026-10-18T11:00:03Z", "type": "event_msg", "payload": ["type": "token_usage_record", "thread_id": fork, "response_id": "resp_1", "usage": codexUsage(500, cached: 100, output: 10)]]),
            codexTokenCount("2026-10-18T11:00:04Z", last: codexUsage(500, cached: 100, output: 10), total: codexUsage(9999, cached: 0, output: 1)),
        ])

        let data = await TranscriptIndex<CodexTranscripts>(root: home.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(data.usage.count == 3)
        #expect(stats.sessions == 2)
        #expect(stats.messages == 2)
        let gpt55 = try #require(stats.models.first { $0.name == "GPT-5.5" })
        #expect(gpt55.tokens == TokenCounts(input: 400 + 500, output: 120, cacheRead: 2100))
        let gpt6 = try #require(stats.models.first { $0.name == "GPT-6" })
        #expect(gpt6.tokens == TokenCounts(input: 400, output: 10, cacheRead: 100))
    }

    @Test func truncatedZstdIsAcceptedAsComplete() throws {
        guard Zstd.isAvailable else { return }
        let home = try TempProjects()
        let line = Data((codexTokenCount("2026-10-18T10:00:00Z", last: codexUsage(100, cached: 0, output: 10), total: codexUsage(100, cached: 0, output: 10)) + "\n").utf8)
        let blockHeader = UInt32(line.count << 3) | 1
        let header: [UInt8] = [
            0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00,
            UInt8(blockHeader & 0xFF), UInt8((blockHeader >> 8) & 0xFF), UInt8((blockHeader >> 16) & 0xFF),
        ]
        let frame = Data(header) + line

        let validURL = home.root.appendingPathComponent("valid.jsonl.zst")
        try frame.write(to: validURL)
        var validRecord = FileRecord(isSubagent: false)
        validRecord.size = UInt64(frame.count)
        #expect(TranscriptReader.read(path: validURL.path, into: &validRecord, ingest: CodexTranscripts.ingest))
        #expect(validRecord.usage.count == 1)
        #expect(validRecord.offset == validRecord.size)

        let truncated = frame.dropLast(6)
        let truncatedURL = home.root.appendingPathComponent("truncated.jsonl.zst")
        try truncated.write(to: truncatedURL)
        var record = FileRecord(isSubagent: false)
        record.size = UInt64(truncated.count)
        let success = TranscriptReader.read(path: truncatedURL.path, into: &record) { _, _, _, _ in true }
        #expect(!success)
        #expect(record.offset == 0)
    }

    // MARK: Pi

    @Test func piCountsForkCopiesOnceAndCompactions() async throws {
        let home = try TempProjects()
        func assistant(_ id: String, _ time: String, input: Int) -> String {
            json(["type": "message", "id": id, "parentId": "x", "timestamp": time,
                  "message": ["role": "assistant", "model": "gpt-5.6", "timestamp": Timestamp.parse(time)! * 1000,
                              "usage": ["input": input, "output": 10, "cacheRead": 100, "cacheWrite": 0, "reasoning": 5, "totalTokens": input + 110]]])
        }
        let user = json(["type": "message", "id": "u1", "timestamp": "2026-10-18T10:00:01Z", "message": ["role": "user", "content": "hi"]])
        try home.write("--Users-me-app--/2026-10-18T10-00-00_a.jsonl", [
            json(["type": "session", "id": "a", "timestamp": "2026-10-18T10:00:00Z"]),
            user,
            assistant("a1", "2026-10-18T10:00:02Z", input: 1000),
        ])
        try home.write("--Users-me-app--/2026-10-18T11-00-00_b.jsonl", [
            json(["type": "session", "id": "b", "timestamp": "2026-10-18T11:00:00Z", "parentSession": "a"]),
            user,
            assistant("a1", "2026-10-18T10:00:02Z", input: 1000),
            json(["type": "message", "id": "u2", "timestamp": "2026-10-18T11:00:01Z", "message": ["role": "user", "content": "more"]]),
            json(["type": "compaction", "id": "c1", "timestamp": "2026-10-18T11:00:05Z", "details": ["modelId": "gpt-5.6"],
                  "usage": ["input": 300, "output": 20, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 320]]),
        ])
        let data = await TranscriptIndex<PiTranscripts>(root: home.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        // The fork carries the whole original plus more, so as with Claude Code's continued sessions it's
        // one conversation; its copied history counts once.
        #expect(stats.sessions == 1)
        #expect(stats.messages == 3)
        #expect(stats.totalTokens == 1110 + 320)
    }

    @Test func piCountsStandaloneUsageEntriesOnce() async throws {
        let home = try TempProjects()
        let warm = json(["type": "usage", "id": "warm1", "parentId": NSNull(), "timestamp": "2026-10-18T10:00:01Z",
                         "kind": "cache_warm", "provider": "anthropic", "model": "claude-sonnet-5",
                         "usage": ["input": 0, "output": 0, "cacheRead": 50_000, "cacheWrite": 0, "totalTokens": 50_000, "cost": ["total": 0.015]]])
        try home.write("--Users-me-app--/2026-10-18T10-00-00_a.jsonl", [
            json(["type": "session", "id": "a", "timestamp": "2026-10-18T10:00:00Z"]),
            warm,
        ])
        try home.write("--Users-me-app--/2026-10-18T11-00-00_b.jsonl", [
            json(["type": "session", "id": "b", "timestamp": "2026-10-18T11:00:00Z", "parentSession": "a"]),
            warm,
        ])
        let data = await TranscriptIndex<PiTranscripts>(root: home.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.totalTokens == 50_000)
        #expect(abs(stats.cost - 0.015) < 1e-9)
        #expect(stats.messages == 0)
        #expect(stats.models.map(\.name) == ["Sonnet 5"])
    }

    @Test func piExplicitSessionFolderReadsTopLevelFiles() async throws {
        defer {
            unsetenv("PI_CODING_AGENT_SESSION_DIR")
            UserDefaults.standard.removeObject(forKey: "environmentFolders.PI_CODING_AGENT_SESSION_DIR")
        }
        let explicit = try TempProjects()
        let defaultLayout = try TempProjects()
        let line = json(["type": "message", "id": "a1", "timestamp": "2026-10-18T10:00:02Z",
                         "message": ["role": "assistant", "model": "gpt-5.6", "timestamp": Timestamp.parse("2026-10-18T10:00:02Z")! * 1000,
                                     "usage": ["input": 1000, "output": 100, "cacheRead": 0, "cacheWrite": 0]]])
        try explicit.write("s.jsonl", [line])
        try defaultLayout.write("s.jsonl", [line])
        try defaultLayout.write("nested/n.jsonl", [line])

        setenv("PI_CODING_AGENT_SESSION_DIR", explicit.root.path, 1)
        let current = await TranscriptIndex<PiTranscripts>(root: PiTranscripts.defaultRoot, cacheURL: nil).refresh()
        #expect(current.usage.reduce(0) { $0 + $1.tokens.total } == 1100)

        // Still recognized after the environment variable is gone.
        unsetenv("PI_CODING_AGENT_SESSION_DIR")
        let remembered = await TranscriptIndex<PiTranscripts>(root: explicit.root, cacheURL: nil).refresh()
        #expect(remembered.usage.reduce(0) { $0 + $1.tokens.total } == 1100)

        // The default sessions folder only reads one level down.
        let defaultData = await TranscriptIndex<PiTranscripts>(root: defaultLayout.root, cacheURL: nil).refresh()
        #expect(defaultData.transcriptCount == 1)
    }

    // MARK: Grok

    @Test func grokSplitsCachedInputAndCountsPrompts() async throws {
        let home = try TempProjects()
        func update(_ update: [String: Any], at ms: Double) -> String {
            json(["timestamp": ms / 1000, "method": "_x.ai/session/update",
                  "params": ["sessionId": "s1", "update": update, "_meta": ["agentTimestampMs": ms]]])
        }
        let start = Timestamp.parse("2026-10-18T10:00:00Z")! * 1000
        let usage: [String: Any] = ["inputTokens": 1000, "outputTokens": 50, "cachedReadTokens": 800, "cacheCreationTokens": 0, "reasoningTokens": 40, "modelCalls": 2]
        try home.write("%2FUsers%2Fme/s1/updates.jsonl", [
            update(["sessionUpdate": "user_message_chunk", "_meta": ["promptIndex": 0]], at: start),
            update(["sessionUpdate": "user_message_chunk", "_meta": ["promptIndex": 0]], at: start + 1),
            update(["sessionUpdate": "agent_message_chunk"], at: start + 2),
            update(["sessionUpdate": "turn_completed", "prompt_id": "p1", "usage": usage.merging(["modelUsage": ["grok-4.7-build": usage]]) { a, _ in a }], at: start + 3),
        ])
        let data = await TranscriptIndex<GrokTranscripts>(root: home.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.sessions == 1)
        #expect(stats.messages == 3)
        #expect(stats.models.first?.tokens == TokenCounts(input: 200, output: 50, cacheRead: 800))
    }

    @Test func grokSkipsSubagentSessions() async throws {
        let home = try TempProjects()
        let start = Timestamp.parse("2026-10-18T10:00:00Z")! * 1000
        func turn(_ session: String, prompt: String, input: Int, output: Int) -> [String] {
            let usage: [String: Any] = ["inputTokens": input, "outputTokens": output, "cachedReadTokens": 0, "cacheCreationTokens": 0, "modelCalls": 1]
            return [
                json(["timestamp": start / 1000, "params": ["sessionId": session, "_meta": ["agentTimestampMs": start],
                                                             "update": ["sessionUpdate": "user_message_chunk", "_meta": ["promptIndex": 0]]]]),
                json(["timestamp": (start + 1) / 1000, "params": ["sessionId": session, "_meta": ["agentTimestampMs": start + 1],
                                                                   "update": ["sessionUpdate": "turn_completed", "prompt_id": prompt,
                                                                              "usage": ["modelUsage": ["grok-4.7-build": usage]]]]]),
            ]
        }
        try home.write("project/parent/updates.jsonl", turn("parent", prompt: "p1", input: 1000, output: 100))
        try home.write("project/child/updates.jsonl", turn("child", prompt: "p2", input: 500, output: 50))
        try home.write("project/child/summary.json", [json(["id": "child", "parent_session_id": "parent", "session_kind": "subagent"])])

        let index = TranscriptIndex<GrokTranscripts>(root: home.root, cacheURL: nil)
        let subagentStats = StatsBuilder.build(await index.refresh(), range: .all, now: now, clock: utc)
        #expect(subagentStats.sessions == 1)
        #expect(subagentStats.messages == 2)
        #expect(subagentStats.totalTokens == 1100)

        try home.write("project/child/summary.json", [json(["id": "child", "parent_session_id": "parent", "session_kind": "fork"])])
        let forkStats = StatsBuilder.build(await index.refresh(), range: .all, now: now, clock: utc)
        #expect(forkStats.sessions == 2)
        #expect(forkStats.messages == 4)
        #expect(forkStats.totalTokens == 1650)

        try home.write("project/child/summary.json", [json(["id": "child", "parent_session_id": "parent", "session_kind": "subagent"])])
        let revertedStats = StatsBuilder.build(await index.refresh(), range: .all, now: now, clock: utc)
        #expect(revertedStats.sessions == 1)
        #expect(revertedStats.messages == 2)
        #expect(revertedStats.totalTokens == 1100)
    }

    // MARK: Muse

    @Test func museRepeatedTurnCompletion() {
        var record = FileRecord(isSubagent: false)
        for (i, type) in ["token-usage", "turn_completed", "turn.completed", "TURN-COMPLETE"].enumerated() {
            var line = json([
                "id": "event-\(i)", "type": type, "turnId": "turn1",
                "timestamp": "2026-10-18T10:00:00Z", "modelId": "muse-model",
                "promptTokens": 100, "usage": ["outputTokens": 10],
            ])
            line.withUTF8 { bytes in
                #expect(MuseTranscripts.ingest(UnsafeRawBufferPointer(bytes), lineOffset: UInt64(i * 200), pathHash: 77, into: &record))
            }
        }
        #expect(record.usage.count == 1)
        #expect(record.usage.values.reduce(Int64(0)) { $0 + $1.tokens.total } == 110)
        #expect(record.messages.count == 2)
    }

    // MARK: OpenCode

    @Test func openCodeReasoningIsAddedOnlyWhenSeparate() {
        typealias Database = OpenCodeSource.Database
        // Newer builds: reasoning beside output, and the total says so.
        #expect(Database.tokens(input: 10, output: 5, reasoning: 3, cacheRead: 100, cacheWrite: 0, total: 118, provider: "openai", reasoningAlwaysSeparate: false)?.output == 8)
        // Older OpenAI-style builds: reasoning already inside output.
        #expect(Database.tokens(input: 10, output: 5, reasoning: 3, cacheRead: 100, cacheWrite: 0, total: 115, provider: "openai", reasoningAlwaysSeparate: false)?.output == 5)
        // No total recorded: Google kept it separate.
        #expect(Database.tokens(input: 10, output: 5, reasoning: 3, cacheRead: 0, cacheWrite: 0, total: nil, provider: "google", reasoningAlwaysSeparate: false)?.output == 8)
        #expect(Database.tokens(input: 10, output: 5, reasoning: 3, cacheRead: 0, cacheWrite: 0, total: nil, provider: "openai", reasoningAlwaysSeparate: false)?.output == 5)
        // Some providers' output is recorded net of reasoning, below zero; with reasoning added it's the reply.
        let net = Database.tokens(input: 20577, output: -185, reasoning: 1849, cacheRead: 5376, cacheWrite: 0, total: 27617,
                                  provider: "opencode-go", reasoningAlwaysSeparate: false)
        #expect(net == TokenCounts(input: 20577, output: 1664, cacheRead: 5376))
        // Never below zero, and only output may be.
        #expect(Database.tokens(input: 10, output: -5, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: nil, provider: "openai", reasoningAlwaysSeparate: false)?.output == 0)
        #expect(Database.tokens(input: -10, output: 5, reasoning: 0, cacheRead: 0, cacheWrite: 0, total: nil, provider: "openai", reasoningAlwaysSeparate: false) == nil)
    }

    @Test func corruptNumbersAreSkippedWithoutTrapping() async throws {
        let home = try TempProjects()
        var db: OpaquePointer?
        #expect(sqlite3_open(home.root.appendingPathComponent("opencode.db").path, &db) == SQLITE_OK)
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        run("CREATE TABLE session (id TEXT, parent_id TEXT, time_created INTEGER)")
        run("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        run("INSERT INTO session VALUES ('s', NULL, 1792317600000)")
        for (id, data) in [
            ("a", #"{"role":"assistant","modelID":"gpt-5","tokens":{"input":100,"output":10}}"#),
            ("overflow", #"{"role":"assistant","modelID":"gpt-5","tokens":{"input":9223372036854775807,"output":1}}"#),
            ("b", #"{"role":"assistant","modelID":"gpt-5","tokens":{"input":200,"output":20}}"#),
        ] {
            run("INSERT INTO message VALUES ('\(id)', 's', 1792317601000, 1792317601000, '\(data)')")
        }
        sqlite3_close(db)

        let openCode = await OpenCodeSource(root: home.root).refresh()
        #expect(openCode.usage.count == 2)
        #expect(openCode.usage.reduce(0) { $0 + $1.tokens.total } == 330)

        let start = Timestamp.parse("2026-10-18T10:00:00Z")! * 1000
        try home.write("%2FUsers%2Fme/s1/updates.jsonl", [
            #"{"params":{"sessionId":"s1","_meta":{"agentTimestampMs":\#(start)},"update":{"sessionUpdate":"user_message_chunk","_meta":{"promptIndex":0}}}}"#,
            #"{"params":{"sessionId":"s1","_meta":{"agentTimestampMs":1e300},"update":{"sessionUpdate":"user_message_chunk","_meta":{"promptIndex":1}}}}"#,
            #"{"params":{"sessionId":"s1","_meta":{"agentTimestampMs":\#(start + 1)},"update":{"sessionUpdate":"turn_completed","prompt_id":"bad","usage":{"inputTokens":10,"outputTokens":5,"modelCalls":20000}}}}"#,
            #"{"params":{"sessionId":"s1","_meta":{"agentTimestampMs":\#(start + 2)},"update":{"sessionUpdate":"turn_completed","prompt_id":"ok","usage":{"inputTokens":100,"outputTokens":10,"modelCalls":1}}}}"#,
        ])
        let grok = await TranscriptIndex<GrokTranscripts>(root: home.root, cacheURL: nil).refresh()
        #expect(grok.usage.count == 1)
        #expect(grok.usage.first?.tokens == TokenCounts(input: 100, output: 10))
        #expect(grok.messageBuckets.values.reduce(0, +) == 2)
    }

    @Test func lockedSQLiteReadIsNeverRetriedAfterUnlock() async throws {
        let home = try TempProjects()
        let path = home.root.appendingPathComponent("opencode.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        run("PRAGMA journal_mode=WAL")
        run("CREATE TABLE session (id TEXT, parent_id TEXT, time_created INTEGER)")
        run("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        run("INSERT INTO session VALUES ('s', NULL, 1792317600000)")
        run(#"INSERT INTO message VALUES ('a', 's', 1792317601000, 1792317601000, '{"role":"assistant","modelID":"gpt-5","tokens":{"input":100}}')"#)
        let before = DatabaseStamp(path: path)
        run("PRAGMA locking_mode=EXCLUSIVE")
        run("BEGIN EXCLUSIVE")
        let source = OpenCodeSource(root: home.root)
        let locked = await source.refresh()
        run("COMMIT")
        run("PRAGMA locking_mode=NORMAL")
        run("SELECT count(*) FROM session")
        let after = DatabaseStamp(path: path)
        let unlocked = await source.refresh()
        #expect(before == after)
        #expect(locked.usage.isEmpty)
        #expect(unlocked.usage.count == 1)
    }

    @Test func openCodeMalformedRowAbortsFollowingHistory() async throws {
        let home = try TempProjects()
        let path = home.root.appendingPathComponent("opencode.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        run("CREATE TABLE session (id TEXT, parent_id TEXT, time_created INTEGER)")
        run("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        run("INSERT INTO session VALUES ('s', NULL, 1792317600000)")
        for (id, json) in [
            ("a", #"{"role":"assistant","modelID":"gpt-5","tokens":{"input":100,"output":10}}"#),
            ("bad", #"{"role":"assistant","#),
            ("b", #"{"role":"assistant","modelID":"gpt-5","tokens":{"input":200,"output":20}}"#),
        ] {
            run("INSERT INTO message VALUES ('\(id)', 's', 1792317601000, 1792317601000, '\(json)')")
        }
        let source = OpenCodeSource(root: home.root)
        let first = await source.refresh()
        let second = await source.refresh()
        #expect(first.usage.count == 2)
        #expect(second.usage.count == 2)
    }

    @Test func openCodeResolvesRelativeDatabaseOverrideAndIgnoresMemory() async throws {
        defer { unsetenv("OPENCODE_DB") }
        let home = try TempProjects()
        let other = try TempProjects()
        func writeDatabase(at url: URL, input: Int) {
            var db: OpaquePointer?
            #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
            run("CREATE TABLE session (id TEXT, parent_id TEXT, time_created INTEGER)")
            run("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
            run("INSERT INTO session VALUES ('s', NULL, 1792317600000)")
            run(#"INSERT INTO message VALUES ('m', 's', 1792317601000, 1792317601000, '{"role":"assistant","modelID":"gpt-5","tokens":{"input":\#(input),"output":10}}')"#)
        }
        writeDatabase(at: home.root.appendingPathComponent("custom.db"), input: 100)
        writeDatabase(at: other.root.appendingPathComponent("abs.db"), input: 200)
        writeDatabase(at: home.root.appendingPathComponent(":memory:"), input: 900)

        setenv("OPENCODE_DB", "custom.db", 1)
        let relative = await OpenCodeSource(root: home.root).refresh()
        #expect(relative.usage.reduce(0) { $0 + $1.tokens.total } == 110)

        setenv("OPENCODE_DB", other.root.appendingPathComponent("abs.db").path, 1)
        let absolute = await OpenCodeSource(root: home.root).refresh()
        #expect(absolute.usage.reduce(0) { $0 + $1.tokens.total } == 210)

        setenv("OPENCODE_DB", ":memory:", 1)
        let memory = await OpenCodeSource(root: home.root).refresh()
        #expect(memory.usage.isEmpty)
    }

    @Test func protobufFieldsAndTimestamps() throws {
        // field 1 (message) { field 1: 1792323955, field 2: 500_000_000 }, field 2: varint 150, field 3: "hi"
        let bytes: [UInt8] = [0x0A, 0x0C, 0x08, 0xF3, 0xE2, 0xD2, 0xD6, 0x06, 0x10, 0x80, 0xCA, 0xB5, 0xEE, 0x01, 0x10, 0x96, 0x01, 0x1A, 0x02, 0x68, 0x69]
        let message = try #require(ProtoMessage(Data(bytes)))
        #expect(message.int(2) == 150)
        #expect(message.string(3) == "hi")
        let time = try #require(message.message(1)?.timestamp)
        #expect(abs(time - 1_792_323_955.5) < 0.001)
    }

    @Test func antigravityBackupSelectsArbitraryUsage() async throws {
        func varint(_ value: UInt64) -> [UInt8] {
            var value = value
            var result: [UInt8] = []
            repeat {
                var byte = UInt8(value & 127)
                value >>= 7
                if value != 0 { byte |= 128 }
                result.append(byte)
            } while value != 0
            return result
        }
        func bytes(_ number: Int, _ content: [UInt8]) -> [UInt8] {
            varint(UInt64(number * 8 + 2)) + varint(UInt64(content.count)) + content
        }
        func number(_ field: Int, _ value: UInt64) -> [UInt8] {
            varint(UInt64(field * 8)) + varint(value)
        }
        func hex(_ value: [UInt8]) -> String { Data(value).hexString }

        let home = try TempProjects()
        var roots: [URL] = []
        for (name, output) in [("live", 100), ("backup", 10)] {
            let folder = home.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("conversations"), withIntermediateDirectories: true)
            roots.append(folder)
            var db: OpaquePointer?
            #expect(sqlite3_open(folder.appendingPathComponent("conversations/c1.db").path, &db) == SQLITE_OK)
            func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
            run("CREATE TABLE steps (idx INTEGER, step_type INTEGER, metadata BLOB)")
            run("CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            run("INSERT INTO steps VALUES (0, 15, X'\(hex(bytes(1, number(1, 1792317600))))')")
            let counts = number(2, 1000) + number(3, UInt64(output)) + bytes(11, Array("response1".utf8))
            let generation = bytes(4, counts) + bytes(19, Array("gemini-3-pro".utf8))
            run("INSERT INTO gen_metadata VALUES (0, X'\(hex(bytes(1, generation)))')")
            sqlite3_close(db)
        }
        var seen: Set<Int64> = []
        let source = AntigravitySource(roots: roots)
        for phase in 0..<2 {
            for (index, root) in roots.enumerated() {
                let output = index == phase ? 100 : 10
                let counts = number(2, 1000) + number(3, UInt64(output)) + bytes(11, Array("response1".utf8))
                let generation = bytes(4, counts) + bytes(19, Array("gemini-3-pro".utf8))
                var db: OpaquePointer?
                #expect(sqlite3_open(root.appendingPathComponent("conversations/c1.db").path, &db) == SQLITE_OK)
                #expect(sqlite3_exec(db, "UPDATE gen_metadata SET data = X'\(hex(bytes(1, generation)))'", nil, nil, nil) == SQLITE_OK)
                sqlite3_close(db)
            }
            let data = await source.refresh()
            if let output = data.usage.first?.tokens.output { seen.insert(output) }
        }
        #expect(seen == [100])
    }

    @Test func cursorSymlinkedChatIsCountedTwice() async throws {
        let home = try TempProjects()
        let chats = home.root.appendingPathComponent("chats")
        let folder = chats.appendingPathComponent("hash/agent")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent("store.db").path, &db) == SQLITE_OK)
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        run("CREATE TABLE meta (key TEXT, value TEXT)")
        run("CREATE TABLE blobs (id TEXT, data BLOB)")
        let meta = json(["createdAt": 1792317600000, "latestRootBlobId": "root"])
        run("INSERT INTO meta VALUES ('0', '\(Data(meta.utf8).hexString)')")
        run("INSERT INTO blobs VALUES ('root', X'0a01aa')")
        run(#"INSERT INTO blobs VALUES ('aa', X'\#(Data(#"{"role":"assistant","content":"x"}"#.utf8).hexString)')"#)
        sqlite3_close(db)

        try FileManager.default.createSymbolicLink(at: chats.appendingPathComponent("alias"), withDestinationURL: chats.appendingPathComponent("hash"))
        let source = CursorSource(chatsURL: chats, ideStateURL: home.root.appendingPathComponent("missing.vscdb"))
        let data = await source.refresh()
        #expect(data.sessionStarts.count == 1)
        #expect(data.messageBuckets.values.reduce(0, +) == 1)
    }

    @Test func cursorReadsACPSessions() async throws {
        let home = try TempProjects()
        let acp = home.root.appendingPathComponent("acp-sessions")
        let folder = acp.appendingPathComponent("hash/agent")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent("store.db").path, &db) == SQLITE_OK)
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        run("CREATE TABLE meta (key TEXT, value TEXT)")
        run("CREATE TABLE blobs (id TEXT, data BLOB)")
        let meta = json(["createdAt": 1792317600000, "latestRootBlobId": "root"])
        run("INSERT INTO meta VALUES ('0', '\(Data(meta.utf8).hexString)')")
        run("INSERT INTO blobs VALUES ('root', X'0a01aa')")
        run(#"INSERT INTO blobs VALUES ('aa', X'\#(Data(#"{"role":"user","content":"hi"}"#.utf8).hexString)')"#)
        sqlite3_close(db)

        try FileManager.default.createSymbolicLink(at: acp.appendingPathComponent("alias"), withDestinationURL: acp.appendingPathComponent("hash"))
        let source = CursorSource(chatsURL: home.root.appendingPathComponent("chats"), ideStateURL: home.root.appendingPathComponent("missing.vscdb"))
        #expect(source.watchedPaths.contains(acp.path))
        let data = await source.refresh()
        #expect(data.sessionStarts.count == 1)
        #expect(data.messageBuckets.values.reduce(0, +) == 1)
    }
}

extension ProviderTests {
    @Test func modelsAreGroupedByDisplayName() {
        var data = UsageData()
        let bucket = FileRecord.bucket(now.timeIntervalSince1970 - 3600)
        data.usage = [
            UsageRecord(bucket: bucket, model: "claude-opus-5-5", tokens: TokenCounts(input: 10, output: 10)),
            UsageRecord(bucket: bucket, model: "claude-opus-5-5-xhigh", tokens: TokenCounts(input: 20, output: 20)),
            UsageRecord(bucket: bucket, model: "gpt-6-1-sol-high", tokens: TokenCounts(input: 5)),
        ]
        let grouped = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(grouped.models.map(\.name) == ["Opus 5.5", "GPT-6.1 Sol"])
        #expect(grouped.models.first?.tokens.total == 60)
        // Raw IDs for checking against other tools.
        let raw = StatsBuilder.build(data, range: .all, now: now, clock: utc, groupingModels: false)
        #expect(raw.models.count == 3)
        #expect(raw.favoriteModel?.id == "claude-opus-5-5-xhigh")
    }
}

import SQLite3

extension ProviderTests {
    @Test func devinCountsCopiedMessagesOnce() async throws {
        let home = try TempProjects()
        let folder = home.root.appendingPathComponent("cli")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent("sessions.db").path, &db) == SQLITE_OK)
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        let start = Int(Timestamp.parse("2026-10-18T10:00:00Z")!)
        run("CREATE TABLE sessions (id TEXT PRIMARY KEY, model TEXT, created_at INTEGER, hidden INTEGER)")
        run("CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, created_at INTEGER, chat_message TEXT)")
        run("INSERT INTO sessions VALUES ('s1', 'claude-opus-5-5-xhigh', \(start), 0), ('bg', 'swe-2', \(start), 1)")
        func message(_ id: String, _ role: String, prompt: Bool = false, tokens: (Int, Int, Int)? = nil, model: String? = nil) -> String {
            var metadata: [String: Any] = ["created_at": "2026-10-18T10:00:05Z", "is_user_input": prompt]
            if let model { metadata["generation_model"] = model }
            if let (input, output, cacheRead) = tokens {
                metadata["metrics"] = ["input_tokens": input, "output_tokens": output, "cache_read_tokens": cacheRead]
            }
            // As Devin writes it: message_id first, then role, which the reader looks for near the start.
            return #"{"message_id":"\#(id)","role":"\#(role)","content":"x","metadata":\#(json(metadata))}"#
        }
        let rows = [
            ("s1", message("u1", "user", prompt: true)),
            ("s1", message("ctx", "user")),
            ("s1", message("a1", "assistant", tokens: (100, 10, 1000), model: "claude-opus-5-5-xhigh")),
            // History rewritten into new nodes: the same messages again.
            ("s1", message("u1", "user", prompt: true)),
            ("s1", message("a1", "assistant", tokens: (100, 10, 1000), model: "claude-opus-5-5-xhigh")),
            ("s1", message("t1", "tool")),
            ("bg", message("b1", "assistant", tokens: (5, 5, 0))),
        ]
        for (session, json) in rows {
            run("INSERT INTO message_nodes (session_id, created_at, chat_message) VALUES ('\(session)', \(start), '\(json)')")
        }
        sqlite3_close(db)

        let data = await DevinSource(root: home.root).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.sessions == 1)
        // The typed prompt and the reply; not the injected context, the copies or the hidden session.
        #expect(stats.messages == 2)
        #expect(stats.totalTokens == 1110 + 10)
        #expect(stats.models.map(\.name) == ["Opus 5.5", "SWE 2"])
    }

    @Test func devinReplacementDatabaseRetainsOldRowCursor() throws {
        let home = try TempProjects()
        let path = home.root.appendingPathComponent("sessions.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        run("CREATE TABLE sessions (id TEXT, created_at INTEGER, hidden INTEGER, model TEXT)")
        run("CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY, session_id TEXT, created_at INTEGER, chat_message TEXT)")
        run("INSERT INTO sessions VALUES ('s', 1792317600, 0, 'gpt-5')")
        run(#"INSERT INTO message_nodes VALUES (100, 's', 1792317601, '{"message_id":"old","role":"assistant","metadata":{"metrics":{"input_tokens":100}}}')"#)
        var database = DevinSource.Database()
        #expect(database.read(try #require(SQLiteReader(path: path))))
        run("DELETE FROM message_nodes")
        run(#"INSERT INTO message_nodes VALUES (1, 's', 1792317602, '{"message_id":"new","role":"assistant","metadata":{"metrics":{"input_tokens":200}}}')"#)
        #expect(database.read(try #require(SQLiteReader(path: path))))
        #expect(database.lastRow == 1)
        #expect(Array(database.messages.keys) == ["new"])
        #expect(database.messages["new"]?.tokens.input == 200)
    }

    @Test func devinRewrittenMessageKeepsPartialUsage() throws {
        let home = try TempProjects()
        let path = home.root.appendingPathComponent("sessions.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        run("CREATE TABLE sessions (id TEXT, created_at INTEGER, hidden INTEGER, model TEXT)")
        run("CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY, session_id TEXT, created_at INTEGER, chat_message TEXT)")
        run("INSERT INTO sessions VALUES ('s', 1792317600, 0, 'gpt-5')")
        for (i, output) in [0, 50].enumerated() {
            let json = #"{"message_id":"a","role":"assistant","metadata":{"metrics":{"input_tokens":100,"output_tokens":\#(output)}}}"#
            run("INSERT INTO message_nodes VALUES (\(i + 1), 's', 1792317601, '\(json)')")
        }
        var database = DevinSource.Database()
        #expect(database.read(try #require(SQLiteReader(path: path))))
        #expect(database.messages.count == 1)
        #expect(database.messages["a"]?.tokens == TokenCounts(input: 100, output: 50))
    }

    @Test func devinCountsRequestCopiesOnce() async throws {
        let home = try TempProjects()
        let folder = home.root.appendingPathComponent("cli")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent("sessions.db").path, &db) == SQLITE_OK)
        func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        let start = Int(Timestamp.parse("2026-10-18T10:00:00Z")!)
        run("CREATE TABLE sessions (id TEXT PRIMARY KEY, model TEXT, created_at INTEGER, hidden INTEGER)")
        run("CREATE TABLE message_nodes (row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, created_at INTEGER, chat_message TEXT)")
        run("INSERT INTO sessions VALUES ('s1', 'gpt-5', \(start), 0)")
        for output in [10, 40] {
            let node = #"{"role":"assistant","metadata":{"request_id":"req_1","generation_model":"gpt-5","created_at":"2026-10-18T10:00:05Z","metrics":{"input_tokens":100,"output_tokens":\#(output)}}}"#
            run("INSERT INTO message_nodes (session_id, created_at, chat_message) VALUES ('s1', \(start), '\(node)')")
        }
        let plain = #"{"role":"assistant","metadata":{"request_id":"","generation_model":"gpt-5","created_at":"2026-10-18T10:00:06Z","metrics":{"input_tokens":50,"output_tokens":5}}}"#
        run("INSERT INTO message_nodes (session_id, created_at, chat_message) VALUES ('s1', \(start), '\(plain)')")
        sqlite3_close(db)

        let data = await DevinSource(root: home.root).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(data.usage.count == 2)
        #expect(stats.totalTokens == 140 + 55)
        #expect(stats.messages == 3)
    }
}
