import Foundation
import SwiftUI
import UsageCore

@main
enum Main {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--version") {
            print("SwiftUsage \(AboutPanel.version)")
            return
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print(help, terminator: "")
            return
        }
        if let i = arguments.firstIndex(of: "--replay"), arguments.count > i + 3 {
            Replay.run(source: arguments[i + 1], work: arguments[i + 2], output: arguments[i + 3])
            return
        }
        if let i = arguments.firstIndex(of: "--price-table"), arguments.count > i + 2 {
            // Used by scripts/update-prices.sh to write BundledPrices.swift.
            guard let litellm = FileManager.default.contents(atPath: arguments[i + 1]),
                  let supplement = FileManager.default.contents(atPath: arguments[i + 2]),
                  let source = PriceSources.bundledSource(litellm: litellm, supplement: supplement)
            else {
                FileHandle.standardError.write(Data("Couldn't read the price lists\n".utf8))
                exit(1)
            }
            print(source, terminator: "")
            return
        }
        if arguments.contains("--limits") {
            Limits.run(json: arguments.contains("--json"))
            return
        }
        if arguments.contains("--dump") {
            Dump.run(cold: arguments.contains("--cold"), json: arguments.contains("--json"))
            return
        }
        UsageGraphsApp.main()
    }

    static let help = """
        SwiftUsage \(AboutPanel.version): coding agent usage, limits and costs, in your menu bar.

        With no options it runs the menu bar app. In a terminal:

          swiftusage --limits [--provider <id>] [--json]   every signed-in account's plan limits
          swiftusage --dump [--provider <id>] [--cold]     the numbers the panel shows, per provider
          swiftusage --version                             the version

        Providers: \(Provider.allCases.map(\.rawValue).joined(separator: ", "))

        """
}

/// `swiftusage --dump [--provider <id>] [--cold]` prints the numbers the panel would show, for checking
/// against other tools. `--json` writes Claude Code's per-day report for `scripts/verify.sh`.
enum Dump {
    static func run(cold: Bool, json: Bool) {
        let arguments = CommandLine.arguments
        let only = arguments.firstIndex(of: "--provider").flatMap { arguments.indices.contains($0 + 1) ? Provider(rawValue: arguments[$0 + 1]) : nil }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if json {
                let data = await UsageIndex(cacheURL: cold ? nil : UsageIndex.defaultCacheURL, readOnly: true).refresh()
                FileHandle.standardOutput.write(jsonReport(data))
                print()
                done.signal()
                return
            }
            let prices = await PriceUpdates.shared.current()
            for source in UsageSources.all(cached: !cold, readOnly: true) where only == nil || source.provider == only {
                let started = Date()
                let data = await source.refresh(progress: nil)
                let elapsed = Date().timeIntervalSince(started)
                print("== \(source.provider.name)  transcripts: \(data.transcriptCount)  scan: \(String(format: "%.2f", elapsed))s  responses: \(data.usage.count)")
                for range in StatsRange.allCases {
                    let s = StatsBuilder.build(data, range: range, prices: prices)
                    print("  [\(range.rawValue)] sessions \(Format.grouped(s.sessions))  messages \(Format.grouped(s.messages))  tokens \(Format.compact(s.totalTokens)) (\(s.totalTokens))  cost \(Format.dollars(s.cost))  active days \(s.activeDays)  peak hour \(s.peakHour.map(Format.hour) ?? "–")  favorite \(s.favoriteModel?.name ?? "–")")
                    if !s.unpricedModels.isEmpty {
                        let ids = StatsBuilder.build(data, range: range, groupingModels: false, prices: prices).unpricedModels
                        print("      unpriced: \(ids.joined(separator: ", "))")
                    }
                    guard range == .all else { continue }
                    for model in s.models.prefix(6) {
                        let t = model.tokens
                        print("      \(model.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(String(format: "%5.1f%%", model.share * 100))  \(model.cost.map(Format.dollars) ?? "unpriced")  in \(t.input)  out \(t.output)  cache read \(t.cacheRead)  cache write \(t.cacheWrite)")
                    }
                }
                let week = StatsBuilder.build(data, range: .days7, prices: prices)
                print("  spend: today \(Format.dollars(week.days[week.today]?.cost ?? 0))  yesterday \(Format.dollars(week.days[week.today - 1]?.cost ?? 0))")
            }
            done.signal()
        }
        done.wait()
    }

    /// Per local day: sessions, messages and each model's four token counts, plus the panel's
    /// summary for every range. Used to diff against independent implementations.
    static func jsonReport(_ data: UsageData) -> Data {
        let clock = DayClock()
        func dayString(_ day: Int) -> String {
            let (y, m, d) = DayClock.civil(fromDays: day)
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        var days: [String: [String: Any]] = [:]
        func bump(_ day: Int, _ field: String, _ by: Int) {
            days[dayString(day), default: [:]][field] = ((days[dayString(day)]?[field] as? Int) ?? 0) + by
        }
        for start in data.sessionStarts { bump(clock.day(of: start), "sessions", 1) }
        for (bucket, count) in data.messageBuckets { bump(clock.day(of: Double(bucket) * 900), "messages", count) }
        var tokens: [String: [String: [Int64]]] = [:]
        for record in data.usage where record.model != "<synthetic>" && record.tokens.total > 0 {
            let day = dayString(clock.day(of: Double(record.bucket) * 900))
            var t = tokens[day, default: [:]][record.model, default: [0, 0, 0, 0]]
            t[0] += record.tokens.input; t[1] += record.tokens.output; t[2] += record.tokens.cacheRead; t[3] += record.tokens.cacheWrite
            tokens[day, default: [:]][record.model] = t
        }
        for (day, models) in tokens { days[day, default: [:]]["tokens"] = models.mapValues { $0.map { NSNumber(value: $0) } } }
        var hours = [Int](repeating: 0, count: 24)
        for start in data.sessionStarts { hours[clock.hour(of: start)] += 1 }
        var ranges: [String: Any] = [:]
        for range in StatsRange.allCases {
            let s = StatsBuilder.build(data, range: range, groupingModels: false)
            ranges[range.rawValue] = [
                "sessions": s.sessions, "messages": s.messages, "totalTokens": NSNumber(value: s.totalTokens),
                "activeDays": s.activeDays, "peakHour": s.peakHour as Any? ?? NSNull(), "favoriteModel": s.favoriteModel?.id as Any? ?? NSNull(),
            ]
        }
        // What the panel itself reads, to check StatsBuilder's per-day totals against the raw data.
        let all = StatsBuilder.build(data, range: .all, groupingModels: false)
        let statsDays = Dictionary(uniqueKeysWithValues: all.days.map { day, s in
            (dayString(day), ["sessions": s.sessions, "messages": s.messages, "tokens": NSNumber(value: s.tokens)] as [String: Any])
        })
        let object: [String: Any] = ["days": days, "hours": hours, "ranges": ranges, "statsDays": statsDays]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }
}

/// `swiftusage --limits [--provider <id>] [--json]` prints every signed-in account's plan limits, for
/// scripts and agents.
enum Limits {
    static func run(json: Bool) {
        let arguments = CommandLine.arguments
        let only = arguments.firstIndex(of: "--provider").flatMap { arguments.indices.contains($0 + 1) ? Provider(rawValue: arguments[$0 + 1]) : nil }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let accounts = await LimitsSources.fetch(LimitsSources.all().filter { only == nil || $0.provider == only })
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                FileHandle.standardOutput.write(try! encoder.encode(accounts))
                print()
            } else {
                for account in accounts {
                    print("== \([account.provider.name, account.account, account.plan].compactMap { $0 }.joined(separator: " · "))")
                    if let problem = account.problem { print("   ! \(problem)") }
                    if !account.sharedWith.isEmpty { print("   also used by \(account.sharedWith.map(\.name).joined(separator: ", "))") }
                    for meter in account.meters {
                        let pace = Pace(meter)
                        let used = switch meter.unit {
                        case .percent: String(format: "%.0f%%", meter.used)
                        case .dollars: "\(Format.dollars(meter.used)) of \(Format.dollars(meter.limit))"
                        case .count: "\(Format.grouped(Int(meter.used))) of \(Format.grouped(Int(meter.limit)))"
                        }
                        let reset = meter.resetsAt.map { "resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "not started"
                        let projection = pace.atReset.map { String(format: "  ~%.0f%% at reset", $0 * 100) } ?? ""
                        print("   \(meter.label.padding(toLength: 16, withPad: " ", startingAt: 0)) \(used.padding(toLength: 16, withPad: " ", startingAt: 0)) \(reset)  [\(pace.verdict)]\(projection)")
                    }
                    for note in account.notes { print("   \(note.label): \(note.value)") }
                    if let resets = account.resets {
                        let expiry = resets.nextExpiry.map { ", next expires " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
                        print("   Limit resets: \(resets.available) available\(expiry)")
                    }
                }
            }
            done.signal()
        }
        done.wait()
    }
}

/// `swiftusage --replay <projects> <work dir> <output prefix>` rebuilds every transcript under
/// `<projects>` inside `<work dir>` in random chunks that split lines, refreshing the index after each
/// round and reloading it from disk halfway, then writes the incremental and the one-pass results.
enum Replay {
    static func run(source: String, work: String, output: String) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let fm = FileManager.default
            let workURL = URL(fileURLWithPath: work)
            try? fm.removeItem(at: workURL)
            let projects = workURL.appendingPathComponent("projects")
            let cache = workURL.appendingPathComponent("index.json")
            let files = UsageIndex.discoverTranscripts(in: URL(fileURLWithPath: source))
            let environment = ProcessInfo.processInfo.environment
            let rounds = environment["REPLAY_ROUNDS"].flatMap(Int.init) ?? 7
            var generator = SplitMix(seed: environment["REPLAY_SEED"].flatMap(UInt64.init) ?? 0x5EED_2026)
            var cuts: [String: [UInt64]] = [:]
            for (relative, info) in files {
                let inner = (0..<(rounds - 1)).map { _ in info.size == 0 ? 0 : generator.next() % info.size }
                cuts[relative] = [0] + inner.sorted() + [info.size]
            }
            var index = UsageIndex(projectsURL: projects, cacheURL: cache)
            var refreshes = 0
            for round in 0..<rounds {
                for (relative, info) in files {
                    let range = cuts[relative]![round]..<cuts[relative]![round + 1]
                    let target = projects.appendingPathComponent(relative)
                    try! fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: target.path) { fm.createFile(atPath: target.path, contents: nil) }
                    guard !range.isEmpty else { continue }
                    let reader = try! FileHandle(forReadingFrom: URL(fileURLWithPath: info.path))
                    try! reader.seek(toOffset: range.lowerBound)
                    let bytes = try! reader.read(upToCount: Int(range.count)) ?? Data()
                    try! reader.close()
                    let writer = try! FileHandle(forWritingTo: target)
                    try! writer.seekToEnd()
                    try! writer.write(contentsOf: bytes)
                    try! writer.close()
                }
                _ = await index.refresh()
                refreshes += 1
                if round == rounds / 2 {
                    await index.save()
                    index = UsageIndex(projectsURL: projects, cacheURL: cache)
                }
            }
            let incremental = await index.refresh()
            let onePass = await UsageIndex(projectsURL: projects, cacheURL: nil).refresh()
            try! Dump.jsonReport(incremental).write(to: URL(fileURLWithPath: output + "-incremental.json"))
            try! Dump.jsonReport(onePass).write(to: URL(fileURLWithPath: output + "-onepass.json"))
            print("replayed \(files.count) transcripts in \(rounds) rounds (\(refreshes) refreshes, index reloaded from disk after round \(rounds / 2 + 1))")
            done.signal()
        }
        done.wait()
    }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
