import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// The latest release, as its `feed.json` describes it. scripts/release.sh writes the feed and each GitHub
/// release carries a copy, so the latest one's is always at `<releases>/latest/download/feed.json`.
struct UpdateFeed: Codable, Equatable, Sendable {
    var version: String
    /// The release's `CFBundleVersion`, which counts commits, so a later release always has a higher one.
    var build: Int
    var minimumSystemVersion: String
    /// The release's zip, holding the app.
    var url: URL
    var sha256: String
    var size: Int

    /// Far more than a release weighs (about 2 MB), and far less than would fill a disk.
    static let maxSize = 200_000_000

    /// Turns away a feed that can't be one release.sh wrote: a zip not served over HTTPS, a malformed hash,
    /// an impossible size.
    static func decode(_ data: Data) -> UpdateFeed? {
        guard let feed = try? JSONDecoder().decode(UpdateFeed.self, from: data),
              feed.url.scheme?.lowercased() == "https",
              feed.sha256.count == 64, feed.sha256.allSatisfy(\.isHexDigit),
              feed.build > 0, (1...maxSize).contains(feed.size)
        else { return nil }
        return feed
    }

    /// Whether this Mac's macOS is new enough for it.
    var runsHere: Bool {
        let parts = minimumSystemVersion.split(separator: ".").map { Int($0) ?? 0 }
        func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: part(0), minorVersion: part(1), patchVersion: part(2)))
    }
}

/// This copy of the app, and what an update to it has to be.
struct InstalledApp: Sendable {
    var url: URL
    var version: String
    var build: Int
    /// What the app in an update must satisfy, in the code requirement language.
    var requirement: String

    /// The Developer ID team that signs SwiftUsage's releases.
    static let releaseTeam = "28726K5AS9"

    /// The running app, if it can update itself: a release, signed with SwiftUsage's Developer ID. An update
    /// then has to meet its designated requirement (the same bundle ID, signed by the same team) and be
    /// notarized. A development build is signed ad hoc, and a release could never replace a build someone
    /// signed with their own Developer ID, so neither updates, and neither sends statistics (`TelemetryConfig`).
    static let current: InstalledApp? = {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
        else { return nil }
        var code: SecStaticCode?
        var info: CFDictionary?
        var designated: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String == releaseTeam,
              SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess, let designated,
              SecRequirementCopyString(designated, [], &text) == errSecSuccess, let text
        else { return nil }
        return InstalledApp(url: bundle.bundleURL, version: version, build: build, requirement: "(\(text as String)) and notarized")
    }()

    /// Why this copy can't replace itself, if it can't: it was opened from the disk image or straight from
    /// Downloads, which macOS runs from a read-only copy, or it's in a folder this account can't change.
    var installProblem: String? {
        let folder = url.deletingLastPathComponent()
        if url.path.contains("/AppTranslocation/") || (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "This copy of SwiftUsage was opened from the disk image or from Downloads, so it can't update itself. Download the new version and drag it to Applications."
        }
        if !FileManager.default.isWritableFile(atPath: folder.path) || !FileManager.default.isWritableFile(atPath: url.path) {
            return "SwiftUsage can't replace itself in \(FileManager.default.displayName(atPath: folder.path)), which your account can't change. Download the new version and put it there."
        }
        return nil
    }
}

/// Checking and installing a downloaded release. Nothing here trusts the feed alone: the app in the zip has
/// to meet the installed app's requirement and be the build the feed names, newer than the installed one.
enum UpdatePackage {
    enum Failure: LocalizedError, Equatable {
        /// GitHub answered the download with this HTTP status instead of the zip.
        case unavailable(Int)
        case damaged
        case unreadable
        case unsigned(String?)
        case mismatched

        var errorDescription: String? {
            switch self {
            case .unavailable(let status): "GitHub didn't send the download (HTTP \(status))."
            case .damaged: "The download doesn't match the release it's for."
            case .unreadable: "The download isn't a zip of the app."
            case .unsigned(let reason): "The app in the download isn't signed and notarized as SwiftUsage is" + (reason.map { " (\($0))." } ?? ".")
            case .mismatched: "The app in the download isn't the version the release names."
            }
        }
    }

    /// Whether downloading again soon may go differently: after the network, the disk or GitHub failed, it
    /// may. A download that isn't an installable update stays one until the next release, so it waits for the
    /// next day's check rather than being downloaded again every hour.
    static func mayPass(_ error: Error) -> Bool {
        guard let failure = error as? Failure else { return true }
        if case .unavailable = failure { return true }
        return false
    }

    /// Whether the zip is the one the feed describes, byte for byte.
    static func checkDownload(_ zip: URL, against feed: UpdateFeed) throws {
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe), data.count == feed.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == feed.sha256.lowercased()
        else { throw Failure.damaged }
    }

    /// Unpacks the zip into an empty folder and returns the app in it.
    static func unpack(_ zip: URL, into folder: URL) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        do { try ditto.run() } catch { throw Failure.unreadable }
        ditto.waitUntilExit()
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard ditto.terminationStatus == 0, items.count == 1, let app = items.first, app.pathExtension == "app" else { throw Failure.unreadable }
        return app
    }

    /// Checks the app's signature, every architecture and every file it seals, against `app`'s requirement,
    /// then that it's the build `feed` names and newer than `app`. The version and build are read from the
    /// Info.plist the signature covers.
    static func verify(_ update: URL, for app: InstalledApp, feed: UpdateFeed) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(update as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(app.requirement as CFString, [], &requirement) == errSecSuccess, let requirement
        else { throw Failure.unsigned(nil) }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error) == errSecSuccess else {
            throw Failure.unsigned(error.map { "\(CFErrorGetCode($0.takeRetainedValue()))" })
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let plist = (info as? [String: Any])?[kSecCodeInfoPList as String] as? [String: Any],
              plist["CFBundleShortVersionString"] as? String == feed.version,
              let build = (plist["CFBundleVersion"] as? String).flatMap(Int.init), build == feed.build, build > app.build
        else { throw Failure.mismatched }
    }

    /// Checks a downloaded zip all the way through without installing it, so only an update that will
    /// install is offered.
    static func check(_ zip: URL, for app: InstalledApp, feed: UpdateFeed) throws {
        try checkDownload(zip, against: feed)
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftusage-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try verify(unpack(zip, into: folder), for: app, feed: feed)
    }

    /// Puts the release in place of `app`. It's unpacked beside the app, on the same volume, and checked
    /// there, so what's checked is exactly what's installed, and the old app is swapped for it in one step:
    /// if anything fails, the old app is left as it was.
    static func install(_ zip: URL, over app: InstalledApp, feed: UpdateFeed) throws {
        try checkDownload(zip, against: feed)
        let fileManager = FileManager.default
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app.url, create: true)
        defer { try? fileManager.removeItem(at: staging) }
        let update = try unpack(zip, into: staging)
        try verify(update, for: app, feed: feed)
        _ = try fileManager.replaceItemAt(app.url, withItemAt: update)
    }
}

/// Keeps SwiftUsage up to date. Once a day it reads the latest release's feed; a newer build is downloaded
/// in the background, checked, and offered in the update window: Install and Relaunch, Remind Me Later or
/// Skip This Version. A development build doesn't update (see `InstalledApp.current`).
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        /// Only shown for Check for Updates…; a daily check is silent until it has something to offer.
        case checking
        case downloading(UpdateFeed)
        case upToDate
        /// Downloaded and checked, waiting for the person to choose.
        case ready(UpdateFeed)
        /// Newer, but this copy can't replace itself where it is, so the window offers the download.
        case manual(UpdateFeed, problem: String)
        case installing(UpdateFeed)
        case failed(title: String, message: String)
    }

    private(set) var phase: Phase = .idle
    let app = InstalledApp.current
    var canUpdate: Bool { app != nil && releases != nil }

    var isInstalling: Bool {
        if case .installing = phase { true } else { false }
    }

    /// The switch in Customize → General.
    var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: "checksForUpdates")
            if checksAutomatically { Task { await tick() } }
        }
    }

    /// The release on offer, if there is one.
    var offered: UpdateFeed? { Self.feed(of: phase) }

    private static let checkInterval: TimeInterval = 86_400
    /// How long Remind Me Later holds the window back.
    private static let remindInterval: TimeInterval = 86_400

    private let releases = (Bundle.main.object(forInfoDictionaryKey: "SwiftUsageReleases") as? String).flatMap(URL.init(string:))
    /// A downloaded release waits here between runs, so Remind Me Later doesn't download it again.
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "dev.tasteskill.UsageGraphs/Update")
    private var zip: URL { folder.appending(path: "SwiftUsage.zip") }
    private var savedFeed: URL { folder.appending(path: "feed.json") }

    private var loop: Task<Void, Never>?
    private var checking: Task<Void, Never>?
    /// Check for Updates… was chosen, so the window follows the check under way, and reports when there's
    /// nothing new or the check fails.
    private var someoneWaiting = false

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["User-Agent": "swiftusage/\(InstalledApp.current?.version ?? "dev")"]
        return URLSession(configuration: configuration)
    }()

    private init() {
        checksAutomatically = UserDefaults.standard.object(forKey: "checksForUpdates") as? Bool ?? true
    }

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// The build Skip This Version passed over; that one and any older aren't offered again.
    private var skippedBuild: Int {
        get { UserDefaults.standard.integer(forKey: "skippedUpdateBuild") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedUpdateBuild") }
    }

    /// Until when Remind Me Later holds the window back.
    private var remindAfter: Date? {
        get { UserDefaults.standard.object(forKey: "updateRemindAfter") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateRemindAfter") }
    }

    /// Picks up a release downloaded in an earlier run, then checks once a day, starting a little after
    /// launch so the first read of the history has the Mac to itself.
    func start() {
        guard canUpdate, loop == nil else { return }
        restore()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self?.tick()
                // A continuous clock, so a Mac waking from sleep catches up at once.
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Shows the window again once Remind Me Later's day is up, and checks when the last check is a day old.
    private func tick() async {
        switch phase {
        case .ready, .manual:
            if remindAfter.map({ $0 <= Date() }) ?? true { UpdateWindow.shared.show(activating: false) }
        default:
            break
        }
        guard checksAutomatically, lastCheck.map({ Date().timeIntervalSince($0) >= Self.checkInterval }) ?? true else { return }
        await runCheck()
    }

    /// Check for Updates… in the ⋯ menu: looks right away, whatever was skipped or put off, and shows how
    /// it goes. With a release already on offer, it shows that.
    func checkNow() {
        guard canUpdate else { return }
        if offered != nil {
            UpdateWindow.shared.show(activating: true)
            return
        }
        someoneWaiting = true
        remindAfter = nil
        phase = .checking
        UpdateWindow.shared.show(activating: true)
        Task { await runCheck() }
    }

    /// One check at a time; a second caller waits for the one under way.
    private func runCheck() async {
        if let checking {
            await checking.value
            return
        }
        let task = Task { await check() }
        checking = task
        await task.value
        checking = nil
        someoneWaiting = false
    }

    private func check() async {
        guard let app, let releases else { return }
        let feedURL = releases.appending(path: "latest/download/feed.json")
        let answer = try? await Self.session.data(for: URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        guard !Task.isCancelled else { return }
        guard let (data, response) = answer, let status = (response as? HTTPURLResponse)?.statusCode else {
            report(.failed(title: "Couldn't check for updates", message: "GitHub didn't answer. Check your connection and try again."))
            return
        }
        lastCheck = Date()
        guard status == 200, let feed = UpdateFeed.decode(data) else {
            report(.failed(title: "Couldn't check for updates",
                           message: status == 404 ? "No release of SwiftUsage was found on GitHub." : "GitHub's answer wasn't a release SwiftUsage can read (HTTP \(status))."))
            return
        }
        guard feed.build > app.build else {
            report(.upToDate)
            return
        }
        guard someoneWaiting || feed.build > skippedBuild else { return }
        guard feed.runsHere else {
            report(.failed(title: "SwiftUsage \(feed.version) needs a newer macOS", message: "It runs on macOS \(feed.minimumSystemVersion) or later."))
            return
        }
        if let problem = app.installProblem {
            offer(.manual(feed, problem: problem))
            return
        }
        if case .ready(let ready) = phase, ready == feed {
            offer(.ready(feed))
            return
        }

        report(.downloading(feed))
        do {
            let (download, response) = try await Self.session.download(for: URLRequest(url: feed.url, timeoutInterval: 60))
            defer { try? FileManager.default.removeItem(at: download) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdatePackage.Failure.unavailable(status) }
            try await Task.detached { try UpdatePackage.check(download, for: app, feed: feed) }.value
            try Task.checkCancellation()
            // An older release on offer may have started installing meanwhile, from the zip about to be replaced.
            guard !isInstalling else { return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: zip)
            try FileManager.default.moveItem(at: download, to: zip)
            try JSONEncoder().encode(feed).write(to: savedFeed, options: .atomic)
            offer(.ready(feed))
        } catch {
            // Tried again within the hour, or at the next day's check when that won't help.
            if UpdatePackage.mayPass(error) { lastCheck = nil }
            guard !Task.isCancelled else { return }
            NSLog("swiftusage: update \(feed.version) not downloaded: \(error)")
            report(.failed(title: "Couldn't download SwiftUsage \(feed.version)", message: error.localizedDescription))
        }
    }

    /// What only Check for Updates… shows: progress, nothing new, failures.
    private func report(_ phase: Phase) {
        if someoneWaiting { self.phase = phase }
    }

    /// A release to offer. The window opens unless Remind Me Later is holding this release back.
    private func offer(_ new: Phase) {
        if offered != nil, offered?.build != Self.feed(of: new)?.build { remindAfter = nil }
        phase = new
        if someoneWaiting || remindAfter.map({ $0 <= Date() }) ?? true {
            UpdateWindow.shared.show(activating: someoneWaiting)
        }
    }

    private static func feed(of phase: Phase) -> UpdateFeed? {
        switch phase {
        case .ready(let feed), .manual(let feed, _), .installing(let feed): feed
        default: nil
        }
    }

    /// A release downloaded in an earlier run, offered again, unless it's been installed or skipped since.
    private func restore() {
        guard let app, let data = try? Data(contentsOf: savedFeed), let feed = try? JSONDecoder().decode(UpdateFeed.self, from: data),
              feed.build > app.build, feed.build > skippedBuild, FileManager.default.fileExists(atPath: zip.path)
        else {
            try? FileManager.default.removeItem(at: folder)
            remindAfter = nil
            return
        }
        phase = .ready(feed)
    }

    // MARK: - The window's buttons

    func install() {
        guard case .ready(let feed) = phase, let app else { return }
        phase = .installing(feed)
        let zip = zip
        Task {
            do {
                try await Task.detached { try UpdatePackage.install(zip, over: app, feed: feed) }.value
            } catch {
                NSLog("swiftusage: update \(feed.version) not installed: \(error)")
                // Downloaded again at the next check.
                try? FileManager.default.removeItem(at: folder)
                lastCheck = nil
                phase = .failed(title: "Couldn't install SwiftUsage \(feed.version)", message: error.localizedDescription)
                return
            }
            try? FileManager.default.removeItem(at: folder)
            LSRegisterURL(app.url as CFURL, true)
            // The new copy takes over from this one as it opens (see `UsageGraphsApp.takeOverFromOtherCopies`),
            // which quits it as Quit does, saving the indexes on the way out.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
                NSApp.terminate(nil)
            } catch {
                NSLog("swiftusage: update \(feed.version) installed but didn't open: \(error)")
                phase = .failed(title: "SwiftUsage \(feed.version) is installed", message: "It didn't open by itself. Quit this copy and open SwiftUsage from \(FileManager.default.displayName(atPath: app.url.deletingLastPathComponent().path)).")
            }
        }
    }

    /// The release page, for a copy that can't replace itself.
    func download() {
        guard case .manual(let feed, _) = phase, let releases else { return }
        NSWorkspace.shared.open(releases.appending(path: "tag/v\(feed.version)"))
        remindLater()
    }

    func remindLater() {
        remindAfter = Date().addingTimeInterval(Self.remindInterval)
        UpdateWindow.shared.hide()
    }

    func skip() {
        guard let feed = offered else { return }
        skippedBuild = feed.build
        remindAfter = nil
        try? FileManager.default.removeItem(at: folder)
        phase = .idle
        UpdateWindow.shared.hide()
    }

    /// OK, Cancel, or the window's close button. Closing a release on offer puts it off like Remind Me Later.
    func dismiss() {
        switch phase {
        case .ready, .manual:
            remindLater()
        case .installing:
            break
        case .checking, .downloading:
            checking?.cancel()
            fallthrough
        default:
            someoneWaiting = false
            phase = .idle
            restore()
            UpdateWindow.shared.hide()
        }
    }
}
