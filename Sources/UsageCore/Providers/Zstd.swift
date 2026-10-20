import Foundation
import Synchronization

/// zstd decompression through a libzstd found at run time (Homebrew or MacPorts), since macOS ships
/// none. Without one, compressed transcripts are skipped.
enum Zstd {
    private struct InBuffer {
        var source: UnsafeRawPointer?
        var size: Int
        var position: Int
    }

    private struct OutBuffer {
        var destination: UnsafeMutableRawPointer?
        var size: Int
        var position: Int
    }

    private typealias Create = @convention(c) () -> OpaquePointer?
    private typealias Free = @convention(c) (OpaquePointer?) -> Int
    private typealias Decompress = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int
    private typealias IsError = @convention(c) (Int) -> UInt32

    private struct Library: @unchecked Sendable {
        var create: Create
        var free: Free
        var decompress: Decompress
        var isError: IsError
    }

    /// The library once found. Until then it's looked for again at most once a minute, so installing
    /// zstd takes effect without relaunching the app.
    private static let loader = Mutex<(library: Library?, lastTry: TimeInterval)>((nil, -.infinity))

    private static var library: Library? {
        loader.withLock { state in
            let now = ProcessInfo.processInfo.systemUptime
            if state.library == nil, now - state.lastTry >= 60 {
                state.lastTry = now
                state.library = load()
            }
            return state.library
        }
    }

    private static func load() -> Library? {
        let candidates = ["/opt/homebrew/lib/libzstd.1.dylib", "/usr/local/lib/libzstd.1.dylib", "/opt/local/lib/libzstd.1.dylib"]
        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            guard let create = dlsym(handle, "ZSTD_createDStream"), let free = dlsym(handle, "ZSTD_freeDStream"),
                  let decompress = dlsym(handle, "ZSTD_decompressStream"), let isError = dlsym(handle, "ZSTD_isError")
            else { continue }
            return Library(create: unsafeBitCast(create, to: Create.self), free: unsafeBitCast(free, to: Free.self),
                           decompress: unsafeBitCast(decompress, to: Decompress.self), isError: unsafeBitCast(isError, to: IsError.self))
        }
        return nil
    }

    static var isAvailable: Bool { library != nil }

    /// Decompresses a file descriptor's contents on demand.
    final class Stream {
        private let fd: Int32
        private let library: Library
        private let context: OpaquePointer
        private let input: UnsafeMutableRawPointer
        private let inputCapacity = 1 << 20
        private var inBuffer = InBuffer(source: nil, size: 0, position: 0)
        private var finished = false

        init?(fd: Int32) {
            guard let library = Zstd.library, let context = library.create() else { return nil }
            self.fd = fd
            self.library = library
            self.context = context
            input = .allocate(byteCount: inputCapacity, alignment: 16)
            inBuffer.source = UnsafeRawPointer(input)
        }

        deinit {
            _ = library.free(context)
            input.deallocate()
        }

        /// Fills up to `count` bytes. Returns 0 at the end and -1 on a read or format error.
        func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
            var out = OutBuffer(destination: buffer, size: count, position: 0)
            while out.position < out.size {
                if inBuffer.position == inBuffer.size {
                    if finished { break }
                    let n = Foundation.read(fd, input, inputCapacity)
                    if n < 0 { if errno == EINTR { continue }; return -1 }
                    if n == 0 { finished = true; break }
                    inBuffer.size = n
                    inBuffer.position = 0
                }
                let result = withUnsafeMutablePointer(to: &out) { outPointer in
                    withUnsafeMutablePointer(to: &inBuffer) { inPointer in
                        library.decompress(context, UnsafeMutableRawPointer(outPointer), UnsafeMutableRawPointer(inPointer))
                    }
                }
                if library.isError(result) != 0 { return -1 }
                // A frame ended and there's no input left to start another.
                if result == 0, inBuffer.position == inBuffer.size, out.position > 0 { break }
            }
            return out.position
        }
    }
}
