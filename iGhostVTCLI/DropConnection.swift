import CryptoKit
import Darwin
import Foundation

/// One drop zone session at the relay (`Relay/PROTOCOL.md`, "drop"): the
/// control protocol's magic and hello, a `drop` request signed with the
/// relay key, and then requests one after another on the same connection.
///
/// Blocking sockets, not Network.framework: a CLI does one thing at a time,
/// and a file's bytes go straight from a buffer to `send`. Every read and
/// write gives up after `idleTimeout` without progress, never for taking
/// long — a big file over a slow relay is not a dead one.
final class DropConnection {
    static let idleTimeout: TimeInterval = 60
    static let connectTimeout: TimeInterval = 10
    static let maximumChunkByteCount = 1 << 20

    /// What the relay said about itself when it admitted this session.
    struct Welcome {
        var ttl: TimeInterval
        var fileByteLimit: Int64
        var totalByteLimit: Int64
    }

    private let fd: Int32
    private(set) var welcome = Welcome(ttl: 0, fileByteLimit: 0, totalByteLimit: 0)

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

    /// Connects, proves membership, and is admitted — or says why not.
    static func open(_ relay: RelayConfiguration) throws -> DropConnection {
        let connection = try DropConnection(fd: connect(host: relay.host, port: relay.port))
        var opening = RelayControl.magic
        opening.append(UInt8(RelayControl.protocolVersion))
        try connection.write(Data(opening))
        let hello = try connection.readFrame()
        guard hello["relay"] as? String == "ighostvt-relay", let version = hello["version"] as? Int else {
            throw CLIError.dropUnavailable("\(relay.endpointDescription) is not an iGhostVT relay.")
        }
        guard version == RelayControl.protocolVersion else {
            throw CLIError.dropUnavailable("The relay speaks protocol \(version); this ighostvt-cli speaks \(RelayControl.protocolVersion). Update the one that is older.")
        }
        guard hello["relayID"] as? String == relay.relayID, let nonce = hello["nonce"] as? String else {
            throw CLIError.dropUnavailable("\(relay.endpointDescription) is another relay than the configuration names. Import its configuration again.")
        }
        let message = RelayControl.signedMessage(role: .drop, relayID: relay.relayID, nonce: nonce, parameter: "")
        guard let signature = RelayControl.sign(message, with: relay.signingKey) else {
            throw CLIError.dropFailed("Unable to sign the request.")
        }
        try connection.writeFrame(["role": RelayControl.Role.drop.rawValue, "sig": signature])
        let answer = try connection.readFrame()
        guard answer["ok"] as? Bool == true else {
            switch answer["reason"] as? String {
            case "auth":
                throw CLIError.dropUnavailable("The relay did not accept this configuration's key. Import its current configuration.")
            case "full":
                throw CLIError.dropUnavailable("The relay's drop zone is busy. Try again in a moment.")
            default:
                throw CLIError.dropUnavailable("This relay has no drop zone: it is older than iGhostVT 1.6.15, or RELAY_DROP_BYTES turned it off. Update the relay's image.")
            }
        }
        connection.welcome = Welcome(
            ttl: TimeInterval(answer["ttl"] as? Int ?? 0),
            fileByteLimit: (answer["fileBytes"] as? NSNumber)?.int64Value ?? 0,
            totalByteLimit: (answer["totalBytes"] as? NSNumber)?.int64Value ?? 0,
        )
        return connection
    }

    // MARK: Requests

    func list() throws -> [DropEntry] {
        try writeFrame(["op": "ls"])
        let answer = try readAnswer()
        return (answer["files"] as? [[String: Any]] ?? []).compactMap(DropEntry.init)
    }

    /// Starts an upload, or resumes `id`'s; the relay's id and how many
    /// stored bytes it already holds.
    func beginPut(_ header: [String: Any]) throws -> (id: String, offset: Int64) {
        var request = header
        request["op"] = "put"
        try writeFrame(request)
        let answer = try readAnswer()
        guard let id = answer["id"] as? String, DropEntry.isValidID(id) else {
            throw CLIError.dropFailed("The relay answered without an id.")
        }
        return (id, (answer["offset"] as? NSNumber)?.int64Value ?? 0)
    }

    /// One chunk of an upload's stream; empty ends it.
    func writeChunk(_ bytes: UnsafeRawBufferPointer) throws {
        precondition(bytes.count <= Self.maximumChunkByteCount)
        var header = UInt32(bytes.count).bigEndian
        try withUnsafeBytes(of: &header) { try write($0) }
        if bytes.count > 0 {
            try write(bytes)
        }
    }

    /// Ends an upload; the bytes the relay stored.
    func commit(sha256: String) throws -> Int64 {
        var empty = UInt32(0)
        try withUnsafeBytes(of: &empty) { try write($0) }
        try writeFrame(["op": "commit", "sha256": sha256])
        let answer = try readAnswer()
        return (answer["stored"] as? NSNumber)?.int64Value ?? 0
    }

    /// Starts a download at `offset`; the stored size, whose bytes from
    /// `offset` on follow and are read with `read(into:)`.
    func beginGet(id: String, offset: Int64) throws -> Int64 {
        try writeFrame(["op": "get", "id": id, "offset": offset])
        let answer = try readAnswer()
        guard let stored = (answer["stored"] as? NSNumber)?.int64Value, stored >= offset else {
            throw CLIError.dropFailed("The relay answered without the file's size.")
        }
        return stored
    }

    func remove(id: String) throws {
        try writeFrame(["op": "rm", "id": id])
        _ = try readAnswer()
    }

    /// The reason the relay gave before it closed, after a write failed:
    /// a refusal mid-upload arrives as a frame and then a closed socket.
    func refusalAfterFailedWrite() -> String? {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let frame = try? readFrame(), frame["ok"] as? Bool == false else { return nil }
        return frame["reason"] as? String
    }

    // MARK: Frames

    private func readAnswer() throws -> [String: Any] {
        let answer = try readFrame()
        guard answer["ok"] as? Bool == true else {
            throw DropRefusal(reason: answer["reason"] as? String ?? "refused")
        }
        return answer
    }

    func writeFrame(_ object: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: object)
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(body.count).bigEndian, as: UInt32.self) }
        frame.append(body)
        try write(frame)
    }

    func readFrame() throws -> [String: Any] {
        var header = [UInt8](repeating: 0, count: 4)
        try header.withUnsafeMutableBytes { try readExactly($0) }
        let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
        guard length > 0, length <= RelayControl.maximumFrameByteCount else {
            throw CLIError.dropFailed("The relay sent a \(length)-byte frame.")
        }
        var body = Data(count: length)
        try body.withUnsafeMutableBytes { try readExactly($0) }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CLIError.dropFailed("The relay sent a frame that is not a JSON object.")
        }
        return object
    }

    // MARK: Bytes

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        var sent = 0
        while sent < bytes.count {
            let n = Darwin.send(fd, bytes.baseAddress! + sent, bytes.count - sent, 0)
            if n > 0 {
                sent += n
            } else if n < 0, errno == EINTR {
                continue
            } else {
                throw DropConnectionLost(writing: true, code: n < 0 ? errno : 0)
            }
        }
    }

    /// Up to `buffer.count` bytes, at least one.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while true {
            let n = Darwin.recv(fd, buffer.baseAddress!, buffer.count, 0)
            if n > 0 {
                return n
            }
            if n < 0, errno == EINTR {
                continue
            }
            throw DropConnectionLost(writing: false, code: n < 0 ? errno : 0)
        }
    }

    private func readExactly(_ buffer: UnsafeMutableRawBufferPointer) throws {
        var filled = 0
        while filled < buffer.count {
            filled += try read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled...]))
        }
    }

    // MARK: Connecting

    private static func connect(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let first = list else {
            throw CLIError.dropUnavailable("Unable to find the relay \(host): \(String(cString: gai_strerror(status))).")
        }
        defer { freeaddrinfo(list) }
        var reasons: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            cursor = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            if let failure = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) {
                reasons.append(failure)
                Darwin.close(fd)
                continue
            }
            tune(fd)
            return fd
        }
        let detail = reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))"
        throw CLIError.dropUnavailable("Unable to reach the relay at \(host):\(port)\(detail).")
    }

    /// Connects with a timeout; nil, or what went wrong.
    private static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> String? {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        if Darwin.connect(fd, address, length) == 0 {
            return nil
        }
        guard errno == EINPROGRESS else { return String(cString: strerror(errno)) }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&poller, 1, Int32(connectTimeout * 1000))
        guard ready > 0 else { return ready == 0 ? "timed out" : String(cString: strerror(errno)) }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
        return error == 0 ? nil : String(cString: strerror(error))
    }

    /// Keepalive as every relay leg has it, no SIGPIPE, and the idle
    /// timeout on each read and write.
    private static func tune(_ fd: Int32) {
        func set(_ level: Int32, _ name: Int32, _ value: Int32) {
            var value = value
            setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
        }
        set(SOL_SOCKET, SO_NOSIGPIPE, 1)
        set(SOL_SOCKET, SO_KEEPALIVE, 1)
        set(IPPROTO_TCP, TCP_KEEPALIVE, 10)
        set(IPPROTO_TCP, TCP_KEEPINTVL, 5)
        set(IPPROTO_TCP, TCP_KEEPCNT, 3)
        set(IPPROTO_TCP, TCP_NODELAY, 1)
        var timeout = timeval(tv_sec: Int(idleTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// The relay said no to one request; the session goes on.
struct DropRefusal: Error {
    var reason: String
}

/// The connection broke, or went quiet past the idle timeout.
struct DropConnectionLost: Error {
    var writing: Bool
    var code: Int32

    var message: String {
        if code == EAGAIN || code == EWOULDBLOCK {
            return "The relay stopped answering."
        }
        if code == 0 {
            return "The relay closed the connection."
        }
        return "The connection to the relay was lost (\(String(cString: strerror(code))))."
    }
}

/// One row of the drop zone's manifest.
struct DropEntry {
    var id: String
    var name: String
    var size: Int64
    var stored: Int64
    var encoding: String
    var mode: UInt32
    var mtime: Int64
    var sha256: String
    var fingerprint: String
    var created: Int64
    var isComplete: Bool
    /// When it goes; nil while a connection that put or got it is open.
    var expires: Int64?

    /// A relay's id is a lower-case UUID. Anything else is never put into
    /// a path or printed: a relay that sends one is not to be trusted.
    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 36 && UUID(uuidString: id) != nil && id == id.lowercased()
    }

    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, Self.isValidID(id), let name = row["name"] as? String else { return nil }
        func int(_ key: String) -> Int64 {
            (row[key] as? NSNumber)?.int64Value ?? 0
        }
        self.id = id
        self.name = name
        size = int("size")
        stored = int("stored")
        encoding = row["encoding"] as? String ?? ""
        mode = UInt32(truncatingIfNeeded: int("mode"))
        mtime = int("mtime")
        sha256 = row["sha256"] as? String ?? ""
        fingerprint = row["fingerprint"] as? String ?? ""
        created = int("created")
        isComplete = row["complete"] as? Bool ?? false
        expires = (row["expires"] as? NSNumber)?.int64Value
    }
}
