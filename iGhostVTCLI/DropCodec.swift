import CryptoKit
import CZstd
import Darwin
import Foundation

/// What the drop zone stores: a file compressed as one zstd frame, written
/// by `DropEncoder` and read back by `DropDecoder`. The relay never looks
/// inside; it holds and hands out exactly these bytes.
///
/// One thread and a fixed level make the stream a function of the file, so
/// an upload cut off is resumed by compressing again from the start and
/// sending only what the relay does not have.
enum DropCodec {
    static let encoding = "zstd"
    static let level: Int32 = 3
    static let readByteCount = 1 << 20

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func zstdError(_ code: Int) -> String {
        String(cString: ZSTD_getErrorName(code))
    }
}

/// Reads a file, compresses it, and hands the compressed stream on in
/// chunks the relay takes, from another thread so reading and compressing
/// overlap the network. The SHA-256 of what was read comes with the end.
final class DropEncoder {
    enum Piece {
        /// Compressed bytes, and how much of the file they cover.
        case chunk(Data, consumed: Int64)
        case end(sha256: String)
        case failure(String)
    }

    private let condition = NSCondition()
    private var pieces: [Piece] = []
    private var isCancelled = false
    private let finished = DispatchSemaphore(value: 0)
    private let maximumQueued = 4

    /// Starts on `fd` (read from where it stands), which has `size` bytes.
    init(fd: Int32, size: Int64, chunkByteCount: Int) {
        let thread = Thread { [self] in
            run(fd: fd, size: size, chunkByteCount: chunkByteCount)
            finished.signal()
        }
        thread.name = "drop.encode"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The next piece, waiting for it; never past `.end` or `.failure`.
    func next() -> Piece {
        condition.lock()
        defer { condition.unlock() }
        while pieces.isEmpty {
            condition.wait()
        }
        let piece = pieces.removeFirst()
        condition.broadcast()
        return piece
    }

    /// Stops the thread and waits for it, so the file it reads can be
    /// closed after.
    func stop() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
        finished.wait()
    }

    /// False once cancelled.
    private func put(_ piece: Piece) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while pieces.count >= maximumQueued, !isCancelled {
            condition.wait()
        }
        guard !isCancelled else { return false }
        pieces.append(piece)
        condition.broadcast()
        return true
    }

    private func run(fd: Int32, size: Int64, chunkByteCount: Int) {
        guard let context = ZSTD_createCCtx() else {
            _ = put(.failure("Unable to start compressing."))
            return
        }
        defer { ZSTD_freeCCtx(context) }
        ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, DropCodec.level)
        ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, 1)
        // The size is in the frame header, and a file that grows or shrinks
        // while it is read fails the frame instead of going up changed.
        ZSTD_CCtx_setPledgedSrcSize(context, UInt64(size))

        var hasher = SHA256()
        var input = [UInt8](repeating: 0, count: DropCodec.readByteCount)
        var output = [UInt8](repeating: 0, count: max(ZSTD_CStreamOutSize(), 128 * 1024))
        var pending = Data()
        pending.reserveCapacity(chunkByteCount)
        var consumed: Int64 = 0
        var isLast = false

        while !isLast {
            let count = input.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                _ = put(.failure("Unable to read the file: \(String(cString: strerror(errno)))."))
                return
            }
            consumed += Int64(count)
            isLast = count == 0
            input.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }

            var failure: String?
            input.withUnsafeBytes { inputBytes in
                var source = ZSTD_inBuffer(src: inputBytes.baseAddress, size: count, pos: 0)
                let directive = isLast ? ZSTD_e_end : ZSTD_e_continue
                var finished = false
                while !finished, failure == nil {
                    output.withUnsafeMutableBytes { outputBytes in
                        var sink = ZSTD_outBuffer(dst: outputBytes.baseAddress, size: outputBytes.count, pos: 0)
                        let remaining = ZSTD_compressStream2(context, &sink, &source, directive)
                        if ZSTD_isError(remaining) != 0 {
                            failure = DropCodec.zstdError(remaining)
                            return
                        }
                        pending.append(outputBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: sink.pos)
                        finished = isLast ? remaining == 0 : source.pos == source.size
                    }
                    while pending.count >= chunkByteCount, failure == nil {
                        let chunk = pending.prefix(chunkByteCount)
                        pending.removeFirst(chunkByteCount)
                        if !put(.chunk(Data(chunk), consumed: consumed)) {
                            failure = ""
                        }
                    }
                }
            }
            if let failure {
                if !failure.isEmpty {
                    _ = put(.failure(failure.contains("Src size") ? "The file changed while it was being sent." : "Unable to compress the file: \(failure)."))
                }
                return
            }
        }
        if !pending.isEmpty, !put(.chunk(pending, consumed: consumed)) {
            return
        }
        _ = put(.end(sha256: DropCodec.hex(hasher.finalize())))
    }
}

/// Decodes a downloaded stream into a file, checking it against what the
/// uploader declared: never more than `size` bytes, and the SHA-256 it
/// committed.
enum DropDecoder {
    static func decode(from input: Int32, to output: Int32, entry: DropEntry) throws {
        var hasher = SHA256()
        var written: Int64 = 0
        func emit(_ bytes: UnsafeRawBufferPointer) throws {
            written += Int64(bytes.count)
            guard written <= entry.size else {
                throw DropDamage(message: "\(entry.id) is larger than its manifest says; it was not saved.")
            }
            hasher.update(bufferPointer: bytes)
            var done = 0
            while done < bytes.count {
                let n = Darwin.write(output, bytes.baseAddress! + done, bytes.count - done)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw CLIError.dropFailed("Unable to write the file: \(String(cString: strerror(errno))).") }
                done += n
            }
        }

        var buffer = [UInt8](repeating: 0, count: DropCodec.readByteCount)
        switch entry.encoding {
        case "none":
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw CLIError.dropFailed("Unable to read the download.") }
                if count == 0 { break }
                try buffer.withUnsafeBytes { try emit(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
        case DropCodec.encoding:
            guard let context = ZSTD_createDCtx() else { throw CLIError.dropFailed("Unable to start decompressing.") }
            defer { ZSTD_freeDCtx(context) }
            var output = [UInt8](repeating: 0, count: max(ZSTD_DStreamOutSize(), 128 * 1024))
            var lastResult = 1
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw CLIError.dropFailed("Unable to read the download.") }
                if count == 0 { break }
                try buffer.withUnsafeBytes { inputBytes in
                    var source = ZSTD_inBuffer(src: inputBytes.baseAddress, size: count, pos: 0)
                    // Until the input is used up and the decoder has
                    // nothing left inside: a full output buffer may mean
                    // more is waiting — unless the frame just ended, since
                    // asked again with no input it would start on the next
                    // frame's header (a file of a multiple of 128 KiB).
                    var outputFull = false
                    while source.pos < source.size || (outputFull && lastResult != 0) {
                        try output.withUnsafeMutableBytes { outputBytes in
                            var sink = ZSTD_outBuffer(dst: outputBytes.baseAddress, size: outputBytes.count, pos: 0)
                            lastResult = ZSTD_decompressStream(context, &sink, &source)
                            if ZSTD_isError(lastResult) != 0 {
                                throw DropDamage(message: "\(entry.id) is damaged (\(DropCodec.zstdError(lastResult))); it was not saved.")
                            }
                            try emit(UnsafeRawBufferPointer(rebasing: outputBytes[..<sink.pos]))
                            outputFull = sink.pos == sink.size
                        }
                    }
                }
            }
            guard lastResult == 0 else {
                throw DropDamage(message: "\(entry.id) ends early; it was not saved.")
            }
        default:
            throw CLIError.dropFailed("\(entry.id) is stored as \(entry.encoding), which this ighostvt-cli cannot read. Update it.")
        }
        guard written == entry.size, DropCodec.hex(hasher.finalize()) == entry.sha256 else {
            throw DropDamage(message: "\(entry.id) does not match what was uploaded; it was not saved.")
        }
    }
}

/// The downloaded bytes are not the file that was uploaded: worth fetching
/// again from the start, unlike a failure to write the decoded copy.
struct DropDamage: Error {
    var message: String
}
