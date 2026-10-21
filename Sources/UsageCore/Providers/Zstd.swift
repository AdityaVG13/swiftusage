import CZstd
import Foundation

/// zstd decompression, with zstd's own decoder built in.
enum Zstd {
    /// Decompresses a file descriptor's contents on demand.
    final class Stream {
        private let fd: Int32
        private let context: OpaquePointer
        private let input: UnsafeMutableRawPointer
        private let inputCapacity = 1 << 20
        private var inBuffer = ZSTD_inBuffer(src: nil, size: 0, pos: 0)
        private var finished = false
        private var lastResult = 0

        init?(fd: Int32) {
            guard let context = ZSTD_createDStream() else { return nil }
            self.fd = fd
            self.context = context
            input = .allocate(byteCount: inputCapacity, alignment: 16)
            inBuffer.src = UnsafeRawPointer(input)
        }

        deinit {
            ZSTD_freeDStream(context)
            input.deallocate()
        }

        /// Fills up to `count` bytes. Returns 0 at the end and -1 on a read or format error.
        func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
            var out = ZSTD_outBuffer(dst: buffer, size: count, pos: 0)
            while out.pos < out.size {
                if inBuffer.pos == inBuffer.size {
                    if finished { break }
                    let n = Foundation.read(fd, input, inputCapacity)
                    if n < 0 { if errno == EINTR { continue }; return -1 }
                    if n == 0 {
                        if lastResult != 0 { return -1 }
                        finished = true
                        break
                    }
                    inBuffer.size = n
                    inBuffer.pos = 0
                }
                let result = ZSTD_decompressStream(context, &out, &inBuffer)
                if ZSTD_isError(result) != 0 { return -1 }
                lastResult = result
                // A frame ended and there's no input left to start another.
                if result == 0, inBuffer.pos == inBuffer.size, out.pos > 0 { break }
            }
            return out.pos
        }
    }
}
