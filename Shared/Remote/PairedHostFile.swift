import Darwin
import Foundation
import Network

/// A device this one has paired with: what to call it, and the key that
/// opens a link to it. The key is the whole of the pairing — whoever holds
/// it is this device to that host.
struct PairedRemoteHost: Codable, Equatable, Identifiable, Sendable {
    /// The host's own id, from its Bonjour TXT record and the pairing reply.
    var id: String
    /// What the host calls itself — its device name, kept in step with its
    /// advertisement (`PairedRemoteHostStore.syncName`).
    var name: String
    /// What the user calls it here, when they named it; nil follows `name`.
    var nickname: String? = nil
    /// This device's id as that host knows it.
    var deviceID: String
    var deviceKey: Data
    var pairedAt: Date
    /// The address it was last reached at directly, as the connection
    /// resolved it — never the relay's. The way back in on a launch where
    /// the browser has not seen the host yet.
    var lastAddress: String?
    /// When a link last reached it — pairing, then every connection.
    var lastSeen: Date? = nil

    /// The name to show: the nickname, or the device's own.
    var displayName: String {
        nickname ?? name
    }

    /// Where to try when the browser has not found the host: the address
    /// it last answered at.
    var lastEndpoint: NWEndpoint? {
        guard let lastAddress, let port = NWEndpoint.Port(rawValue: RemoteAccess.port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(lastAddress), port: port)
    }
}

/// The paired hosts on disk, one JSON file that the app and `ighostvt-cli`
/// both keep — the CLI runs as the same user and is this device to every
/// host the app paired with, so it reads the app's pairings rather than
/// making its own.
///
/// Every change is a read-modify-write under `flock` on the file's
/// directory, reading the file afresh inside the lock: whichever process
/// writes second sees the first one's change instead of writing over it
/// from a cache. The file is replaced whole — a 0600 temporary file renamed
/// over it — so a reader without the lock sees the old file or the new one,
/// never half of either. `Stamp` says which file a reader saw: every write
/// is a new inode, so a process can tell its own last write from someone
/// else's by the stamp alone, without comparing contents.
enum PairedHostFile {
    static let fileName = "RemoteHosts.json"

    /// Which file was read: a rename makes a new inode, so two equal
    /// stamps are the same write.
    struct Stamp: Equatable, Sendable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modified: timespec

        static func == (lhs: Stamp, rhs: Stamp) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
        }
    }

    /// A few dozen hosts are a few KiB; anything far past that is not ours.
    private static let maximumFileByteCount = 1 << 20

    /// The file's stamp now; nil when there is none.
    static func stamp(at url: URL) -> Stamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Stamp(info)
    }

    /// The hosts in the file and the stamp of the file they came from. No
    /// file is no hosts (`stamp` nil); a file that does not decode is no
    /// hosts too, as it always was for the app. Never follows a symlink at
    /// the name.
    static func read(at url: URL) -> (hosts: [PairedRemoteHost], stamp: Stamp?) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return ([], nil) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumFileByteCount
        else { return ([], nil) }
        var data = Data(count: Int(info.st_size))
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard complete else { return ([], Stamp(info)) }
        var hosts = (try? JSONDecoder().decode([PairedRemoteHost].self, from: data)) ?? []
        // Earlier builds kept whatever the connection resolved, IPv6
        // included; only an IPv4 address is kept. The next connection
        // records the right one.
        for index in hosts.indices {
            if let address = hosts[index].lastAddress, IPv4Address(address) == nil {
                hosts[index].lastAddress = nil
            }
        }
        return (hosts, Stamp(info))
    }

    /// Runs `body` holding the directory's lock, which every writer of the
    /// file takes; the directory is made (0700) if it is missing. Nil when
    /// the directory cannot be made or locked.
    static func withLock<T>(at url: URL, _ body: () throws -> T) rethrows -> T? {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { return nil }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Replaces the file with `hosts`, sorted by name; the stamp of the
    /// new file, nil when it could not be written. Call inside `withLock`.
    @discardableResult
    static func write(_ hosts: [PairedRemoteHost], at url: URL) -> Stamp? {
        let sorted = hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let data = try? JSONEncoder().encode(sorted) else { return nil }
        let directory = url.deletingLastPathComponent().path
        var template = Array((directory + "/.RemoteHosts.XXXXXX").utf8CString)
        // 0600 from the first byte: the keys are never readable by anyone
        // else, not even for a moment.
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return nil }
        let temporary = String(cString: template)
        #if os(iOS) && !targetEnvironment(macCatalyst)
            // Class C, as the app always wrote it: a tab that reconnects in
            // the background after a reboot-and-unlock still reads it.
            _ = fcntl(descriptor, F_SETPROTECTIONCLASS, 3)
        #endif
        let written = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return fsync(descriptor) == 0
        }
        var info = stat()
        let stated = fstat(descriptor, &info) == 0
        close(descriptor)
        // `rename` replaces a symlink left at the name rather than
        // following it.
        guard written, stated, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            return nil
        }
        return Stamp(info)
    }
}

/// The paired hosts held in memory for a process that keeps the file —
/// the app — and kept true to it while another process (`ighostvt-cli
/// pair`) writes it too.
///
/// A change is a read-modify-write under the file's lock against the file
/// as it is now: when it is not the one cached, it is read again first.
/// A watch on the directory (a rename over the file is a write to the
/// directory; the file itself is a new inode each time) brings in what
/// another process wrote. The watch knows this process's own writes by
/// their stamp and says nothing about them, and calls `onExternalChange`
/// only when the hosts it read differ from the ones held — so nothing done
/// in answer to that call, which may well write the file, can come back to
/// it as another change.
final class PairedHostCache: @unchecked Sendable {
    let url: URL
    private let onExternalChange: @Sendable () -> Void
    private let lock = NSLock()
    private let watchQueue = DispatchQueue(label: "wiki.qaq.ighostvt.paired-hosts.watch")
    private var cache: [PairedRemoteHost]?
    /// The file the cache came from, or that this process last wrote.
    private var cacheStamp: PairedHostFile.Stamp?
    private var watcher: DispatchSourceFileSystemObject?

    init(url: URL, onExternalChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onExternalChange = onExternalChange
    }

    deinit {
        watcher?.cancel()
    }

    var hosts: [PairedRemoteHost] {
        lock.withLock { loadedLocked() }
    }

    /// One change. `change` says whether it changed anything; nothing is
    /// written when it did not. True when the file now holds the change;
    /// `failed` hears of a change that could not be written.
    @discardableResult
    func modify(failed: () -> Void = {}, _ change: (inout [PairedRemoteHost]) -> Bool) -> Bool {
        lock.withLock {
            _ = loadedLocked()
            let written = PairedHostFile.withLock(at: url) { () -> Bool in
                // Another process wrote since this one last looked: start
                // from what it wrote, not from the cache.
                if PairedHostFile.stamp(at: url) != cacheStamp {
                    let (current, stamp) = PairedHostFile.read(at: url)
                    cache = current
                    cacheStamp = stamp
                }
                var hosts = cache ?? []
                guard change(&hosts) else { return false }
                guard let stamp = PairedHostFile.write(hosts, at: url) else {
                    failed()
                    return false
                }
                // What was written, in the order it was written.
                cache = PairedHostFile.read(at: url).hosts
                cacheStamp = stamp
                return true
            }
            return written ?? false
        }
    }

    private func loadedLocked() -> [PairedRemoteHost] {
        if let cache {
            return cache
        }
        let (loaded, stamp) = PairedHostFile.read(at: url)
        cache = loaded
        cacheStamp = stamp
        watchLocked()
        return loaded
    }

    /// Once, from the first load.
    private func watchLocked() {
        guard watcher == nil else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: watchQueue,
        )
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { close(descriptor) }
        watcher = source
        source.resume()
    }

    /// Something in the directory moved: another process's file is read,
    /// and announced only when its hosts are not the ones held.
    private func directoryChanged() {
        let changed = lock.withLock { () -> Bool in
            let stamp = PairedHostFile.stamp(at: url)
            guard stamp != cacheStamp else { return false }
            let (current, readStamp) = PairedHostFile.read(at: url)
            cacheStamp = readStamp
            guard current != cache else { return false }
            cache = current
            return true
        }
        if changed {
            onExternalChange()
        }
    }
}
