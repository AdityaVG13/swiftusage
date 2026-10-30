import Foundation

/// What renewing a tool's login came to.
enum Renewal: Equatable {
    case renewed(token: String, expires: Date?)
    /// The provider turned the refresh token down: only signing in again helps.
    case rejected
    /// Not this time: the provider unreachable, the lock held elsewhere, or nowhere to save it.
    case unchanged
}

/// Writing back a login a tool keeps in a file.
enum SavedLogin {
    /// Replaces a file with a copy only its owner can read, swapped in whole.
    static func replace(_ url: URL, with data: Data) -> Bool {
        let copy = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).swiftusage-\(UUID().uuidString)")
        let descriptor = open(copy.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.close()
        } catch {
            unlink(copy.path)
            return false
        }
        guard rename(copy.path, url.path) == 0 else {
            unlink(copy.path)
            return false
        }
        return true
    }

    /// Indented JSON, as the tools write their own login files.
    static func json(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// `2026-10-30T14:21:05.160Z`, as RFC 3339 dates are written in the tools' login files.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A string that isn't empty, or nil.
    static func text(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A lock as the Grok CLI takes one: an exclusive `flock` on a file that stays in place, with the holder's
/// process ID and the time it took the lock written inside. Released when its holder ends, however it ends.
struct FileLock {
    private let descriptor: Int32

    /// Waits up to `wait` while another process, or another reading here, holds it.
    static func take(_ url: URL, within wait: Duration) async -> FileLock? {
        let deadline = ContinuousClock.now + wait
        var pause = Duration.milliseconds(50)
        while true {
            let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { return nil }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                // A file that was replaced while it was being locked locks nothing; the new one is taken instead.
                var held = stat()
                var there = stat()
                if fstat(descriptor, &held) == 0, stat(url.path, &there) == 0, held.st_ino == there.st_ino, held.st_dev == there.st_dev {
                    let holder = Array("\(getpid()):\(Int(Date().timeIntervalSince1970))".utf8)
                    _ = ftruncate(descriptor, 0)
                    _ = pwrite(descriptor, holder, holder.count, 0)
                    return FileLock(descriptor: descriptor)
                }
            }
            close(descriptor)
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: pause)
            pause = min(pause * 2, .milliseconds(500))
        }
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Where the app keeps its own locks on renewing logins.
    static let renewals = Remembered<String>.inCaches("renewals")

    /// The app's own lock on renewing one login, for tools that take none across processes: two copies of
    /// the app, or the app and `swiftusage --limits`, never renew it at once.
    static func renewing(_ name: String, in folder: URL, within wait: Duration = .seconds(20)) async -> FileLock? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return await take(folder.appendingPathComponent(name.sha256Prefix + ".lock"), within: wait)
    }
}
