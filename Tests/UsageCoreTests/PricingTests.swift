import Foundation
import Testing
@testable import UsageCore

struct PricingTests {
    let utc = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let now = Date(timeIntervalSince1970: Timestamp.parse("2026-10-18T20:00:00Z")!)

    /// Opus at Anthropic's rates, GPT-6 Sol with its long-prompt tier, and a supplement-only fast mode.
    let prices = PriceList(
        prices: [
            "claude-opus-5-5": ModelPrice(base: .init(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, cacheWriteHour: 8)),
            "claude-fable-5": ModelPrice(base: .init(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5, cacheWriteHour: 20)),
            "gpt-6-sol": ModelPrice(base: .init(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5), threshold: 272_000,
                                    long: .init(input: 4, output: 15, cacheRead: 0.4, cacheWrite: 5), fast: 2),
            "grok-4-6": ModelPrice(base: .init(input: 2, output: 6, cacheRead: 0.5, cacheWrite: 2)),
            "gpt-5-5": ModelPrice(base: .init(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5)),
            "gemini-3-flash-preview": ModelPrice(base: .init(input: 0.5, output: 3, cacheRead: 0.05, cacheWrite: 0.5)),
        ],
        supplement: [
            "claude-opus-5-5-fast": ModelPrice(base: .init(input: 8, output: 40, cacheRead: 0.4, cacheWrite: 10, cacheWriteHour: 16)),
        ],
        aliases: [PriceList.Alias(pattern: try! NSRegularExpression(pattern: "^gemini-3-flash(?:-(?:low|high))?$"), canonical: "gemini-3-flash-preview")])

    @Test func claudeLinesRecordHourLongCacheWritesAndSpeed() throws {
        let line = try #require(TranscriptLine.parse(#"{"type":"assistant","timestamp":"2026-10-18T10:00:00Z","message":{"model":"claude-opus-5-5","id":"msg_1","usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":10000,"cache_creation_input_tokens":4000,"cache_creation":{"ephemeral_1h_input_tokens":3000,"ephemeral_5m_input_tokens":1000},"iterations":[{"input_tokens":5}],"speed":"fast"}}}"#))
        #expect(line.usage == TokenCounts(input: 1000, output: 2000, cacheRead: 10000, cacheWrite: 4000))
        #expect(line.cacheWriteHour == 3000)
        #expect(line.speed == .fast)

        let tokens = try #require(line.usage)
        // 1000 × $4 + 2000 × $20 + 10,000 × $0.20 + 1000 × $5 + 3000 × $8, per million.
        let standard = try #require(prices.price(for: "claude-opus-5-5"))
        #expect(abs(standard.cost(tokens, cacheWriteHour: 3000) - 0.075) < 1e-9)
        // Fast mode is listed as a model of its own, at twice the rates.
        let fast = try #require(prices.price(for: "claude-opus-5-5", speed: .fast))
        #expect(abs(fast.cost(tokens, cacheWriteHour: 3000) - 0.15) < 1e-9)
    }

    @Test func longPromptsAndFastModesBillHigher() throws {
        let sol = try #require(prices.price(for: "gpt-6-sol"))
        let short = TokenCounts(input: 100_000, output: 1000, cacheRead: 100_000)
        #expect(abs(sol.cost(short) - (100_000 * 2 + 1000 * 10 + 100_000 * 0.2) / 1e6) < 1e-9)
        // Past 272k prompt tokens the whole request moves to the long rates.
        let long = TokenCounts(input: 200_000, output: 1000, cacheRead: 100_000)
        #expect(abs(sol.cost(long) - (200_000 * 4 + 1000 * 15 + 100_000 * 0.4) / 1e6) < 1e-9)
        let fast = try #require(prices.price(for: "gpt-6-sol", speed: .fast))
        #expect(abs(fast.cost(short) - 2 * sol.cost(short)) < 1e-9)
        // A model without a known fast rate keeps its standard one.
        #expect(prices.price(for: "grok-4.6", speed: .fast) == prices.price(for: "grok-4.6"))
    }

    @Test func namesResolveAcrossToolSpellings() {
        let opus = prices.price(for: "claude-opus-5-5")
        #expect(opus != nil)
        for spelling in ["claude-opus-5-5[1m]", "anthropic/claude-opus-5-5", "claude-opus-5-5-20260901", "claude-opus-5.5-thinking-xhigh",
                         "antigravity-claude-opus-5-5-thinking", "CLAUDE-OPUS-5-5"] {
            #expect(prices.price(for: spelling) == opus, "\(spelling)")
        }
        #expect(prices.price(for: "claude-5-fable-high") == prices.price(for: "claude-fable-5"))
        #expect(prices.price(for: "grok-4.6") != nil)
        #expect(prices.price(for: "xai/grok-4-6") == prices.price(for: "grok-4.6"))
        #expect(prices.price(for: "gpt-5.5-2026-04-23") == prices.price(for: "gpt-5.5"))
        #expect(prices.price(for: "antigravity-gemini-3-flash") == prices.price(for: "gemini-3-flash-preview"))
        #expect(prices.price(for: "opencode/deepseek-v4.1-flash-free")?.cost(TokenCounts(input: 1_000_000)) == 0)
        #expect(prices.price(for: "codex-auto-review")?.cost(TokenCounts(input: 1_000_000)) == 0)
        #expect(prices.price(for: "swe-2-high") == nil)
    }

    @Test func litellmListConverts() throws {
        let list: [String: Any] = [
            "claude-opus-5-5": ["litellm_provider": "anthropic", "mode": "chat", "input_cost_per_token": 4e-06, "output_cost_per_token": 2e-05,
                                "cache_read_input_token_cost": 2e-07, "cache_creation_input_token_cost": 5e-06],
            "gpt-6-sol": ["litellm_provider": "openai", "mode": "responses", "input_cost_per_token": 2e-06, "output_cost_per_token": 1e-05,
                          "input_cost_per_token_above_272k_tokens": 4e-06, "output_cost_per_token_above_272k_tokens": 1.5e-05,
                          "input_cost_per_token_priority": 4e-06],
            // A reseller's copy at a markup, and a cloud mirror, lose to the first-party entry.
            "aihubmix/gpt-6-sol": ["litellm_provider": "aihubmix", "mode": "chat", "input_cost_per_token": 9e-06, "output_cost_per_token": 9e-05],
            "bedrock/anthropic.claude-opus-5-5": ["litellm_provider": "bedrock", "input_cost_per_token": 9e-06, "output_cost_per_token": 9e-05],
            "xai/grok-4.6": ["litellm_provider": "xai", "mode": "chat", "input_cost_per_token": 2e-06, "output_cost_per_token": 6e-06],
            "text-embedding-4": ["litellm_provider": "openai", "mode": "embedding", "input_cost_per_token": 1e-07, "output_cost_per_token": 0],
            "sample_spec": "not a model",
        ]
        let prices = try #require(PriceSources.litellm(JSONSerialization.data(withJSONObject: list)))
        #expect(prices["claude-opus-5-5"]?.base == ModelPrice.Rates(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, cacheWriteHour: 8))
        let sol = try #require(prices["gpt-6-sol"])
        #expect(sol.base.input == 2)
        #expect(sol.threshold == 272_000)
        #expect(sol.long?.input == 4)
        #expect(sol.long?.output == 15)
        #expect(sol.fast == 2)
        // Without a listed cache price, cached input costs the input rate.
        #expect(sol.base.cacheRead == 2)
        #expect(prices["grok-4-6"]?.base.output == 6)
        #expect(prices["text-embedding-4"] == nil)
        #expect(prices["anthropic-claude-opus-5-5"] == nil)
    }

    @Test func statsAddUpCostsAndListUnpricedModels() {
        var data = UsageData()
        let bucket = FileRecord.bucket(Timestamp.parse("2026-10-18T10:00:00Z")!)
        data.usage = [
            UsageRecord(bucket: bucket, model: "claude-opus-5-5", tokens: TokenCounts(input: 1_000_000)),
            UsageRecord(bucket: bucket, model: "claude-opus-5-5", tokens: TokenCounts(output: 1_000_000), speed: .fast),
            UsageRecord(bucket: bucket - 96, model: "swe-2-high", tokens: TokenCounts(input: 5000)),
            // What the tool logged wins over the estimate; a logged zero doesn't.
            UsageRecord(bucket: bucket, model: "grok-4.6", tokens: TokenCounts(input: 1_000_000), cost: 3.5),
            UsageRecord(bucket: bucket, model: "grok-4.6", tokens: TokenCounts(input: 1_000_000), cost: 0),
        ]
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc, prices: prices)
        #expect(abs(stats.cost - (4 + 40 + 3.5 + 2)) < 1e-9)
        #expect(stats.unpricedModels == ["SWE 2"])
        #expect(stats.models.first { $0.name == "Opus 5.5" }?.cost == 44)
        #expect(stats.models.first { $0.name == "SWE 2" }?.cost == nil)
        let today = utc.day(of: now.timeIntervalSince1970)
        #expect(abs((stats.days[today]?.cost ?? 0) - 49.5) < 1e-9)
        #expect(stats.days[today - 1]?.cost == 0)
    }

    @Test func usageRecordsLeaveDefaultsOutOfTheIndex() throws {
        let plain = UsageRecord(bucket: 1, model: "m", tokens: TokenCounts(input: 1))
        let encoded = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!encoded.contains("\"h\"") && !encoded.contains("\"s\"") && !encoded.contains("\"c\""))
        let detailed = UsageRecord(bucket: 1, model: "m", tokens: TokenCounts(cacheWrite: 10), cacheWriteHour: 7, speed: .ultrafast, cost: 0.25)
        #expect(try JSONDecoder().decode(UsageRecord.self, from: JSONEncoder().encode(detailed)) == detailed)
        // Indexes saved before these fields existed still decode.
        let old = try JSONDecoder().decode(UsageRecord.self, from: Data(#"{"b":1,"m":"m","t":{"i":1,"o":0,"r":0,"w":0}}"#.utf8))
        #expect(old == plain)
    }

    @Test func olderIndexesUpgradeWithoutLosingDeletedHistory() async throws {
        let projects = try TempProjects()
        let cache = projects.root.deletingLastPathComponent().appendingPathComponent("cache/index.json")
        try projects.write("-old/s-old.jsonl", [Lines.user("2026-09-01T12:00:00Z"), Lines.assistant("2026-09-01T12:00:01Z", id: "msg_old")])
        let kept = #"{"type":"assistant","timestamp":"2026-10-18T12:00:01Z","message":{"model":"claude-opus-5-5","id":"msg_new","usage":{"input_tokens":1,"output_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":1000}}}}"#
        try projects.write("-new/s-new.jsonl", [Lines.user("2026-10-18T12:00:00Z"), kept])

        let index = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        _ = await index.refresh()
        await index.save()

        // The saved index becomes one from the previous version, written before one-hour cache writes were
        // recorded, and Claude Code then prunes the old transcript.
        func dropHourField(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { $0.key != "h" }.mapValues(dropHourField)
            }
            if let array = value as? [Any] { return array.map(dropHourField) }
            return value
        }
        var file = try #require(dropHourField(JSONSerialization.jsonObject(with: Data(contentsOf: cache))) as? [String: Any])
        file["version"] = ClaudeTranscripts.upgradableCacheVersion
        try JSONSerialization.data(withJSONObject: file).write(to: cache)
        try FileManager.default.removeItem(at: projects.root.appendingPathComponent("-old"))

        let data = await UsageIndex(projectsURL: projects.root, cacheURL: cache).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.sessions == 2)
        #expect(stats.messages == 4)
        // The transcript still on disk was read again, so its one-hour cache write is known.
        #expect(data.usage.first { $0.bucket == FileRecord.bucket(Timestamp.parse("2026-10-18T12:00:01Z")!) }?.cacheWriteHour == 1000)
    }

    @Test func reviewUpgradeRetriesUnreadableTranscript() async throws {
        let projects = try TempProjects()
        let cache = projects.root.deletingLastPathComponent().appendingPathComponent("cache.json")
        let line = #"{"type":"assistant","timestamp":"2026-10-18T10:00:00Z","message":{"id":"hour","model":"claude-opus-5-5","usage":{"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":1000}}}}"#
        let transcript = try projects.write("-p/s.jsonl", [line])
        let first = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        _ = await first.refresh()
        await first.save()
        var file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        file["version"] = ClaudeTranscripts.upgradableCacheVersion
        func dropHour(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { $0.key != "h" }.mapValues(dropHour)
            }
            if let array = value as? [Any] { return array.map(dropHour) }
            return value
        }
        try JSONSerialization.data(withJSONObject: dropHour(file)).write(to: cache)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: transcript.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript.path) }
        #expect((try? Data(contentsOf: transcript)) == nil)
        let upgrading = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        _ = await upgrading.refresh()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript.path)
        let restored = await upgrading.refresh()
        #expect(restored.usage.first?.cacheWriteHour == 1000)
    }
}
