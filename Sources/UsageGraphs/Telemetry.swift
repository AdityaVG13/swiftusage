import Foundation
import Observation
import PostHog
import UsageCore

/// Anonymous statistics, as OpenUsage sends them. Once a local day, a check-in: that this copy ran, its
/// versions, which providers are on and in use, and the settings chosen. Crash reports, on the launch after
/// a crash. And unless Help Improve SwiftUsage is off in Customize → General, each day's counts once the
/// day is over: how often the panel opened and how each provider's limit readings went. Nothing names an
/// account or says how much anyone used; docs/privacy.md lists every field.
@MainActor
@Observable
final class Telemetry {
    static let shared = Telemetry()

    /// Whether this copy sends anything: a release with a project key (see `TelemetryConfig`).
    let isActive: Bool

    /// The switch in Customize → General. The check-in and crash reports go out either way.
    var sharesStatistics: Bool {
        didSet {
            guard sharesStatistics != oldValue else { return }
            store.sharesStatistics = sharesStatistics
            // What was counted so far today isn't sent once it's turned off.
            if !sharesStatistics { store.counts = nil }
        }
    }

    @ObservationIgnored private let store = TelemetryStore()
    @ObservationIgnored private let token = TelemetryConfig.token()
    @ObservationIgnored private var recorder: TelemetryRecorder?

    private init() {
        isActive = token != nil
        sharesStatistics = store.sharesStatistics
    }

    /// Sets up crash reporting and the check-in, as early in the launch as the stores exist.
    func start(usage: UsageStore, limits: LimitsStore, preferences: Preferences) {
        guard let token, recorder == nil else { return }
        recorder = TelemetryRecorder(sink: PostHogSink(token: token), store: store) { [weak usage, weak limits, weak preferences] in
            guard let usage, let limits, let preferences else { return nil }
            return TelemetrySnapshot(usage: usage, limits: limits, preferences: preferences)
        }
        recorder?.tick()
        // The check-in waits for the history; it goes out once that has loaded, not at the next reading.
        withObservationTracking {
            _ = usage.hasLoaded
        } onChange: { [weak self] in
            Task { @MainActor in self?.recorder?.tick() }
        }
    }

    func panelOpened() {
        recorder?.panelOpened()
    }

    func limitsRead(_ readings: [AccountLimits]) {
        recorder?.limitsRead(readings)
    }
}

/// Where the statistics go: the SwiftUsage project in PostHog's EU cloud. A project key only lets an app send
/// events, so it ships in the app, as every analytics key does.
enum TelemetryConfig {
    static let placeholderToken = "phc_REPLACE_ME"
    /// The project's key, from PostHog's project settings.
    private static let bakedToken = "phc_nqeuTmgQS5RkALJm8v5QsLT8HgDjtC6DznF6sF53R3sX"
    static let host = "https://eu.i.posthog.com"

    /// The key to send with: `SWIFTUSAGE_POSTHOG_TOKEN`'s, for trying it out, or else the one above, which
    /// only a release uses, so running a development build adds nothing to the counts.
    static func token(environment: [String: String] = ProcessInfo.processInfo.environment,
                      isRelease: Bool = InstalledApp.current != nil, baked: String = bakedToken) -> String? {
        if let token = environment["SWIFTUSAGE_POSTHOG_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), token.hasPrefix("phc_") {
            return token
        }
        guard isRelease, baked.hasPrefix("phc_"), baked != placeholderToken else { return nil }
        return baked
    }
}

/// Where the recorder's events go: PostHog, or a list in the tests.
@MainActor
protocol TelemetrySink: AnyObject {
    func capture(_ event: String, _ properties: [String: Any])
}

/// Sends to PostHog, set up to send the recorder's events and crash reports and nothing of its own.
@MainActor
final class PostHogSink: TelemetrySink {
    init(token: String) {
        let config = PostHogConfig(projectToken: token, host: TelemetryConfig.host)
        // No profiles of people, and no location looked up from the IP address.
        config.personProfiles = .never
        config.disableGeoIp = true
        // No events the SDK would make up itself: app opened, screens, clicks, feature flags.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        // A crash is saved and sent as an `$exception` event when the app next opens. PostHog only takes
        // them with exception autocapture on in the project's Error tracking settings.
        config.errorTrackingConfig.autoCapture = true
        config.errorTrackingConfig.exceptionSteps.enabled = false
        config.setBeforeSend { event in
            event.properties = TelemetryScrubber.scrub(event.properties)
            return event
        }
        PostHogSDK.shared.setup(config)
    }

    func capture(_ event: String, _ properties: [String: Any]) {
        PostHogSDK.shared.capture(event, properties: properties)
        // A few events a day, so each goes out now rather than waiting for a batch to fill.
        PostHogSDK.shared.flush()
    }
}

/// Takes out of every event what the statistics don't need: the screen's size and the network, which the
/// SDK adds, and the home folder from crash reports' paths, which names the account when the app runs
/// from ~/Applications.
enum TelemetryScrubber {
    static let dropped: Set<String> = ["$screen_width", "$screen_height", "$network_wifi", "$network_cellular"]

    static func scrub(_ properties: [String: Any], home: String = NSHomeDirectory()) -> [String: Any] {
        properties.filter { !dropped.contains($0.key) }.mapValues { anonymized($0, home: home) }
    }

    private static func anonymized(_ value: Any, home: String) -> Any {
        switch value {
        case let string as String: string.replacingOccurrences(of: home, with: "~")
        case let array as [Any]: array.map { anonymized($0, home: home) }
        case let dictionary as [String: Any]: dictionary.mapValues { anonymized($0, home: home) }
        default: value
        }
    }
}

/// One day's counts, kept until the day is over and they're sent.
struct DailyCounts: Codable, Equatable {
    /// `2026-10-24`, the local day.
    var day: String
    var panelOpens = 0
    /// Each provider's limit readings, by its raw value.
    var limits: [String: LimitReadings] = [:]

    struct LimitReadings: Codable, Equatable {
        var succeeded = 0
        /// Failed readings by `LimitProblem`.
        var failed: [String: Int] = [:]
    }
}

/// What the statistics keep between launches, among the app's settings under `telemetry.`.
final class TelemetryStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A random ID for this copy of the app, made the first time it's needed. Nothing ties it to the Mac,
    /// the person or an account.
    var installID: String {
        if let id = defaults.string(forKey: "telemetry.installID") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "telemetry.installID")
        return id
    }

    /// The local day the last check-in went out.
    var activeDay: String? {
        get { defaults.string(forKey: "telemetry.activeDay") }
        set { defaults.set(newValue, forKey: "telemetry.activeDay") }
    }

    /// On unless turned off.
    var sharesStatistics: Bool {
        get { defaults.object(forKey: "telemetry.sharesStatistics") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "telemetry.sharesStatistics") }
    }

    var counts: DailyCounts? {
        get { defaults.data(forKey: "telemetry.counts").flatMap { try? JSONDecoder().decode(DailyCounts.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "telemetry.counts") }
    }
}

/// What the check-in says about this copy, besides its ID and versions.
struct TelemetrySnapshot {
    /// Turned on in Customize.
    var enabledProviders: [Provider]
    /// With any history on this Mac.
    var providersWithHistory: [Provider]
    /// Used on at least one of the last 30 days.
    var providersUsedRecently: [Provider]
    /// With an account whose limits were read.
    var providersWithLimits: [Provider]
    /// Each limit pinned to the menu bar as `provider/meter`, like `claude/session`, without its account.
    var pinnedLimits: [String]
    var menuBarShowsTokens: Bool
    var menuBarShowsCost: Bool
    var menuBarShowsLeft: Bool
    var limitsInterval: TimeInterval
    var opensAtLogin: Bool
    var checksForUpdates: Bool

    /// Nil until the history has loaded, which says which providers are in use.
    @MainActor
    init?(usage: UsageStore, limits: LimitsStore, preferences: Preferences, defaults: UserDefaults = .standard) {
        guard usage.hasLoaded else { return nil }
        enabledProviders = preferences.shownProviders
        providersWithHistory = Provider.allCases.filter(usage.providersWithData.contains)
        providersUsedRecently = Provider.allCases.filter { (usage.stats[$0]?[.days30]?.activeDays ?? 0) > 0 }
        providersWithLimits = Provider.allCases.filter { provider in limits.accounts.contains { $0.provider == provider && $0.hasValues } }
        var pins: [String] = []
        for (account, meter) in limits.pinned where !pins.contains(account.provider.rawValue + "/" + meter.id) {
            pins.append(account.provider.rawValue + "/" + meter.id)
        }
        pinnedLimits = pins
        menuBarShowsTokens = defaults.object(forKey: "showTokensInMenuBar") as? Bool ?? true
        menuBarShowsCost = defaults.bool(forKey: "showCostInMenuBar")
        menuBarShowsLeft = defaults.bool(forKey: "menuBarShowsLeft")
        limitsInterval = preferences.limitsInterval
        opensAtLogin = LoginItem.shared.isEnabled
        checksForUpdates = Updater.shared.checksAutomatically
    }

    init(enabledProviders: [Provider], providersWithHistory: [Provider], providersUsedRecently: [Provider], providersWithLimits: [Provider],
         pinnedLimits: [String], menuBarShowsTokens: Bool, menuBarShowsCost: Bool, menuBarShowsLeft: Bool, limitsInterval: TimeInterval,
         opensAtLogin: Bool, checksForUpdates: Bool) {
        self.enabledProviders = enabledProviders
        self.providersWithHistory = providersWithHistory
        self.providersUsedRecently = providersUsedRecently
        self.providersWithLimits = providersWithLimits
        self.pinnedLimits = pinnedLimits
        self.menuBarShowsTokens = menuBarShowsTokens
        self.menuBarShowsCost = menuBarShowsCost
        self.menuBarShowsLeft = menuBarShowsLeft
        self.limitsInterval = limitsInterval
        self.opensAtLogin = opensAtLogin
        self.checksForUpdates = checksForUpdates
    }

    var properties: [String: Any] {
        [
            "enabled_providers": enabledProviders.map(\.rawValue),
            "providers_with_history": providersWithHistory.map(\.rawValue),
            "providers_used_30d": providersUsedRecently.map(\.rawValue),
            "providers_with_limits": providersWithLimits.map(\.rawValue),
            "pinned_limits": pinnedLimits,
            "menu_bar_tokens": menuBarShowsTokens,
            "menu_bar_cost": menuBarShowsCost,
            "menu_bar_shows_left": menuBarShowsLeft,
            "limits_interval": Int(limitsInterval),
            "opens_at_login": opensAtLogin,
            "checks_for_updates": checksForUpdates,
        ]
    }
}

/// Turns what happens into the day's events: the check-in once a local day, and each finished day's counts
/// once the next begins, so they're whole and a relaunch in between doesn't split them. It's ticked when
/// the limits are read (at launch, on waking and every few minutes) and when the panel opens, so a new day
/// is noticed within minutes of starting, or of the Mac waking into it.
@MainActor
final class TelemetryRecorder {
    private let sink: TelemetrySink
    private let store: TelemetryStore
    private let snapshot: @MainActor () -> TelemetrySnapshot?
    private let now: () -> Date
    private let calendar: Calendar

    init(sink: TelemetrySink, store: TelemetryStore, now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         snapshot: @escaping @MainActor () -> TelemetrySnapshot?) {
        self.sink = sink
        self.store = store
        self.snapshot = snapshot
        self.now = now
        self.calendar = calendar
    }

    func tick() {
        let today = day(now())
        if let counts = store.counts, counts.day != today {
            store.counts = nil
            if store.sharesStatistics { send(counts) }
        }
        // The check-in waits for the history, which says which providers are in use.
        guard store.activeDay != today, let snapshot = snapshot() else { return }
        store.activeDay = today
        var properties = snapshot.properties
        properties["install_id"] = store.installID
        properties["shares_statistics"] = store.sharesStatistics
        properties.merge(Self.app) { _, app in app }
        sink.capture("app_daily_active", properties)
    }

    func panelOpened() {
        count { $0.panelOpens += 1 }
        tick()
    }

    func limitsRead(_ readings: [AccountLimits]) {
        count { counts in
            for reading in readings {
                var limits = counts.limits[reading.provider.rawValue, default: .init()]
                if let kind = reading.problemKind {
                    limits.failed[kind.rawValue, default: 0] += 1
                } else {
                    limits.succeeded += 1
                }
                counts.limits[reading.provider.rawValue] = limits
            }
        }
        tick()
    }

    private func count(_ change: (inout DailyCounts) -> Void) {
        guard store.sharesStatistics else { return }
        let today = day(now())
        var counts = store.counts ?? DailyCounts(day: today)
        if counts.day != today {
            send(counts)
            counts = DailyCounts(day: today)
        }
        change(&counts)
        store.counts = counts
    }

    private func send(_ counts: DailyCounts) {
        sink.capture("app_usage_daily", ["day": counts.day, "panel_opens": counts.panelOpens])
        for (provider, limits) in counts.limits.sorted(by: { $0.key < $1.key }) {
            var properties: [String: Any] = ["day": counts.day, "provider": provider, "success_count": limits.succeeded]
            var expected = 0
            for kind in LimitProblem.allCases {
                let failures = limits.failed[kind.rawValue] ?? 0
                properties[kind.rawValue + "_count"] = failures
                if kind.isExpected { expected += failures }
            }
            let failures = limits.failed.values.reduce(0, +)
            properties["failure_count"] = failures
            properties["expected_failure_count"] = expected
            properties["unexpected_failure_count"] = failures - expected
            sink.capture("provider_limits_daily", properties)
        }
    }

    /// `2026-10-24`, in the person's own calendar day.
    private func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// This copy's version and build, and the Mac's macOS and architecture.
    static let app: [String: Any] = {
        let info = Bundle.main.infoDictionary ?? [:]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            "app_version": info["CFBundleShortVersionString"] as? String ?? "development",
            "app_build": Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
            "os_version": "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            "arch": arch,
        ]
    }()
}
