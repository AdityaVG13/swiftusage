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

    // MARK: OpenCode

    @Test func openCodeReasoningIsAddedOnlyWhenSeparate() {
        typealias Database = OpenCodeSource.Database
        // Newer builds: reasoning beside output, and the total says so.
        #expect(Database.tokens(input: 10, output: 5, reasoning: 3, cacheRead: 100, cacheWrite: 0, total: 118, provider: "openai", reasoningAlwaysSeparate: false).output == 8)
        // Older OpenAI-style builds: reasoning already inside output.
        #expect(Database.tokens(input: 10, output: 5, reasoning: 3, cacheRead: 100, cacheWrite: 0, total: 115, provider: "openai", reasoningAlwaysSeparate: false).output == 5)
        // No total recorded: Google kept it separate.
        #expect(Database.tokens(input: 10, output: 5, reasoning: 3, cacheRead: 0, cacheWrite: 0, total: nil, provider: "google", reasoningAlwaysSeparate: false).output == 8)
        #expect(Database.tokens(input: 10, output: 5, reasoning: 3, cacheRead: 0, cacheWrite: 0, total: nil, provider: "openai", reasoningAlwaysSeparate: false).output == 5)
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
}
