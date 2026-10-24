import Foundation
import Testing
import UsageCore
@testable import UsageGraphs

/// The statistics' daily rhythm and what each event carries, sent to a list instead of PostHog.
@MainActor
@Suite(.serialized)
final class TelemetryTests {
    final class Sink: TelemetrySink {
        var events: [(name: String, properties: [String: Any])] = []
        var names: [String] { events.map(\.name) }

        func capture(_ event: String, _ properties: [String: Any]) {
            events.append((event, properties))
        }

        func last(_ name: String) -> [String: Any]? {
            events.last { $0.name == name }?.properties
        }
    }

    final class Clock {
        var now: Date
        init(_ now: String) { self.now = Clock.date(now) }
        func set(_ now: String) { self.now = Clock.date(now) }
        static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    }

    let sink = Sink()
    // One suite for every test, run one at a time and emptied around each: preferences keeps a file for
    // every suite name ever used.
    let suite = "usagegraphs-tests-telemetry"
    let defaults: UserDefaults
    var store: TelemetryStore { TelemetryStore(defaults: defaults) }
    /// Warsaw's days, so a day ends at 22:00 UTC in October.
    let calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    static let snapshot = TelemetrySnapshot(
        enabledProviders: [.claude, .codex], providersWithHistory: [.claude, .codex, .pi], providersUsedRecently: [.claude],
        providersWithLimits: [.claude], pinnedLimits: ["claude/session", "claude/weekly"], menuBarShowsTokens: true,
        menuBarShowsCost: false, menuBarShowsLeft: false, limitsInterval: 300, opensAtLogin: true, checksForUpdates: true)

    func recorder(_ clock: Clock, snapshot: @escaping @MainActor () -> TelemetrySnapshot? = { snapshot }) -> TelemetryRecorder {
        TelemetryRecorder(sink: sink, store: store, now: { clock.now }, calendar: calendar, snapshot: snapshot)
    }

    @Test func checksInOnceALocalDay() {
        let clock = Clock("2026-10-24T08:00:00Z")
        let recorder = recorder(clock)
        recorder.tick()
        clock.set("2026-10-24T21:59:00Z")
        recorder.tick()
        recorder.panelOpened()
        #expect(sink.names == ["app_daily_active"])

        clock.set("2026-10-24T22:01:00Z")
        recorder.tick()
        #expect(sink.names.filter { $0 == "app_daily_active" }.count == 2)
    }

    @Test func aRelaunchTheSameDayDoesntCheckInAgain() {
        let clock = Clock("2026-10-24T08:00:00Z")
        recorder(clock).tick()
        recorder(clock).tick()
        #expect(sink.names == ["app_daily_active"])
    }

    @Test func theCheckInWaitsForTheHistory() {
        let clock = Clock("2026-10-24T08:00:00Z")
        final class History { var loaded = false }
        let history = History()
        let recorder = recorder(clock) { history.loaded ? Self.snapshot : nil }
        recorder.tick()
        #expect(sink.events.isEmpty)
        history.loaded = true
        recorder.tick()
        #expect(sink.names == ["app_daily_active"])
    }

    @Test func theCheckInSaysWhatsInUseAndNothingAboutAccounts() throws {
        let clock = Clock("2026-10-24T08:00:00Z")
        recorder(clock).tick()
        let properties = try #require(sink.last("app_daily_active"))
        #expect(properties["install_id"] as? String == store.installID)
        #expect(properties["providers_with_history"] as? [String] == ["claude", "codex", "pi"])
        #expect(properties["providers_used_30d"] as? [String] == ["claude"])
        #expect(properties["pinned_limits"] as? [String] == ["claude/session", "claude/weekly"])
        #expect(properties["shares_statistics"] as? Bool == true)
        #expect(properties["os_version"] is String)
        #expect(Set(properties.keys) == Set(Self.snapshot.properties.keys).union(["install_id", "shares_statistics", "app_version", "app_build", "os_version", "arch"]))
    }

    @Test func sendsADaysCountsOnceItsOver() throws {
        let clock = Clock("2026-10-24T08:00:00Z")
        let recorder = recorder(clock)
        recorder.panelOpened()
        recorder.panelOpened()
        recorder.limitsRead([
            AccountLimits(id: "claude:a", provider: .claude),
            AccountLimits(id: "claude:b", provider: .claude, problem: "Login expired. Run `claude` to renew it."),
            AccountLimits(id: "codex:a", provider: .codex, problem: "ChatGPT's usage API answered HTTP 500."),
        ])
        recorder.limitsRead([AccountLimits(id: "claude:a", provider: .claude)])
        #expect(!sink.names.contains("app_usage_daily"))

        clock.set("2026-10-25T07:00:00Z")
        recorder.tick()
        let usage = try #require(sink.last("app_usage_daily"))
        #expect(usage["day"] as? String == "2026-10-24")
        #expect(usage["panel_opens"] as? Int == 2)

        let limits = sink.events.filter { $0.name == "provider_limits_daily" }.map(\.properties)
        #expect(limits.map { $0["provider"] as? String } == ["claude", "codex"])
        #expect(limits[0]["success_count"] as? Int == 2)
        #expect(limits[0]["failure_count"] as? Int == 1)
        #expect(limits[0]["login_expired_count"] as? Int == 1)
        #expect(limits[0]["expected_failure_count"] as? Int == 1)
        #expect(limits[0]["unexpected_failure_count"] as? Int == 0)
        #expect(limits[1]["http_5xx_count"] as? Int == 1)
        #expect(limits[1]["unexpected_failure_count"] as? Int == 1)

        // Sent once, and the new day starts from nothing.
        recorder.tick()
        #expect(sink.names.filter { $0 == "app_usage_daily" }.count == 1)
        #expect(store.counts == nil)
    }

    @Test func aDaysCountsSurviveARelaunch() {
        let clock = Clock("2026-10-24T08:00:00Z")
        recorder(clock).panelOpened()
        recorder(clock).panelOpened()
        clock.set("2026-10-26T08:00:00Z")
        recorder(clock).tick()
        #expect(sink.last("app_usage_daily")?["panel_opens"] as? Int == 2)
    }

    @Test func turnedOffItCountsNothingButStillChecksIn() throws {
        let clock = Clock("2026-10-24T08:00:00Z")
        store.sharesStatistics = false
        let recorder = recorder(clock)
        recorder.panelOpened()
        recorder.limitsRead([AccountLimits(id: "claude:a", provider: .claude)])
        #expect(store.counts == nil)
        clock.set("2026-10-25T08:00:00Z")
        recorder.tick()
        #expect(sink.names == ["app_daily_active", "app_daily_active"])
        #expect(sink.last("app_daily_active")?["shares_statistics"] as? Bool == false)
    }

    @Test func onlyAReleaseUsesTheBakedInKey() {
        #expect(TelemetryConfig.token(environment: [:], isRelease: true, baked: TelemetryConfig.placeholderToken) == nil)
        #expect(TelemetryConfig.token(environment: [:], isRelease: true, baked: "phc_real") == "phc_real")
        #expect(TelemetryConfig.token(environment: [:], isRelease: false, baked: "phc_real") == nil)
        #expect(TelemetryConfig.token(environment: ["SWIFTUSAGE_POSTHOG_TOKEN": " phc_test\n"], isRelease: false, baked: "phc_real") == "phc_test")
        #expect(TelemetryConfig.token(environment: ["SWIFTUSAGE_POSTHOG_TOKEN": "nonsense"], isRelease: false, baked: "phc_real") == nil)
    }

    @Test func takesTheHomeFolderOutOfCrashReports() {
        let scrubbed = TelemetryScrubber.scrub([
            "$exception_list": [["module": "/Users/someone/Applications/SwiftUsage.app/Contents/MacOS/swiftusage"]],
            "$debug_images": [["code_file": "/Users/someone/Applications/SwiftUsage.app/Contents/MacOS/swiftusage", "image_size": 10]],
            "$screen_width": 1512,
            "$os_version": "26.1",
        ], home: "/Users/someone")
        #expect(((scrubbed["$exception_list"] as? [[String: Any]])?.first?["module"] as? String) == "~/Applications/SwiftUsage.app/Contents/MacOS/swiftusage")
        #expect(((scrubbed["$debug_images"] as? [[String: Any]])?.first?["code_file"] as? String) == "~/Applications/SwiftUsage.app/Contents/MacOS/swiftusage")
        #expect(((scrubbed["$debug_images"] as? [[String: Any]])?.first?["image_size"] as? Int) == 10)
        #expect(scrubbed["$screen_width"] == nil)
        #expect(scrubbed["$os_version"] as? String == "26.1")
    }
}
