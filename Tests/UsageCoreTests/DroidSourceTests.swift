import Foundation
import Testing
@testable import UsageCore

/// Droid's settings files carry the tokens and its transcripts carry the messages, so a source's
/// totals are read from one and its sessions and messages from the other.
struct DroidSourceTests {
    let utc = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let now = Date(timeIntervalSince1970: Timestamp.parse("2026-11-01T20:00:00Z")!)

    private func settings(model: String, input: Int, output: Int, thinking: Int = 0,
                          cacheRead: Int = 0, cacheWrite: Int = 0,
                          inclusive: [String: Int]? = nil, children: [String: [String: Int]]? = nil,
                          subagent: Bool = false) throws -> String {
        var object: [String: Any] = [
            "model": model,
            "tokenUsage": ["inputTokens": input, "outputTokens": output, "thinkingTokens": thinking,
                           "cacheReadTokens": cacheRead, "cacheCreationTokens": cacheWrite],
        ]
        if let inclusive { object["inclusiveTokenUsage"] = inclusive }
        if let children { object["childInclusiveTokenUsageBySessionId"] = children }
        if subagent { object["tags"] = [["name": "subagent"]] }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// A line the way Droid writes it: its id, time and role before the content, so a read that stops
    /// at the first kilobyte still knows what the line is.
    private func message(_ id: String, _ time: String, _ role: String, calling: String? = nil,
                         visibility: String? = nil, text: String = "text") -> String {
        var line = #"{"type":"message","id":"\#(id)""#
        if let calling { line += #","callingSessionId":"\#(calling)""# }
        line += #","timestamp":"\#(time)","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(text)"}]"#
        if let visibility { line += #","visibility":"\#(visibility)""# }
        return line + "}}"
    }

    @Test func aSessionsOwnTotalIsCountedAndTheSubagentItStartedCountsOnceBesideIt() async throws {
        let home = try TempProjects()
        let root = home.root
        try home.write("proj/parent.settings.json", [
            try settings(model: "claude-opus-5-5", input: 100, output: 10, thinking: 5, cacheRead: 20,
                         inclusive: ["inputTokens": 300, "outputTokens": 40, "thinkingTokens": 5,
                                     "cacheReadTokens": 20, "cacheCreationTokens": 0],
                         children: ["child": ["inputTokens": 200, "outputTokens": 30]]),
        ])
        try home.write("proj/child.settings.json", [
            try settings(model: "glm-5.3-flash", input: 200, output: 30, subagent: true),
        ])
        try home.write("proj/parent.jsonl", [
            #"{"type":"session_start","id":"parent"}"#,
            message("m1", "2026-10-01T10:00:00.000Z", "user"),
            message("m2", "2026-10-18T10:00:00.000Z", "assistant"),
        ])
        try home.write("proj/child.jsonl", [
            message("s1", "2026-10-18T11:00:00.000Z", "assistant", calling: "parent"),
        ])

        let usage = await DroidSource(root: root).refresh()
        #expect(usage.usage.count == 2)
        let total = usage.usage.reduce(TokenCounts()) {
            TokenCounts(input: $0.input + $1.tokens.input, output: $0.output + $1.tokens.output,
                        cacheRead: $0.cacheRead + $1.tokens.cacheRead, cacheWrite: $0.cacheWrite + $1.tokens.cacheWrite)
        }
        #expect(total.input == 300 && total.output == 45 && total.cacheRead == 20)
        #expect(usage.usage.first { $0.model == "claude-opus-5-5" }?.tokens.output == 15)

        // The subagent's transcript carries the session it was called from, so it adds tokens but not
        // a session or a message.
        let index = await TranscriptIndex<DroidTranscripts>(root: root, cacheURL: nil).refresh()
        #expect(index.sessionStarts.count == 1)
        #expect(index.messageBuckets.values.reduce(0, +) == 1)
    }

    @Test func aSessionThatRanOverSeveralDaysIsKeptOutOfTheDailyFigures() async throws {
        let home = try TempProjects()
        let root = home.root
        try home.write("proj/long.settings.json", [try settings(model: "gpt-5.5", input: 1_000, output: 100)])
        try home.write("proj/long.jsonl", [
            message("a", "2026-10-01T10:00:00.000Z", "user"),
            message("b", "2026-10-03T12:00:00.000Z", "assistant"),
            message("c", "2026-10-18T14:00:00.000Z", "assistant"),
        ])

        let usage = await DroidSource(root: root).refresh()
        let record = try #require(usage.usage.first)
        #expect(record.bucket == FileRecord.bucket(Timestamp.parse("2026-10-18T14:00:00Z")!))
        #expect(record.firstBucket == FileRecord.bucket(Timestamp.parse("2026-10-01T10:00:00Z")!))

        let stats = StatsBuilder.build(usage, range: .all, now: now, clock: utc)
        #expect(stats.totalTokens == 1_100)
        #expect(stats.unallocatedTokens == 1_100)
        #expect(stats.days.values.reduce(Int64(0)) { $0 + $1.tokens } == 0)
    }

    @Test func aLongTranscriptIsDatedFromItsFirstAndLastKilobytes() async throws {
        let home = try TempProjects()
        let root = home.root
        try home.write("proj/fat.settings.json", [try settings(model: "gpt-5.5", input: 10, output: 1)])
        let bulk = String(repeating: "x", count: 200_000)
        try home.write("proj/fat.jsonl", [
            message("a", "2026-09-01T09:00:00.000Z", "user"),
            message("b", "2026-09-01T09:30:00.000Z", "user", text: bulk),
            message("c", "2026-09-02T18:00:00.000Z", "assistant"),
        ])

        let usage = await DroidSource(root: root).refresh()
        let record = try #require(usage.usage.first)
        #expect(record.bucket == FileRecord.bucket(Timestamp.parse("2026-09-02T18:00:00Z")!))
        #expect(record.firstBucket == FileRecord.bucket(Timestamp.parse("2026-09-01T09:00:00Z")!))
    }

    @Test func aSessionWithoutTokensAddsNoResponse() async throws {
        let home = try TempProjects()
        let root = home.root
        try home.write("proj/empty.settings.json", [try settings(model: "gpt-5.5", input: 0, output: 0)])
        #expect(await DroidSource(root: root).refresh().usage.isEmpty)
    }

    @Test func aSessionCopiedBesideASecondProjectCountsOnce() async throws {
        let home = try TempProjects()
        let root = home.root
        // Droid copies a session's files into the new project folder when a workspace moves, so the
        // same session id can sit twice; the copy that counted the most holds its total.
        try home.write("old/7f.settings.json", [try settings(model: "gpt-5.5", input: 10, output: 1)])
        try home.write("new/7f.settings.json", [try settings(model: "gpt-5.5", input: 100, output: 10)])
        try home.write("old/7f.jsonl", [message("m1", "2026-10-01T10:00:00.000Z", "assistant")])
        try home.write("new/7f.jsonl", [
            message("m1", "2026-10-01T10:00:00.000Z", "assistant"),
            message("m2", "2026-10-01T10:20:00.000Z", "assistant"),
        ])

        let usage = await DroidSource(root: root).refresh()
        #expect(usage.usage.count == 1)
        #expect(usage.usage.first?.tokens.input == 100 && usage.usage.first?.tokens.output == 10)
        #expect(usage.usage.first?.bucket == FileRecord.bucket(Timestamp.parse("2026-10-01T10:20:00Z")!))

        // Another session in the same folder is a session of its own.
        try home.write("new/other.settings.json", [try settings(model: "gpt-5.5", input: 5, output: 1)])
        #expect(await DroidSource(root: root).refresh().usage.count == 2)
    }

    @Test func aParentThatQuotesACallingSessionInItsContentIsNotASubagent() async throws {
        let home = try TempProjects()
        let root = home.root
        // A tool result can carry another transcript's line, calling session and all.
        let quoted = #"tool output: {"callingSessionId":"child"}"#
        try home.write("proj/parent.jsonl", [
            #"{"type":"session_start","id":"parent"}"#,
            message("m1", "2026-10-01T10:00:00.000Z", "assistant", text: quoted),
            message("m2", "2026-10-01T10:05:00.000Z", "assistant"),
        ])

        let index = await TranscriptIndex<DroidTranscripts>(root: root, cacheURL: nil).refresh()
        #expect(index.sessionStarts.count == 1)
        #expect(index.messageBuckets.values.reduce(0, +) == 2)
    }

    @Test func droidJoinsItsFolderToTheHomeOverride() throws {
        let key = "FACTORY_HOME_OVERRIDE"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, "/tmp/droid-home", 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        #expect(DroidSource.defaultRoot.path == "/tmp/droid-home/.factory/sessions")
        #expect(DroidTranscripts.defaultRoot == DroidSource.defaultRoot)
    }

    @Test func aContinuedSessionsCopiedMessagesCountOnce() async throws {
        let home = try TempProjects()
        let root = home.root
        try home.write("proj/first.settings.json", [try settings(model: "gpt-5.5", input: 10, output: 1)])
        try home.write("proj/first.jsonl", [
            message("m1", "2026-10-01T10:00:00.000Z", "user"),
            message("m2", "2026-10-01T10:05:00.000Z", "assistant"),
        ])
        try home.write("proj/continued.settings.json", [try settings(model: "gpt-5.5", input: 20, output: 2)])
        try home.write("proj/continued.jsonl", [
            message("m1", "2026-10-01T10:00:00.000Z", "user"),
            message("m2", "2026-10-01T10:05:00.000Z", "assistant"),
            message("m3", "2026-10-01T11:00:00.000Z", "assistant"),
        ])

        // The continued session holds every message the first one wrote, so the first is set aside
        // and the copied message counts once.
        let index = await TranscriptIndex<DroidTranscripts>(root: root, cacheURL: nil).refresh()
        #expect(index.sessionStarts.count == 1)
        #expect(index.messageBuckets.values.reduce(0, +) == 2)
    }
}
