import Foundation
import Testing
@testable import UsageCore

struct ParsingTests {
    @Test func assistantLineWithMessageBeforeType() throws {
        let line = #"{"parentUuid":"a","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","content":[{"type":"text","text":"a \"quoted\" {brace} [bracket] \\ done"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":5482,"cache_read_input_tokens":1104,"output_tokens":318,"server_tool_use":{"web_search_requests":0},"iterations":[{"input_tokens":9}]}},"type":"assistant","timestamp":"2026-10-18T21:08:12.345Z"}"#
        let parsed = try #require(TranscriptLine.parse(line))
        #expect(parsed.kind == .assistant)
        #expect(parsed.model == "claude-opus-5-5")
        #expect(parsed.messageID == fnv1a("msg_1"))
        #expect(parsed.usage == TokenCounts(input: 2, output: 318, cacheRead: 1104, cacheWrite: 5482))
        #expect(parsed.isSidechain == false)
        let expected = try Date("2026-10-18T21:08:12.345Z", strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)).timeIntervalSince1970
        #expect(abs(parsed.timestamp! - expected) < 0.001)
    }

    @Test func userLineSkipsHugeEscapedContent() throws {
        let noise = String(repeating: #"x\\\"y\\"#, count: 50_000)
        let line = #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"\#(noise)"},"toolUseResult":{"stdout":"}}]]\"","nested":[1,2,{"a":"b"}]},"timestamp":"2026-01-02T03:04:05Z"}"#
        let parsed = try #require(TranscriptLine.parse(line))
        #expect(parsed.kind == .user)
        #expect(parsed.isSidechain)
        #expect(parsed.usage == nil)
        #expect(parsed.timestamp == Double(Timestamp.daysFromCivil(year: 2026, month: 1, day: 2)) * 86_400 + 3 * 3600 + 4 * 60 + 5)
    }

    @Test func corruptCountsCantOverflow() throws {
        let line = #"{"type":"assistant","message":{"model":"m","id":"msg_9","usage":{"input_tokens":9223372036854775807,"output_tokens":-9223372036854775808,"cache_read_input_tokens":99999999999999999999999,"cache_creation_input_tokens":5}}}"#
        let usage = try #require(TranscriptLine.parse(line)?.usage)
        #expect(usage.input == 1_000_000_000_000)
        #expect(usage.output == -1_000_000_000_000)
        #expect(usage.cacheRead == 1_000_000_000_000)
        #expect(usage.total == 1_000_000_000_005)
    }

    @Test func serverNumbersSaturate() {
        #expect(Int(saturating: 41.9) == 41)
        #expect(Int(saturating: 1e300) == .max)
        #expect(Int(saturating: -1e300) == .min)
        #expect(Int(saturating: .nan) == 0)
    }

    @Test func missingDatabaseOpensNothing() {
        #expect(SQLiteReader(path: "/nonexistent/swiftusage/state.vscdb") == nil)
    }

    @Test func otherTypesAndMalformedLines() {
        #expect(TranscriptLine.parse(#"{"type":"file-history-snapshot","snapshot":{}}"#)?.kind == .other)
        #expect(TranscriptLine.parse(#"{"type":"assistant","message":{"content":"unterminated"#) == nil)
        #expect(TranscriptLine.parse("") == nil)
        #expect(TranscriptLine.parse("not json") == nil)
    }

    @Test func timestampOffsets() {
        let utc = Timestamp.parse("2026-10-18T12:00:00Z")!
        #expect(Timestamp.parse("2026-10-18T17:30:00+05:30") == utc)
        #expect(Timestamp.parse("2026-10-18T07:00:00-05:00") == utc)
        #expect(Timestamp.parse("2026-10-18T12:00:00") == utc)
        #expect(Timestamp.parse("2026-13-18T12:00:00Z") == nil)
        #expect(Timestamp.parse("yesterday") == nil)
    }

    @Test func modelNames() {
        #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.display("claude-sonnet-5") == "Sonnet 5")
        #expect(ModelName.display("claude-opus-4-8[1m]") == "Opus 4.8")
        #expect(ModelName.display("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelName.display("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ModelName.display("claude-fable-5-1") == "Fable 5.1")
        #expect(ModelName.display("opus") == "Opus")
        #expect(ModelName.display("claude-4.5-opus-high-thinking") == "Opus 4.5")
        #expect(ModelName.display("anthropic/claude-sonnet-4-5") == "Sonnet 4.5")
        #expect(ModelName.display("antigravity-claude-opus-4-5-thinking") == "Opus 4.5")
        #expect(ModelName.display("gpt-9") == "GPT-9")
        #expect(ModelName.display("gpt-5.5-codex") == "GPT-5.5 Codex")
        #expect(ModelName.display("gpt-5-mini") == "GPT-5 Mini")
        #expect(ModelName.display("o4-mini") == "o4 Mini")
        #expect(ModelName.display("gemini-2-5-pro") == "Gemini 2.5 Pro")
        #expect(ModelName.display("gemini-3-pro-preview") == "Gemini 3 Pro Preview")
        #expect(ModelName.display("grok-code-fast-1") == "Grok Code Fast 1")
        #expect(ModelName.display("deepseek-v3.2") == "DeepSeek V3.2")
        // Reasoning effort is dropped, so one model reads the same whichever tool ran it.
        #expect(ModelName.display("gpt-6-1-sol-xhigh") == "GPT-6.1 Sol")
        #expect(ModelName.display("claude-opus-5-5-xhigh-fast") == "Opus 5.5")
        #expect(ModelName.display("gemini-4-argon-high") == "Gemini 4 Argon")
        #expect(ModelName.display("gpt-5.1-codex-max") == "GPT-5.1 Codex Max")
        #expect(ModelName.display("swe-2-high") == "SWE 2")
    }

    @Test func formatting() {
        #expect(Format.compact(23_612_000_000) == "23.6B")
        #expect(Format.compact(41_200_000) == "41.2M")
        #expect(Format.compact(999_960) == "1.0M")
        #expect(Format.compact(12_345) == "12.3K")
        #expect(Format.compact(950) == "950")
        #expect(Format.grouped(242_379) == "242,379")
        #expect(Format.grouped(1234.5) == "1,234.5")
        #expect(Format.grouped(0.75) == "0.75")
        #expect(Format.grouped(12.0) == "12")
        #expect(Format.hour(0) == "12 AM")
        #expect(Format.hour(12) == "12 PM")
        #expect(Format.hour(23) == "11 PM")
        #expect(Format.hour(16) == "4 PM")
    }

    @Test func bookComparisons() {
        let shamik = TokenComparison.sentences(for: 41_200_000)
        #expect(shamik.contains("You've used ~71× more tokens than The Lord of the Rings."))
        #expect(!shamik.contains { $0.contains("The Little Prince") })
        #expect(TokenComparison.sentences(for: 30_000) == ["You've used about as many tokens as The Little Prince."])
        #expect(TokenComparison.sentences(for: 11_000) == ["You've used 50% of the tokens in The Little Prince."])
        #expect(TokenComparison.sentences(for: 0).isEmpty)
    }
}
