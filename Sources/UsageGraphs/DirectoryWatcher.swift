import CoreServices
import Foundation

/// Calls `onChange` (coalesced by `latency`) with the changed paths whenever anything under `paths`
/// changes. Changed paths read as under the watched path they're in, even when it runs through a symlink.
final class DirectoryWatcher: @unchecked Sendable {
    private let paths: [String]
    /// Each watched path and where its symlinks lead, which is where FSEvents reports changes.
    private let resolved: [(path: String, real: String)]
    private let latency: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "UsageGraphs.DirectoryWatcher")
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: TimeInterval = 5, onChange: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        resolved = paths.map { path in
            guard let real = realpath(path, nil) else { return (path, path) }
            defer { free(real) }
            return (path, String(cString: real))
        }
        self.latency = latency
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        // The stream keeps the watcher alive, so a callback under way on `queue` when `stop()` releases the
        // stream on another thread still has it.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<DirectoryWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let changed = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange(changed.prefix(count).map(watcher.watched))
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// A changed path as it reads under the watched path it's in.
    private func watched(_ path: String) -> String {
        for (given, real) in resolved where given != real && path.hasPrefix(real) {
            return given + path.dropFirst(real.count)
        }
        return path
    }

    /// Ends the stream, which lets go of the watcher.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
