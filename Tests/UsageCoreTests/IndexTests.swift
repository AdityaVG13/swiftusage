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
}
