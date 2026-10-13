import Darwin
import Foundation

// The paired-hosts file the app and `ighostvt-cli` share
// (`PairedHostFile`, `PairedHostCache`), across real processes: this
// program runs itself as the other writer.
//
//   paired-hosts                    the checks
//   paired-hosts add <file> <id>... adds hosts the way `ighostvt-cli pair`
//                                   does, one locked read-modify-write each
//   paired-hosts rewrite <file>     writes the file again with the same hosts

func host(_ id: String) -> PairedRemoteHost {
    PairedRemoteHost(id: id, name: id, deviceID: "device", deviceKey: Data(repeating: 7, count: 32), pairedAt: Date(timeIntervalSince1970: 0))
}

func add(_ ids: [String], at url: URL) {
    for id in ids {
        _ = PairedHostFile.withLock(at: url) {
            var hosts = PairedHostFile.read(at: url).hosts
            hosts.removeAll { $0.id == id }
            hosts.append(host(id))
            PairedHostFile.write(hosts, at: url)
        }
    }
}

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "add" {
    add(Array(arguments.dropFirst(3)), at: URL(fileURLWithPath: arguments[2]))
    exit(0)
}
if arguments.count == 3, arguments[1] == "rewrite" {
    let url = URL(fileURLWithPath: arguments[2])
    _ = PairedHostFile.withLock(at: url) {
        PairedHostFile.write(PairedHostFile.read(at: url).hosts, at: url)
    }
    exit(0)
}

var failures = 0
func check(_ condition: Bool, _ what: String) {
    print(condition ? "  ok   \(what)" : "  FAIL \(what)")
    if !condition {
        failures += 1
    }
}

/// Runs this program as another process and waits for it.
func run(_ arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = arguments
    try! process.run()
    return process
}

/// Waits until `condition` holds or a few seconds pass; a watch answers in
/// milliseconds, and a quiet settle is how "nothing was announced" is seen.
func settle(until condition: () -> Bool = { false }, seconds: TimeInterval = 0.5) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !condition() {
        usleep(20000)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paired-hosts-\(getpid())/iGhostVT")
defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
let url = directory.appendingPathComponent(PairedHostFile.fileName)

print("paired hosts file")
check(PairedHostFile.read(at: url).hosts.isEmpty && PairedHostFile.stamp(at: url) == nil, "no file is no hosts")
add(["solo"], at: url)
var info = stat()
check(stat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "written 0600")
check(PairedHostFile.read(at: url).hosts.map(\.id) == ["solo"], "reads back what was written")
let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
check(leftovers == [PairedHostFile.fileName], "leaves no temporary file behind")

let symlinked = directory.appendingPathComponent("link.json")
symlink(url.path, symlinked.path)
check(PairedHostFile.read(at: symlinked).hosts.isEmpty, "never follows a symlink at the name")

// Eight processes, twenty additions each, all at once: a read-modify-write
// that is not under the lock loses some of them.
let writers = (0 ..< 8).map { writer in
    run(["add", url.path] + (0 ..< 20).map { "w\(writer)-\($0)" })
}
writers.forEach { $0.waitUntilExit() }
check(PairedHostFile.read(at: url).hosts.count == 161, "concurrent writers lose nothing (\(PairedHostFile.read(at: url).hosts.count) of 161)")

print("paired hosts cache")
try? FileManager.default.removeItem(at: url)
let announced = Counter()
nonisolated(unsafe) var cacheRef: PairedHostCache?
nonisolated(unsafe) var writesInAnswer = false
let cache = PairedHostCache(url: url) {
    announced.increment()
    // What the app does in answer — a host renamed in step with its
    // advertisement writes the file — must not come back as a change.
    if writesInAnswer, let cache = cacheRef {
        cache.modify { hosts in
            guard let index = hosts.indices.first else { return false }
            hosts[index].nickname = "answered \(announced.count)"
            return true
        }
    }
}
cacheRef = cache
check(cache.hosts.isEmpty, "starts empty")

for index in 0 ..< 5 {
    cache.modify { hosts in
        hosts.append(host("own-\(index)"))
        return true
    }
}
settle()
check(announced.count == 0, "its own writes are not announced (\(announced.count))")
check(PairedHostFile.read(at: url).hosts.count == 5, "its own writes reach the file")

run(["add", url.path, "cli-1"]).waitUntilExit()
settle(until: { announced.count >= 1 })
settle()
check(announced.count == 1, "another process's write is announced once (\(announced.count))")
check(cache.hosts.contains { $0.id == "cli-1" }, "and the cache has it")

run(["rewrite", url.path]).waitUntilExit()
settle()
check(announced.count == 1, "a write that changes no host is not announced (\(announced.count))")

// A change made from a stale cache would drop what the other process
// wrote; the cache reads the file again first.
let before = cache.hosts.count
run(["add", url.path, "cli-2"]).waitUntilExit()
cache.modify { hosts in
    hosts.append(host("own-after"))
    return true
}
let ids = Set(PairedHostFile.read(at: url).hosts.map(\.id))
check(ids.contains("cli-2") && ids.contains("own-after") && ids.count == before + 2, "a change keeps what another process wrote meanwhile")
settle()

let beforeAnswer = announced.count
writesInAnswer = true
run(["add", url.path, "cli-3"]).waitUntilExit()
settle(until: { announced.count > beforeAnswer })
settle(seconds: 1)
check(announced.count == beforeAnswer + 1, "a write made in answer comes back as nothing (\(announced.count - beforeAnswer))")
writesInAnswer = false

// Writers on both sides at once: the file ends with everything, and the
// cache ends with the file.
let racing = run(["add", url.path] + (0 ..< 30).map { "race-cli-\($0)" })
for index in 0 ..< 30 {
    cache.modify { hosts in
        hosts.append(host("race-own-\(index)"))
        return true
    }
}
racing.waitUntilExit()
settle(seconds: 1)
let file = PairedHostFile.read(at: url).hosts
check(file.filter { $0.id.hasPrefix("race-") }.count == 60, "both sides' racing writes all land")
check(Set(cache.hosts.map(\.id)) == Set(file.map(\.id)), "and the cache ends where the file is")

print(failures == 0 ? "paired hosts: all checks passed" : "paired hosts: \(failures) failed")
exit(failures == 0 ? 0 : 1)
