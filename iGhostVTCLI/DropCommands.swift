import CryptoKit
import CZstd
import Darwin
import Foundation

/// `ighostvt-cli drop`: files on the relay for any device that has its
/// configuration — the way to move one between two devices without typing
/// it through a shell. The relay keeps each file until thirty minutes (the
/// relay's `ttl`) after the last connection that put or got it closed, and
/// empties the whole zone whenever it restarts.
enum DropCommand: Equatable {
    case list
    case put(paths: [String])
    case get(selectors: [String], output: String?, force: Bool)
    case remove(selectors: [String])
}

enum DropCommands {
    /// `drop [--relay <file>] [ls | put … | get … | rm …]`.
    static func parse(_ arguments: [String]) throws -> (command: DropCommand, relayPath: String?) {
        var rest = arguments
        var relayPath: String?
        if let first = rest.first, first == "--relay" || first.hasPrefix("--relay=") {
            rest.removeFirst()
            if first.hasPrefix("--relay=") {
                relayPath = String(first.dropFirst("--relay=".count))
            } else if !rest.isEmpty {
                relayPath = rest.removeFirst()
            }
            guard let relayPath, !relayPath.isEmpty else { throw CLIError.usage("--relay needs a .vtrpsc file.") }
        }
        let verb = rest.first ?? "ls"
        let operands = Array(rest.dropFirst())
        switch verb {
        case "ls", "list":
            guard operands.isEmpty else { throw CLIError.usage("The drop ls command takes no arguments.") }
            return (.list, relayPath)
        case "put":
            guard !operands.isEmpty else { throw CLIError.usage("The drop put command takes one or more files.") }
            return (.put(paths: operands.first == "--" ? Array(operands.dropFirst()) : operands), relayPath)
        case "get":
            var selectors: [String] = []
            var output: String?
            var force = false
            var remaining = operands[...]
            while let word = remaining.popFirst() {
                switch word {
                case "-o", "--output":
                    guard let value = remaining.popFirst(), !value.isEmpty else {
                        throw CLIError.usage("-o needs a file or a folder.")
                    }
                    output = value
                case "-f", "--force":
                    force = true
                default:
                    selectors.append(word)
                }
            }
            guard !selectors.isEmpty else {
                throw CLIError.usage("The drop get command takes one or more files, by id or by name. Run `ighostvt-cli drop` to see them.")
            }
            return (.get(selectors: selectors, output: output, force: force), relayPath)
        case "rm":
            guard !operands.isEmpty else { throw CLIError.usage("The drop rm command takes one or more files, by id or by name.") }
            return (.remove(selectors: operands), relayPath)
        default:
            throw CLIError.usage("No drop command named \(verb). The drop commands are ls, put, get and rm.")
        }
    }

    static func run(_ command: DropCommand, relayPath: String?) throws {
        let relay: RelayConfiguration
        if let relayPath {
            relay = try RelayStoreFile.read(from: relayPath)
        } else if let configured = AppFiles.relay() {
            relay = configured
        } else {
            throw CLIError.dropUnavailable("iGhostVT has no relay. Import one in Settings ▸ Remote Access, or name a configuration with --relay <file.vtrpsc>.")
        }
        let connection = try DropConnection.open(relay)
        do {
            switch command {
            case .list:
                try list(connection)
            case let .put(paths):
                try put(paths, connection)
            case let .get(selectors, output, force):
                try get(selectors, output: output, force: force, connection)
            case let .remove(selectors):
                try remove(selectors, connection)
            }
        } catch let lost as DropConnectionLost {
            throw CLIError.dropFailed(lost.message)
        } catch let refusal as DropRefusal {
            throw CLIError.dropFailed(message(for: refusal.reason, connection))
        }
    }

    // MARK: ls

    private static func list(_ connection: DropConnection) throws {
        let files = try connection.list()
        guard !files.isEmpty else {
            print("The drop zone is empty.")
            return
        }
        let now = Int64(Date().timeIntervalSince1970)
        var rows = [["ID", "SIZE", "STORED", "KEPT", "NAME"]]
        for file in files {
            let kept: String = if !file.isComplete {
                file.expires == nil ? "uploading" : "partial, " + remaining(file.expires! - now)
            } else if let expires = file.expires {
                remaining(expires - now)
            } else {
                "in use"
            }
            rows.append([shortID(file.id, among: files), bytes(file.size), bytes(file.stored), kept, printable(file.name)])
        }
        let widths = (0 ..< 4).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            let padded = (0 ..< 4).map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
            print((padded + [row[4]]).joined(separator: "  "))
        }
    }

    // MARK: put

    private static func put(_ paths: [String], _ connection: DropConnection) throws {
        // Every file is checked before the first byte goes, so a typo at the
        // end of the list does not leave half of it uploaded.
        let files = try paths.map(openForUpload)
        defer { files.forEach { Darwin.close($0.fd) } }
        let existing = try connection.list()
        for file in files {
            try upload(file, resuming: existing, connection)
        }
    }

    private struct UploadFile {
        var path: String
        var name: String
        var fd: Int32
        var size: Int64
        var mode: UInt32
        var mtime: Int64
        var fingerprint: String
    }

    private static func openForUpload(_ path: String) throws -> UploadFile {
        // Non-blocking until it is known to be a file: opening a FIFO
        // would wait for a writer.
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw CLIError.usage("Unable to open \(path): \(String(cString: strerror(errno))).")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw CLIError.usage("\(path) is not a file. The drop zone takes files, not folders; archive a folder first (tar czf).")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard isValidName(name) else {
            Darwin.close(fd)
            throw CLIError.usage("\(path) has a name the drop zone does not take: control characters, or longer than 255 bytes. Rename it first.")
        }
        return UploadFile(
            path: path,
            name: name,
            fd: fd,
            size: Int64(info.st_size),
            mode: UInt32(info.st_mode) & 0o777,
            mtime: Int64(info.st_mtimespec.tv_sec),
            fingerprint: fingerprint(fd),
        )
    }

    /// What a resume checks besides name, size and time: the SHA-256 of the
    /// file's first MiB. Two files that share all of it are rare enough;
    /// the downloader's whole-file check catches what is left.
    private static func fingerprint(_ fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var filled = 0
        while filled < buffer.count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + filled, $0.count - filled, off_t(filled)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            filled += n
        }
        // Which encoder, too: another zstd, or another level, makes another
        // stream, and continuing one with the other would splice garbage.
        return "v1:z\(ZSTD_versionNumber())l\(DropCodec.level):" + DropCodec.hex(SHA256.hash(data: buffer[..<filled]))
    }

    private static func upload(_ file: UploadFile, resuming existing: [DropEntry], _ connection: DropConnection) throws {
        let header: [String: Any] = [
            "name": file.name, "size": file.size, "mode": file.mode, "mtime": file.mtime, "encoding": DropCodec.encoding,
            "fingerprint": file.fingerprint,
        ]
        // The same file cut off earlier, from here or anywhere: same name,
        // size, modification time and first MiB. The stream is the same
        // bytes again, so only what the relay lacks is sent; the
        // downloader's whole-file check catches a file that was not after all.
        var begun: (id: String, offset: Int64)?
        candidates: for partial in existing where !partial.isComplete && partial.name == file.name &&
            partial.size == file.size && partial.mtime == file.mtime && partial.encoding == DropCodec.encoding &&
            partial.fingerprint == file.fingerprint
        {
            // Busy right after a cut: the relay is still reading what the
            // dead connection left in its buffers. Worth a few seconds.
            for attempt in 0 ..< 5 {
                do {
                    begun = try connection.beginPut(["id": partial.id])
                    break candidates
                } catch let refusal as DropRefusal where refusal.reason == "busy" && attempt < 4 {
                    Thread.sleep(forTimeInterval: 1)
                } catch is DropRefusal {
                    continue candidates
                }
            }
        }
        let (id, offset) = try begun ?? connection.beginPut(header)
        if offset > 0 {
            FileHandle.standardError.write(Data("Resuming \(printable(file.name)) at \(bytes(offset)) stored.\n".utf8))
        }

        let progress = Progress(label: "put", name: file.name, total: file.size)
        let encoder = DropEncoder(fd: file.fd, size: file.size, chunkByteCount: DropConnection.maximumChunkByteCount)
        defer { encoder.stop() }
        var position: Int64 = 0 // in the compressed stream
        var sha256 = ""
        loop: while true {
            switch encoder.next() {
            case let .chunk(data, consumed):
                let start = position
                position += Int64(data.count)
                guard position > offset else { continue }
                let skip = Int(max(0, offset - start))
                do {
                    try data.withUnsafeBytes { try connection.writeChunk(UnsafeRawBufferPointer(rebasing: $0[skip...])) }
                } catch let lost as DropConnectionLost {
                    progress.finish()
                    if let reason = connection.refusalAfterFailedWrite() {
                        throw DropRefusal(reason: reason)
                    }
                    throw CLIError.dropFailed("\(lost.message) Run the same command again to resume.")
                }
                progress.update(consumed)
            case let .end(digest):
                sha256 = digest
                break loop
            case let .failure(message):
                progress.finish()
                throw CLIError.dropFailed("\(file.path): \(message)")
            }
        }
        if position < offset {
            throw CLIError.dropFailed("The relay holds more of \(printable(file.name)) than the file makes; remove it with `ighostvt-cli drop rm \(id)` and put it again.")
        }
        let stored = try connection.commit(sha256: sha256)
        progress.finish()
        print("\(id)  \(printable(file.name))  \(bytes(file.size)) → \(bytes(stored))")
    }

    // MARK: get

    private static func get(_ selectors: [String], output: String?, force: Bool, _ connection: DropConnection) throws {
        let files = try connection.list()
        let entries = try selectors.map { try select($0, in: files) }
        var isDirectory: ObjCBool = false
        let outputIsDirectory = output.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue } ?? true
        if entries.count > 1, output != nil, !outputIsDirectory {
            throw CLIError.usage("-o must be a folder when getting more than one file.")
        }
        for entry in entries {
            guard entry.isComplete else {
                throw CLIError.dropFailed("\(printable(entry.name)) is still being uploaded, or its upload was cut off.")
            }
            let destination: String
            if let output, !outputIsDirectory {
                destination = output
            } else {
                guard isValidName(entry.name) else {
                    throw CLIError.dropFailed("\(entry.id) has a name this device will not use as a file name. Give one with -o.")
                }
                destination = (output ?? FileManager.default.currentDirectoryPath) + "/" + entry.name
            }
            try download(entry, to: destination, force: force, connection)
        }
    }

    private static func download(_ entry: DropEntry, to destination: String, force: Bool, _ connection: DropConnection) throws {
        if !force, access(destination, F_OK) == 0 {
            throw CLIError.dropFailed("\(destination) already exists. Pass -f to replace it.")
        }
        let folder = (destination as NSString).deletingLastPathComponent.isEmpty ? "." : (destination as NSString).deletingLastPathComponent
        let stem = "." + String(entry.id.prefix(8)) + ".ighostvt-drop"
        // The stored bytes go here first, so a download cut off resumes
        // where it stopped; the file itself appears only once whole and
        // checked.
        let partialPath = folder + "/" + stem + ".part"
        let partial = Darwin.open(partialPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard partial >= 0 else {
            throw CLIError.dropFailed("Unable to write in \(folder): \(String(cString: strerror(errno))).")
        }
        defer { Darwin.close(partial) }
        // In a folder others can write (/tmp), the name may have been taken
        // first: only a plain file of this user's, readable by nobody else.
        var info = stat()
        guard fstat(partial, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(partial, 0o600) == 0
        else {
            throw CLIError.dropFailed("\(partialPath) is not a file of this user's. Remove it, or get into another folder.")
        }
        // Two gets of one file into one folder would share these files.
        guard flock(partial, LOCK_EX | LOCK_NB) == 0 else {
            throw CLIError.dropFailed("Another ighostvt-cli is getting \(printable(entry.name)) into \(folder).")
        }
        removeLeftovers(of: stem, in: folder)
        var have = Int64(info.st_size)
        if have > entry.stored {
            ftruncate(partial, 0)
            have = 0
        }
        lseek(partial, off_t(have), SEEK_SET)

        let stored = try connection.beginGet(id: entry.id, offset: have)
        let progress = Progress(label: "get", name: entry.name, total: stored)
        progress.update(have)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while have < stored {
            let want = Int(min(Int64(buffer.count), stored - have))
            let count: Int
            do {
                count = try buffer.withUnsafeMutableBytes { try connection.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[..<want])) }
            } catch let lost as DropConnectionLost {
                progress.finish()
                throw CLIError.dropFailed("\(lost.message) Run the same command again to resume.")
            }
            try buffer.withUnsafeBytes { bytes in
                var done = 0
                while done < count {
                    let n = Darwin.write(partial, bytes.baseAddress! + done, count - done)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else {
                        throw CLIError.dropFailed("Unable to write \(partialPath): \(String(cString: strerror(errno))).")
                    }
                    done += n
                }
            }
            have += Int64(count)
            progress.update(have)
        }
        progress.finish()

        var template = Array((folder + "/" + stem + ".XXXXXX").utf8CString)
        let decoded = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard decoded >= 0 else {
            throw CLIError.dropFailed("Unable to write in \(folder): \(String(cString: strerror(errno))).")
        }
        let decodedPath = String(cString: template)
        var kept = false
        defer {
            Darwin.close(decoded)
            if !kept { unlink(decodedPath) }
        }
        // A declared size is the uploader's word, and a few bytes of zstd
        // can claim a terabyte: it has to fit before decoding starts.
        var volume = statfs()
        if fstatfs(decoded, &volume) == 0, Int64(volume.f_bavail) * Int64(volume.f_bsize) < entry.size {
            throw CLIError.dropFailed("\(printable(entry.name)) needs \(bytes(entry.size)), and \(folder) has less free. The download is kept; free some space and get it again.")
        }
        lseek(partial, 0, SEEK_SET)
        do {
            try DropDecoder.decode(from: partial, to: decoded, entry: entry)
        } catch let damage as DropDamage {
            // Damaged bytes would only be decoded again: start over next time.
            unlink(partialPath)
            throw CLIError.dropFailed(damage.message)
        }
        // The uploader's permission bits, never set-id ones, under this
        // process's umask; its modification time.
        let mask = umask(0)
        umask(mask)
        fchmod(decoded, mode_t(entry.mode & 0o777) & ~mask)
        var times = [
            timespec(tv_sec: Int(entry.mtime), tv_nsec: 0),
            timespec(tv_sec: Int(entry.mtime), tv_nsec: 0),
        ]
        futimens(decoded, &times)
        let moved = force ? rename(decodedPath, destination) : renamex_np(decodedPath, destination, UInt32(RENAME_EXCL))
        guard moved == 0 else {
            if errno == EEXIST {
                throw CLIError.dropFailed("\(destination) already exists. Pass -f to replace it.")
            }
            throw CLIError.dropFailed("Unable to save \(destination): \(String(cString: strerror(errno))).")
        }
        kept = true
        unlink(partialPath)
        print(destination)
    }

    /// Decoded copies an earlier run was killed before renaming or
    /// removing (`<stem>.XXXXXX`, as `mkstemp` names them).
    private static func removeLeftovers(of stem: String, in folder: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for name in names where name.hasPrefix(stem + ".") && name.count == stem.count + 7 && !name.hasSuffix(".part") {
            var info = stat()
            let path = folder + "/" + name
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() {
                unlink(path)
            }
        }
    }

    // MARK: rm

    private static func remove(_ selectors: [String], _ connection: DropConnection) throws {
        let files = try connection.list()
        let entries = try selectors.map { try select($0, in: files) }
        for entry in entries {
            try connection.remove(id: entry.id)
            print("\(entry.id)  \(printable(entry.name))")
        }
    }

    // MARK: Helpers

    /// A file by its id, the start of its id (four characters at least),
    /// or its name — the newest one uploaded completely, when several share
    /// it.
    private static func select(_ selector: String, in files: [DropEntry]) throws -> DropEntry {
        let wanted = selector.lowercased()
        if let exact = files.first(where: { $0.id == wanted }) {
            return exact
        }
        if wanted.count >= 4 {
            let matches = files.filter { $0.id.hasPrefix(wanted) }
            if matches.count == 1 {
                return matches[0]
            }
            if matches.count > 1 {
                throw CLIError.usage("More than one file's id starts with \(selector). Give more of it.")
            }
        }
        let named = files.filter { $0.name == selector }
        if let newest = named.filter(\.isComplete).max(by: { $0.created < $1.created }) ?? named.max(by: { $0.created < $1.created }) {
            return newest
        }
        throw CLIError.dropFailed("No file \(selector) in the drop zone. Run `ighostvt-cli drop` to see them.")
    }

    /// The relay's own rule (`protocol.ValidDropName`): one path component,
    /// nothing that reorders or hides text when printed.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            return false
        }
        return !name.unicodeScalars.contains(where: isHidden)
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v < 0x20 || v == 0x7F || (0x80 ..< 0xA0).contains(v) || v == 0x2028 || v == 0x2029 ||
            (0x200B ... 0x200F).contains(v) || (0x202A ... 0x202E).contains(v) || (0x2066 ... 0x2069).contains(v) || v == 0xFEFF
    }

    /// A name as a terminal should show it: anything the relay should have
    /// refused anyway, escaped rather than sent to the terminal.
    static func printable(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if isHidden(scalar) {
                out += String(format: "\\u{%X}", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func shortID(_ id: String, among files: [DropEntry]) -> String {
        var length = 8
        while length < id.count, files.contains(where: { $0.id != id && $0.id.hasPrefix(id.prefix(length)) }) {
            length += 4
        }
        return String(id.prefix(length))
    }

    private static func remaining(_ seconds: Int64) -> String {
        if seconds <= 60 { return "<1m" }
        return "\((seconds + 59) / 60)m"
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func message(for reason: String, _ connection: DropConnection) -> String {
        switch reason {
        case "unknown": "That file is no longer in the drop zone."
        case "incomplete": "That file is still being uploaded, or its upload was cut off."
        case "busy": "Another device is uploading that file right now."
        case "size": "The file is larger than the relay takes (\(bytes(connection.welcome.fileByteLimit)) after compression)."
        case "full": "The relay's drop zone is full (\(bytes(connection.welcome.totalByteLimit)), or its disk is. Remove files with `ighostvt-cli drop rm`, or wait for them to expire."
        default: "The relay refused the request (\(reason))."
        }
    }
}

/// A one-line progress report on standard error, only when it is a
/// terminal, at most a few times a second.
private final class Progress {
    private let label: String
    private let name: String
    private let total: Int64
    private let start = Date()
    private var last = Date.distantPast
    private var first: Int64?
    private let isShown = isatty(STDERR_FILENO) != 0
    private var drew = false

    init(label: String, name: String, total: Int64) {
        self.label = label
        self.name = DropCommands.printable(name)
        self.total = total
    }

    func update(_ done: Int64) {
        guard isShown else { return }
        if first == nil { first = done }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.2 else { return }
        last = now
        let elapsed = max(now.timeIntervalSince(start), 0.001)
        let rate = Double(done - (first ?? 0)) / elapsed
        let percent = total > 0 ? Int(Double(done) * 100 / Double(total)) : 100
        let line = "\(label) \(name)  \(percent)%  \(DropCommands.bytes(done))/\(DropCommands.bytes(total))  \(DropCommands.bytes(Int64(rate)))/s"
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + line).utf8))
        drew = true
    }

    func finish() {
        guard drew else { return }
        drew = false
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }
}
