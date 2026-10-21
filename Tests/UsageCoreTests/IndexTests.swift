import Foundation
import Testing
@testable import UsageCore

/// Builds transcript lines in Claude Code's shape.
enum Lines {
    static func user(_ time: String, uuid: String = UUID().uuidString, sidechain: Bool = false) -> String {
        #"{"type":"user","uuid":"\#(uuid)","isSidechain":\#(sidechain),"message":{"role":"user","content":"hi"},"timestamp":"\#(time)"}"#
    }

    static func assistant(_ time: String, id: String, model: String = "claude-opus-5-5", input: Int = 1, output: Int = 10, cacheRead: Int = 100, cacheWrite: Int = 1000, sidechain: Bool = false) -> String {
        #"{"isSidechain":\#(sidechain),"message":{"model":"\#(model)","id":"\#(id)","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)}},"type":"assistant","timestamp":"\#(time)"}"#
    }

    static func attachment(_ time: String) -> String {
        #"{"type":"attachment","attachment":{"type":"x"},"timestamp":"\#(time)"}"#
    }
}

final class TempProjects {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usagegraphs-tests-\(UUID().uuidString)/projects")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    @discardableResult
    func write(_ relative: String, _ lines: [String], trailingNewline: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    func append(_ relative: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(relative))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

struct IndexTests {
    let utc = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let now = Date(timeIntervalSince1970: Timestamp.parse("2026-10-18T20:00:00Z")!)

    @Test func streamedBlocksCountOnceAndSubagentsAddTokensOnly() async throws {
        let projects = try TempProjects()
        try projects.write("-Users-me-app/s1.jsonl", [
            Lines.user("2026-10-18T10:00:00Z"),
            Lines.assistant("2026-10-18T10:00:05Z", id: "msg_a", output: 5),
            Lines.assistant("2026-10-18T10:00:06Z", id: "msg_a", output: 20),
            Lines.attachment("2026-10-18T10:00:07Z"),
            Lines.user("2026-10-18T10:01:00Z"),
            Lines.assistant("2026-10-18T10:01:05Z", id: "msg_b", model: "claude-haiku-5-5"),
            Lines.assistant("2026-10-18T10:02:00Z", id: "msg_side", sidechain: true),
            #"{"type":"assistant","message":{"model":"<synthetic>","id":"msg_err","usage":{"input_tokens":0,"output_tokens":0}},"timestamp":"2026-10-18T10:03:00Z"}"#,
        ])
        try projects.write("-Users-me-app/s1/subagents/agent-1.jsonl", [
            Lines.user("2026-10-18T10:00:30Z"),
            Lines.assistant("2026-10-18T10:00:40Z", id: "msg_sub", model: "claude-haiku-5-5"),
            Lines.assistant("2026-10-18T10:00:40Z", id: "msg_a", output: 20),
        ])

        let data = await UsageIndex(projectsURL: projects.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)

        #expect(stats.sessions == 1)
        // Two prompts and two replies; the synthetic error notice isn't a reply.
        #expect(stats.messages == 4)
        let perResponse: Int64 = 1 + 10 + 100 + 1000
        // msg_a keeps its final usage (output 20); msg_b, the sidechain and the subagent count once each.
        #expect(stats.totalTokens == (1 + 20 + 100 + 1000) + perResponse * 3)
        #expect(stats.favoriteModel?.name == "Opus 5.5")
        #expect(stats.models.map(\.name) == ["Opus 5.5", "Haiku 5.5"])
        #expect(stats.activeDays == 1)
        #expect(stats.peakHour == 10)
    }

    @Test func workflowSubagentsAddTokensOnly() async throws {
        let projects = try TempProjects()
        try projects.write("-Users-me-app/s1.jsonl", [
            Lines.user("2026-10-18T10:00:00Z"),
            Lines.assistant("2026-10-18T10:00:05Z", id: "msg_main", input: 100, output: 10, cacheRead: 0, cacheWrite: 0),
        ])
        try projects.write("-Users-me-app/s1/subagents/agent-a.jsonl", [
            Lines.user("2026-10-18T10:00:10Z"),
            Lines.assistant("2026-10-18T10:00:15Z", id: "msg_sub", input: 200, output: 20, cacheRead: 0, cacheWrite: 0),
        ])
        try projects.write("-Users-me-app/s1/subagents/workflows/wf_1/agent-b.jsonl", [
            Lines.user("2026-10-18T10:00:20Z"),
            Lines.assistant("2026-10-18T10:00:25Z", id: "msg_wf", input: 300, output: 30, cacheRead: 0, cacheWrite: 0),
        ])
        try projects.write("-Users-me-app/s1/subagents/workflows/wf_1/journal.jsonl", [
            Lines.assistant("2026-10-18T10:00:30Z", id: "msg_journal", input: 900, output: 90, cacheRead: 0, cacheWrite: 0),
        ])

        let data = await UsageIndex(projectsURL: projects.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.sessions == 1)
        #expect(stats.messages == 2)
        #expect(stats.totalTokens == 660)
    }

    @Test func advisorIterationsAddUsageOnTheirOwnModel() async throws {
        let projects = try TempProjects()
        let line = #"""
        {"type":"assistant","timestamp":"2026-10-18T10:00:05Z","message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"iterations":[{"type":"message","model":null,"input_tokens":100,"output_tokens":10},{"type":"advisor_message","model":"claude-opus-5-5","input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":50}]}}}
        """#
        try projects.write("-Users-me-app/s1.jsonl", [line, line])

        let data = await UsageIndex(projectsURL: projects.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.sessions == 1)
        #expect(stats.messages == 1)
        #expect(stats.totalTokens == 110 + 1350)
        #expect(stats.models.map(\.name) == ["Opus 5.5", "Sonnet 5"])
    }

    @Test func appendedLinesAreReadIncrementally() async throws {
        let projects = try TempProjects()
        let path = "-p/s.jsonl"
        let first = Lines.user("2026-10-18T09:00:00Z")
        let second = Lines.assistant("2026-10-18T09:00:01Z", id: "msg_1", output: 5)
        let secondFinal = Lines.assistant("2026-10-18T09:00:02Z", id: "msg_1", output: 50)
        // The second line is half written when the first scan happens.
        try projects.write(path, [first, String(second.prefix(40))], trailingNewline: false)

        let index = UsageIndex(projectsURL: projects.root, cacheURL: nil)
        var data = await index.refresh()
        #expect(StatsBuilder.build(data, range: .all, now: now, clock: utc).messages == 1)
        #expect(data.usage.isEmpty)

        try projects.append(path, String(second.dropFirst(40)) + "\n" + secondFinal + "\n" + Lines.user("2026-10-18T19:00:00Z") + "\n")
        data = await index.refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)

        let fresh = await UsageIndex(projectsURL: projects.root, cacheURL: nil).refresh()
        let freshStats = StatsBuilder.build(fresh, range: .all, now: now, clock: utc)
        #expect(stats.messages == 3)
        #expect(stats.totalTokens == 1 + 50 + 100 + 1000)
        #expect(stats.messages == freshStats.messages)
        #expect(stats.totalTokens == freshStats.totalTokens)
        #expect(stats.days == freshStats.days)
    }

    @Test func historySurvivesPrunedTranscriptsAndCachePersists() async throws {
        let projects = try TempProjects()
        let cache = projects.root.deletingLastPathComponent().appendingPathComponent("cache/index.json")
        try projects.write("-old/s-old.jsonl", [Lines.user("2026-09-01T12:00:00Z"), Lines.assistant("2026-09-01T12:00:01Z", id: "msg_old")])
        try projects.write("-new/s-new.jsonl", [Lines.user("2026-10-18T12:00:00Z"), Lines.assistant("2026-10-18T12:00:01Z", id: "msg_new")])

        let index = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        _ = await index.refresh()
        await index.save()

        // Claude Code prunes the old transcript, and a project folder gets renamed.
        try FileManager.default.removeItem(at: projects.root.appendingPathComponent("-old"))
        try FileManager.default.moveItem(at: projects.root.appendingPathComponent("-new"), to: projects.root.appendingPathComponent("-renamed"))

        let reopened = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        let data = await reopened.refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.sessions == 2)
        #expect(stats.messages == 4)
        #expect(stats.totalTokens == 2 * (1 + 10 + 100 + 1000))
        #expect(StatsBuilder.build(data, range: .days30, now: now, clock: utc).sessions == 1)
    }

    @Test func zeroedRepeatLinesDontEraseUsage() async throws {
        let projects = try TempProjects()
        try projects.write("-p/s.jsonl", [
            Lines.user("2026-10-18T09:00:00Z"),
            Lines.assistant("2026-10-18T09:00:01Z", id: "msg_1", output: 4),
            Lines.assistant("2026-10-18T09:00:02Z", id: "msg_1", output: 400),
            Lines.assistant("2026-10-18T09:00:03Z", id: "msg_1", input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        ])
        let data = await UsageIndex(projectsURL: projects.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.totalTokens == 1 + 400 + 100 + 1000)
        #expect(stats.messages == 2)
    }

    @Test func copiedHistoryCountsOnce() async throws {
        let projects = try TempProjects()
        let history = [
            Lines.user("2026-10-18T08:00:00Z", uuid: "u1"),
            Lines.assistant("2026-10-18T08:00:05Z", id: "msg_1"),
            Lines.user("2026-10-18T08:01:00Z", uuid: "u2"),
            Lines.assistant("2026-10-18T08:01:05Z", id: "msg_2"),
        ]
        // A session continued in a new transcript, which starts with a copy of the old one.
        try projects.write("-p/original.jsonl", history + [#"{"type":"continued-in","continuedInSessionId":"continuation"}"#])
        try projects.write("-p/continuation.jsonl", history + [Lines.user("2026-10-18T12:00:00Z", uuid: "u3"), Lines.assistant("2026-10-18T12:00:05Z", id: "msg_3")])
        // A fork of the same history that went its own way.
        try projects.write("-p/fork.jsonl", history + [Lines.user("2026-10-18T13:00:00Z", uuid: "u4"), Lines.assistant("2026-10-18T13:00:05Z", id: "msg_4")])
        // Claude Code sometimes writes the same entry twice in one transcript.
        try projects.write("-q/other.jsonl", [Lines.user("2026-10-18T15:00:00Z", uuid: "u5"), Lines.user("2026-10-18T15:00:00Z", uuid: "u5")])

        let data = await UsageIndex(projectsURL: projects.root, cacheURL: nil).refresh()
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.sessions == 3)
        #expect(stats.messages == 9)
        #expect(stats.totalTokens == 4 * (1 + 10 + 100 + 1000))
    }

    @Test func manyCopiedPairsDeduplicateWithoutQuadraticScan() async throws {
        let projects = try TempProjects()
        let index = UsageIndex(projectsURL: projects.root, cacheURL: nil)
        let stamp = Timestamp.parse("2026-10-18T08:00:00Z")!
        let bucket = FileRecord.bucket(stamp)
        var records: [String: FileRecord] = [:]
        records.reserveCapacity(12_000)
        for pair in 0..<6000 {
            var record = FileRecord(isSubagent: false)
            record.sessionStart = stamp + Double(pair)
            record.messages[UInt64(pair + 1)] = bucket
            records[String(format: "-p/c%05d-a.jsonl", pair)] = record
            records[String(format: "-p/c%05d-b.jsonl", pair)] = record
        }
        let started = Date()
        let data = await index.aggregate(records)
        let elapsed = Date().timeIntervalSince(started)
        #expect(data.sessionStarts.count == 6000)
        #expect(data.messageBuckets == [bucket: 6000])
        #expect(elapsed < 1.0)
    }

    @Test func daylightSavingDays() {
        let warsaw = DayClock(timeZone: TimeZone(identifier: "Europe/Warsaw")!)
        // Clocks go back at 03:00 CEST on 25 Oct 2026 (01:00 UTC).
        let beforeMidnight = Timestamp.parse("2026-10-24T21:59:59Z")!
        let afterMidnight = Timestamp.parse("2026-10-24T22:00:00Z")!
        let lateSunday = Timestamp.parse("2026-10-25T22:59:59Z")!
        let monday = Timestamp.parse("2026-10-25T23:00:00Z")!
        #expect(warsaw.day(of: afterMidnight) == warsaw.day(of: beforeMidnight) + 1)
        #expect(warsaw.day(of: lateSunday) == warsaw.day(of: afterMidnight))
        #expect(warsaw.day(of: monday) == warsaw.day(of: lateSunday) + 1)
        #expect(warsaw.hour(of: lateSunday) == 23)

        var data = UsageData()
        data.messageBuckets = [Int32(lateSunday / 900): 1, Int32(monday / 900): 1]
        let stats = StatsBuilder.build(data, range: .all, now: Date(timeIntervalSince1970: monday), clock: warsaw)
        #expect(stats.days[stats.today]?.messages == 1)
        #expect(stats.days[stats.today - 1]?.messages == 1)
    }

    @Test func daysFollowTheLocalClock() {
        let kolkata = DayClock(timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        var data = UsageData()
        // 20:00 UTC is 01:30 the next day in India.
        let late = Timestamp.parse("2026-10-17T20:00:00Z")!
        data.sessionStarts = [late, Timestamp.parse("2026-10-17T21:00:00Z")!, Timestamp.parse("2026-10-17T05:00:00Z")!]
        data.messageBuckets = [Int32(late / 900): 4]
        data.usage = [UsageRecord(bucket: Int32(late / 900), model: "claude-opus-5-5", tokens: TokenCounts(output: 7))]

        let stats = StatsBuilder.build(data, range: .days7, now: Date(timeIntervalSince1970: Timestamp.parse("2026-10-18T06:00:00Z")!), clock: kolkata)
        let oct18 = kolkata.day(of: Timestamp.parse("2026-10-18T06:00:00Z")!)
        #expect(stats.today == oct18)
        #expect(stats.days[oct18]?.messages == 4)
        #expect(stats.days[oct18]?.sessions == 2)
        #expect(stats.days[oct18]?.tokens == 7)
        #expect(stats.days[oct18 - 1]?.sessions == 1)
        #expect(stats.activeDays == 2)
        // 01:30 and 02:30 are the 1 AM and 2 AM hours, 10:30 the 10 AM hour: ties go to the earliest.
        #expect(stats.peakHour == 1)
        #expect(DayClock.weekday(of: oct18) == 1)
    }

    @Test func rangesCutAtTheRightDay() {
        var data = UsageData()
        let days = [0, 6, 7, 29, 30].map { now.timeIntervalSince1970 - Double($0) * 86_400 }
        data.sessionStarts = days
        let counts = StatsRange.allCases.map { StatsBuilder.build(data, range: $0, now: now, clock: utc).sessions }
        #expect(counts == [5, 4, 2])
    }

    @Test func reviewTokensOnlyDayIsActive() {
        var data = UsageData()
        data.usage = [UsageRecord(bucket: FileRecord.bucket(Timestamp.parse("2026-10-18T10:00:00Z")!), model: "claude-opus-5-5", tokens: TokenCounts(output: 100))]
        let stats = StatsBuilder.build(data, range: .all, now: now, clock: utc)
        #expect(stats.activeDays == 1)
    }

    @Test func unreadableFilesKeepTheirSummary() async throws {
        let projects = try TempProjects()
        let url = try projects.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:00Z"), Lines.assistant("2026-10-18T09:00:01Z", id: "msg_1")])
        let index = UsageIndex(projectsURL: projects.root, cacheURL: nil)
        _ = await index.refresh()

        // The file grows but can't be opened this time; what was read before still counts.
        try projects.append("-p/s.jsonl", Lines.assistant("2026-10-18T09:00:02Z", id: "msg_2") + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let blocked = StatsBuilder.build(await index.refresh(), range: .all, now: now, clock: utc)
        #expect(blocked.messages == 2)
        #expect(blocked.sessions == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let readable = StatsBuilder.build(await index.refresh(), range: .all, now: now, clock: utc)
        #expect(readable.messages == 3)
    }

    @Test func anotherBuildsIndexIsLeftAlone() async throws {
        let projects = try TempProjects()
        let folder = projects.root.deletingLastPathComponent().appendingPathComponent("cache")
        let cache = folder.appendingPathComponent("index.json")
        try projects.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:00Z")])
        let newer = #"{"version":\#(ClaudeTranscripts.cacheVersion + 1),"root":"\#(projects.root.path)","records":{"s.jsonl":{"future":true}}}"#
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(newer.utf8).write(to: cache)

        let index = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        #expect(StatsBuilder.build(await index.refresh(), range: .all, now: now, clock: utc).messages == 1)
        await index.save()
        #expect(try String(contentsOf: cache, encoding: .utf8) == newer)

        // Two unreadable indexes in a row are both set aside under timestamped names, never overwriting the earlier one.
        for bad in ["{not json", "{broken second"] {
            try Data(bad.utf8).write(to: cache)
            let fresh = UsageIndex(projectsURL: projects.root, cacheURL: cache)
            _ = await fresh.refresh()
            await fresh.save()
        }
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("index.json.unreadable-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(entries.count == 2)
        #expect(entries.allSatisfy {
            $0.lastPathComponent.range(of: #"^index\.json\.unreadable-\d{8}-\d{6}(-\d+)?$"#, options: .regularExpression) != nil
        })
        let saved = try Set(entries.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(saved == ["{not json", "{broken second"])
    }

    @Test func aReadOnlyIndexLeavesABrokenCacheAndItsBackupsAlone() async throws {
        let projects = try TempProjects()
        let folder = projects.root.deletingLastPathComponent()
        let cache = folder.appendingPathComponent("cache.json")
        let backup = cache.appendingPathExtension("unreadable")
        let transcript = try projects.write("-fixture/session.jsonl", [
            Lines.user("2026-01-01T10:00:00Z"),
            Lines.assistant("2026-01-01T10:00:01Z", id: "archived"),
        ])
        let writer = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        _ = await writer.refresh()
        try FileManager.default.removeItem(at: transcript)
        let archived = await writer.refresh()
        await writer.save()
        #expect(archived.usage.count == 1 && archived.transcriptCount == 0)

        let recovery = try Data(contentsOf: cache)
        try recovery.write(to: backup)
        let positive = await UsageIndex(projectsURL: projects.root, cacheURL: backup, readOnly: true).refresh()
        #expect(positive.usage.count == 1)

        try Data("{broken".utf8).write(to: cache)
        let data = await UsageIndex(projectsURL: projects.root, cacheURL: cache, readOnly: true).refresh()
        #expect(data.isEmpty)
        #expect(try Data(contentsOf: cache) == Data("{broken".utf8))
        #expect(try Data(contentsOf: backup) == recovery)
        let extraBackups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("cache.json.unreadable-") }
        #expect(extraBackups.isEmpty)
    }

    @Test func readOnlyIndexLeavesNoCacheFile() async throws {
        let projects = try TempProjects()
        let cache = projects.root.deletingLastPathComponent().appendingPathComponent("cache/index.json")
        try projects.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:00Z"), Lines.assistant("2026-10-18T09:00:01Z", id: "msg_1")])

        let index = UsageIndex(projectsURL: projects.root, cacheURL: cache, readOnly: true)
        let data = await index.refresh()
        #expect(StatsBuilder.build(data, range: .all, now: now, clock: utc).messages == 2)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func aTranscriptRewrittenInPlaceIsReadAgainFromTheStart() async throws {
        let projects = try TempProjects()
        let url = try projects.write("-p/s.jsonl", [Lines.user("2026-10-18T01:00:00Z", uuid: "a"), Lines.user("2026-10-18T02:00:00Z", uuid: "b")])
        let inode = try #require(TranscriptInfo.of(url.path)).inode
        let index = UsageIndex(projectsURL: projects.root, cacheURL: nil)
        _ = await index.refresh()

        // The same file, truncated and written again with other lines and more of them.
        let rewritten = [Lines.user("2026-10-18T04:00:00Z", uuid: "c"), Lines.user("2026-10-18T05:00:00Z", uuid: "d"),
                         Lines.user("2026-10-18T06:00:00Z", uuid: "e")].joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.close()
        #expect(try #require(TranscriptInfo.of(url.path)).inode == inode)

        let hours = { (data: UsageData) in data.messageBuckets.keys.map { Int($0) / 4 % 24 }.sorted() }
        #expect(hours(await index.refresh()) == [4, 5, 6])
    }

    @Test func anotherFoldersIndexStaysAndThisFolderGetsOneBesideIt() async throws {
        let first = try TempProjects(), second = try TempProjects()
        let folder = first.root.deletingLastPathComponent().appendingPathComponent("cache")
        let cache = folder.appendingPathComponent("index.json")
        try first.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:00Z"), Lines.assistant("2026-10-18T09:00:01Z", id: "msg_a")])
        try second.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:00Z"), Lines.assistant("2026-10-18T09:00:01Z", id: "msg_b"),
                                        Lines.assistant("2026-10-18T09:00:02Z", id: "msg_c")])
        let index = UsageIndex(projectsURL: first.root, cacheURL: cache)
        _ = await index.refresh()
        await index.save()
        let firstsIndex = try Data(contentsOf: cache)

        let other = UsageIndex(projectsURL: second.root, cacheURL: cache)
        #expect(await other.refresh().usage.count == 2)
        await other.save()
        #expect(try Data(contentsOf: cache) == firstsIndex)
        // Its own index is read on the next launch, even once its transcripts are gone.
        try FileManager.default.removeItem(at: second.root.appendingPathComponent("-p/s.jsonl"))
        #expect(await UsageIndex(projectsURL: second.root, cacheURL: cache).refresh().usage.count == 2)
        #expect(await UsageIndex(projectsURL: first.root, cacheURL: cache).refresh().usage.count == 1)
    }

    @Test func anIndexTooOldToUpgradeIsSetAside() async throws {
        let projects = try TempProjects()
        let folder = projects.root.deletingLastPathComponent().appendingPathComponent("cache")
        let cache = folder.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ancient = #"{"version":0,"root":"\#(projects.root.path)","records":{}}"#
        try Data(ancient.utf8).write(to: cache)
        try projects.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:00Z")])
        let index = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        _ = await index.refresh()
        await index.save()
        let asides = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("index.json.unreadable-") }
        #expect(try asides.map { try String(contentsOf: $0, encoding: .utf8) } == [ancient])
    }

    @Test func historyListedInAnotherOrderIsTheSameHistory() {
        var first = UsageData()
        first.transcriptCount = 3
        first.sessionStarts = [3, 1, 2]
        first.usage = (0..<40).map { UsageRecord(bucket: Int32($0 % 7), model: "model-\($0 % 3)", tokens: TokenCounts(input: Int64($0))) }
        var second = first
        second.sessionStarts.reverse()
        second.usage.reverse()
        #expect(first.sameHistory(as: second))

        second.usage[5].tokens.output += 1
        #expect(!first.sameHistory(as: second))
        second = first
        second.usage[0] = first.usage[1]
        #expect(!first.sameHistory(as: second))
    }
}

struct MergedStatsTests {
    let utc = DayClock(timeZone: TimeZone(identifier: "UTC")!)
    let now = Date(timeIntervalSince1970: Timestamp.parse("2026-10-18T20:00:00Z")!)

    func history(_ seed: Int) -> UsageData {
        let end = now.timeIntervalSince1970
        var data = UsageData()
        data.sessionStarts = (0..<5).map { end - Double(seed * 7 + $0) * 40_000 }
        data.messageBuckets = Dictionary(uniqueKeysWithValues: (0..<6).map { (FileRecord.bucket(end - Double(seed + $0 * 4) * 90_000), $0 + 1) })
        let models = ["claude-opus-5-5", "gpt-5.5", "mystery-\(seed)"]
        for i in 0..<12 {
            let time: Double = end - Double(seed * 3 + i) * 50_000
            let tokens = TokenCounts(input: Int64(10 * (i + seed + 1)), output: Int64(i + 1))
            let cost: Double? = i % 3 == 2 ? nil : Double(i % 4) * 0.25 + 0.25
            data.usage.append(UsageRecord(bucket: FileRecord.bucket(time), model: models[i % 3], tokens: tokens, cost: cost))
        }
        return data
    }

    @Test func providersStatsMergeToTheStatsOfTheirMergedHistory() {
        let parts = [history(1), history(2), history(3)]
        for range in StatsRange.allCases {
            let whole = StatsBuilder.build(UsageData.merged(parts), range: range, now: now, clock: utc)
            let merged = RangeStats.merged(parts.map { StatsBuilder.build($0, range: range, now: now, clock: utc) }, range: range, today: whole.today)
            #expect(merged == whole)
            #expect(merged.unpricedModels.count == 3)
        }
        let none = RangeStats.merged([], range: .all, today: 20_000)
        #expect(none == StatsBuilder.build(UsageData(), range: .all, now: Date(timeIntervalSince1970: 20_000 * 86_400 + 3600), clock: utc))
    }
}

/// Claude Code's transcripts, read only once `gate` is signaled, so a test can act while a scan is
/// part way through.
enum GatedTranscripts: TranscriptFormat {
    static let provider = Provider.claude
    static let cacheName = "gated-index.json"
    static let cacheVersion = 2
    static let upgradableCacheVersion = 1
    static let entered = DispatchSemaphore(value: 0)
    static let gate = DispatchSemaphore(value: 0)

    static func discover(in root: URL) -> [String: TranscriptInfo] { ClaudeTranscripts.discover(in: root) }

    static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        ClaudeTranscripts.ingest(line, lineOffset: lineOffset, pathHash: pathHash, into: &record)
    }

    static func read(path: String, into record: inout FileRecord) -> Bool {
        entered.signal()
        gate.wait()
        return TranscriptReader.read(path: path, into: &record, ingest: ingest)
    }
}

struct UpgradeTests {
    struct Cache: Codable {
        var version: Int
        var root: String
        var records: [String: FileRecord]
    }

    @Test func quittingMidUpgradeLeavesTheUpgradeToTheNextLaunch() async throws {
        let projects = try TempProjects()
        let cache = projects.root.deletingLastPathComponent().appendingPathComponent("cache/index.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = try projects.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:02Z"), Lines.assistant("2026-10-18T09:00:03Z", id: "msg_1")])
        // The older version's summary of the transcript, missing the usage the newer version records.
        let info = try #require(TranscriptInfo.of(url.path))
        var old = FileRecord(isSubagent: false)
        (old.size, old.modified, old.inode, old.offset) = (info.size, info.modified, info.inode, info.size)
        try JSONEncoder().encode(Cache(version: 1, root: projects.root.path, records: ["-p/s.jsonl": old])).write(to: cache)

        let index = TranscriptIndex<GatedTranscripts>(root: projects.root, cacheURL: cache)
        async let upgraded = index.refresh()
        await withCheckedContinuation { done in DispatchQueue.global().async { GatedTranscripts.entered.wait(); done.resume() } }
        // The app quits while the transcript is being read again.
        await index.save()
        #expect(try IndexFile.header(Data(contentsOf: cache))?.version == 1)
        GatedTranscripts.gate.signal()
        #expect(await upgraded.usage.count == 1)

        let relaunched = TranscriptIndex<GatedTranscripts>(root: projects.root, cacheURL: cache)
        GatedTranscripts.gate.signal()
        #expect(await relaunched.refresh().usage.count == 1)
        await relaunched.save()
        #expect(try IndexFile.header(Data(contentsOf: cache))?.version == 2)
    }
}

struct IndexFileTests {
    func sample() -> [String: FileRecord] {
        var full = FileRecord(isSubagent: true)
        (full.size, full.modified, full.inode, full.offset) = (4096, 1_792_000_000.25, 77, 4000)
        (full.missingSince, full.sessionStart, full.tail) = (1_792_100_000, 1_791_000_000.5, 0xDEAD_BEEF)
        full.model = "gpt-5.5"
        full.runningTotal = TokenCounts(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
        full.context = ["thread": "01a0", "tier": "priority"]
        full.messages = [1: 10, 2: -20, .max: .min]
        full.usage = [
            5: UsageRecord(bucket: 100, model: "gpt-5.5", tokens: TokenCounts(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)),
            6: UsageRecord(bucket: 101, model: "claude-opus-5-5", tokens: TokenCounts(input: 1), cacheWriteHour: 7, speed: .fast, cost: 0.125),
        ]
        return ["a/one.jsonl": full, "b/two.jsonl": FileRecord(isSubagent: false), "c/ünïcode.jsonl": FileRecord(isSubagent: false)]
    }

    @Test func recordsComeBackAsTheyWereSaved() throws {
        let data = Data(IndexFile.encode(version: 3, root: "/Users/me/.codex", records: sample()))
        let read = try #require(IndexFile.decode(data))
        #expect(read.header == IndexFile.Header(format: IndexFile.format, version: 3, root: "/Users/me/.codex"))
        #expect(read.records == sample())
    }

    @Test func damagedFilesAreRefusedWithoutTrapping() {
        let data = Data(IndexFile.encode(version: 3, root: "/r", records: sample()))
        for length in [0, 4, 9, 20, data.count / 2, data.count - 1] {
            #expect(IndexFile.decode(data.prefix(length)) == nil)
        }
        var huge = Data(data.prefix(IndexFile.header(data).map { 4 + 4 + 8 + 4 + $0.root.utf8.count } ?? 0))
        huge.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x7F])
        #expect(IndexFile.decode(huge) == nil)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var bytes = data
            for _ in 0..<4 { bytes[Int.random(in: 20..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator) }
            _ = IndexFile.decode(bytes)
        }
    }

    @Test func anIndexSavedAsJSONIsReadAndSavedAgainInBinary() async throws {
        let projects = try TempProjects()
        let cache = projects.root.deletingLastPathComponent().appendingPathComponent("cache/index.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try projects.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:00Z"), Lines.assistant("2026-10-18T09:00:01Z", id: "msg_1")])
        let index = UsageIndex(projectsURL: projects.root, cacheURL: nil)
        _ = await index.refresh()
        // What an earlier build saved: this transcript, and one Claude Code has since deleted.
        let reader = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        _ = await reader.refresh()
        await reader.save()
        var records = try #require(IndexFile.decode(Data(contentsOf: cache))).records
        var deleted = FileRecord(isSubagent: false)
        deleted.missingSince = 1_792_000_000
        deleted.usage = [9: UsageRecord(bucket: 1_990_000, model: "claude-opus-5-5", tokens: TokenCounts(input: 5))]
        records["-q/deleted.jsonl"] = deleted
        struct Legacy: Encodable { var version: Int; var root: String; var records: [String: FileRecord] }
        try JSONEncoder().encode(Legacy(version: ClaudeTranscripts.cacheVersion, root: projects.root.path, records: records)).write(to: cache)

        let relaunched = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        #expect(await relaunched.refresh().usage.count == 2)
        await relaunched.save()
        let saved = try Data(contentsOf: cache)
        #expect(IndexFile.isIndexFile(saved))
        #expect(IndexFile.decode(saved)?.records == records)
    }

    @Test func aLaterFormatIsLeftAlone() async throws {
        let projects = try TempProjects()
        let cache = projects.root.deletingLastPathComponent().appendingPathComponent("cache/index.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        var later = Data(IndexFile.encode(version: ClaudeTranscripts.cacheVersion, root: projects.root.path, records: [:]))
        later[4] = UInt8(IndexFile.format + 1)
        try later.write(to: cache)
        try projects.write("-p/s.jsonl", [Lines.user("2026-10-18T09:00:00Z")])
        let index = UsageIndex(projectsURL: projects.root, cacheURL: cache)
        _ = await index.refresh()
        await index.save()
        #expect(try Data(contentsOf: cache) == later)
    }
}
