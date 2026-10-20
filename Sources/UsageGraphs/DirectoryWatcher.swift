import CoreServices
import Foundation

/// Calls `onChange` (coalesced by `latency`) with the changed paths whenever anything under `paths`
/// changes.
final class DirectoryWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "UsageGraphs.DirectoryWatcher")
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: TimeInterval = 5, onChange: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let changed = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange(Array(changed.prefix(count)))
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

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
