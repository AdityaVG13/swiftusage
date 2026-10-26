import CryptoKit
import Foundation
import Testing
@testable import UsageGraphs

/// The updater's checks, on small apps signed ad hoc in a temporary folder and a requirement naming their
/// bundle ID. The real requirement is the installed app's own (its team) and notarization, which only a
/// release can meet, but it's checked by the same code.
struct UpdaterTests {
    private static let identifier = "dev.tasteskill.UpdaterTests"

    @Test func decodesWhatReleaseShWrites() throws {
        let json = """
            {
              "build" : 160,
              "minimumSystemVersion" : "26.0",
              "sha256" : "678c59ce49c92b83bcb6cfec10bb3a573eb4bf5b7e948995f11e34a75edf88e1",
              "size" : 2104705,
              "url" : "https:\\/\\/github.com\\/Blueemi\\/swiftusage\\/releases\\/download\\/v1.1.0\\/SwiftUsage-1.1.0.zip",
              "version" : "1.1.0"
            }
            """
        let feed = try #require(UpdateFeed.decode(Data(json.utf8)))
        #expect(feed.version == "1.1.0")
        #expect(feed.build == 160)
        #expect(feed.url.absoluteString == "https://github.com/Blueemi/swiftusage/releases/download/v1.1.0/SwiftUsage-1.1.0.zip")
        #expect(feed.runsHere)
    }

    @Test(arguments: [
        ("url", "http://github.com/x.zip"),
        ("sha256", String(repeating: "a", count: 63)),
        ("sha256", String(repeating: "g", count: 64)),
        ("size", 0),
        ("size", UpdateFeed.maxSize + 1),
        ("build", 0),
    ] as [(String, any Sendable)])
    func turnsAwayFeedsReleaseShCouldNotHaveWritten(_ key: String, _ value: any Sendable) throws {
        var fields: [String: Any] = [
            "version": "1.1.0", "build": 160, "minimumSystemVersion": "26.0", "url": "https://github.com/x.zip",
            "sha256": String(repeating: "a", count: 64), "size": 100,
        ]
        #expect(UpdateFeed.decode(try JSONSerialization.data(withJSONObject: fields)) != nil)
        fields[key] = value
        #expect(UpdateFeed.decode(try JSONSerialization.data(withJSONObject: fields)) == nil)
    }

    @Test func comparesTheMinimumSystemVersion() {
        var feed = UpdateFeed(version: "1.1.0", build: 2, minimumSystemVersion: "26", url: URL(string: "https://example.com/u.zip")!,
                              sha256: String(repeating: "a", count: 64), size: 1)
        #expect(feed.runsHere)
        feed.minimumSystemVersion = "99.0"
        #expect(!feed.runsHere)
    }

    @Test func installsANewerSignedBuildInPlace() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try Self.installed(in: folder, build: 10)
        let (zip, feed) = try Self.release(in: folder, version: "1.1.0", build: 11)

        try UpdatePackage.check(zip, for: installed, feed: feed)
        try UpdatePackage.install(zip, over: installed, feed: feed)
        #expect(try Self.build(of: installed.url) == 11)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Applications").path) == ["Test.app"])
    }

    @Test func turnsAwayADamagedDownload() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try Self.installed(in: folder, build: 10)
        let (zip, feed) = try Self.release(in: folder, version: "1.1.0", build: 11)
        let handle = try FileHandle(forWritingTo: zip)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        #expect(throws: UpdatePackage.Failure.damaged) { try UpdatePackage.install(zip, over: installed, feed: feed) }
        #expect(try Self.build(of: installed.url) == 10)
    }

    @Test func turnsAwayAnotherApp() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try Self.installed(in: folder, build: 10)
        let (zip, feed) = try Self.release(in: folder, version: "1.1.0", build: 11, identifier: "dev.tasteskill.Other")

        let error = #expect(throws: UpdatePackage.Failure.self) { try UpdatePackage.install(zip, over: installed, feed: feed) }
        #expect(error.map { if case .unsigned = $0 { true } else { false } } == true)
        #expect(try Self.build(of: installed.url) == 10)
    }

    @Test func turnsAwayAnAppChangedAfterSigning() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try Self.installed(in: folder, build: 10)
        let (zip, feed) = try Self.release(in: folder, version: "1.1.0", build: 11) { app in
            try Self.writeInfo(app, version: "1.1.0", build: 11, extra: ["Changed": true])
        }

        let error = #expect(throws: UpdatePackage.Failure.self) { try UpdatePackage.install(zip, over: installed, feed: feed) }
        #expect(error.map { if case .unsigned = $0 { true } else { false } } == true)
        #expect(try Self.build(of: installed.url) == 10)
    }

    @Test func turnsAwayABuildThatIsNotTheOneNamedOrNotNewer() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = try Self.installed(in: folder, build: 10)

        var (zip, feed) = try Self.release(in: folder, version: "1.1.0", build: 11)
        feed.build = 12
        #expect(throws: UpdatePackage.Failure.mismatched) { try UpdatePackage.check(zip, for: installed, feed: feed) }
        feed.build = 11
        feed.version = "1.2.0"
        #expect(throws: UpdatePackage.Failure.mismatched) { try UpdatePackage.check(zip, for: installed, feed: feed) }

        (zip, feed) = try Self.release(in: folder, version: "0.9.0", build: 9)
        #expect(throws: UpdatePackage.Failure.mismatched) { try UpdatePackage.install(zip, over: installed, feed: feed) }
        #expect(try Self.build(of: installed.url) == 10)
    }

    @Test func downloadsAgainSoonOnlyWhenThatMayHelp() {
        #expect(UpdatePackage.mayPass(URLError(.notConnectedToInternet)))
        #expect(UpdatePackage.mayPass(CocoaError(.fileWriteOutOfSpace)))
        #expect(UpdatePackage.mayPass(UpdatePackage.Failure.unavailable(503)))
        for failure: UpdatePackage.Failure in [.damaged, .unreadable, .unsigned(nil), .mismatched] {
            #expect(!UpdatePackage.mayPass(failure))
        }
    }

    // MARK: - Apps to update

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftusage-updater-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Applications"), withIntermediateDirectories: true)
        return folder
    }

    /// The copy being updated, at `Applications/Test.app`.
    private static func installed(in folder: URL, build: Int) throws -> InstalledApp {
        let app = folder.appending(path: "Applications/Test.app")
        try makeApp(app, version: "1.0.0", build: build, identifier: identifier)
        return InstalledApp(url: app, version: "1.0.0", build: build, requirement: "identifier \"\(identifier)\"")
    }

    /// A release's zip and the feed describing it. `tamper` changes the app after it's signed.
    private static func release(in folder: URL, version: String, build: Int, identifier: String = identifier,
                                tamper: (URL) throws -> Void = { _ in }) throws -> (URL, UpdateFeed) {
        let release = folder.appending(path: "release-\(UUID().uuidString)")
        let app = release.appending(path: "Test.app")
        try makeApp(app, version: version, build: build, identifier: identifier)
        try tamper(app)
        let zip = release.appending(path: "Test.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        let data = try Data(contentsOf: zip)
        let feed = UpdateFeed(version: version, build: build, minimumSystemVersion: "26.0", url: URL(string: "https://example.com/Test.zip")!,
                              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count)
        return (zip, feed)
    }

    /// `/usr/bin/true` in a bundle, signed ad hoc.
    private static func makeApp(_ app: URL, version: String, build: Int, identifier: String) throws {
        let executable = app.appending(path: "Contents/MacOS/Test")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
        try writeInfo(app, version: version, build: build, identifier: identifier)
        try run("/usr/bin/codesign", "--force", "--sign", "-", app.path)
    }

    private static func writeInfo(_ app: URL, version: String, build: Int, identifier: String = identifier, extra: [String: Any] = [:]) throws {
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": String(build),
        ]
        info.merge(extra) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
    }

    private static func build(of app: URL) throws -> Int? {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return (info?["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " ")) failed")
    }
}
