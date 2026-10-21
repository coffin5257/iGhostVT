import Darwin
import Foundation

var failures = 0
func check(_ ok: Bool, _ label: String) {
    if ok { print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label)") }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-link-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let folder = root.appendingPathComponent("Project name + 中文")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
let file = root.appendingPathComponent("file")
try Data().write(to: file)
let alias = root.appendingPathComponent("alias")
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
func url(_ path: String, extra: [URLQueryItem] = []) -> URL {
    var c = URLComponents(); c.scheme = "ighostvt"; c.host = "new"
    c.queryItems = [URLQueryItem(name: "directory", value: path)] + extra
    return c.url!
}
let resolved = realpath(folder.path, nil)!
let canonical = String(cString: resolved)
free(resolved)
check(TerminalLink(URL(string: "ighostvt://new")!) == .new(directory: nil), "existing new-tab link")
check(TerminalLink(URL(string: "ighostvt://session/42")!) == .session(42), "existing session link")
check(TerminalLink(url(folder.path)) == .new(directory: canonical), "spaces, plus and Unicode stay a directory")
check(TerminalLink(url(alias.path)) == .new(directory: canonical), "symlink is canonicalized")
check(TerminalLink(url(file.path)) == nil, "regular file rejected")
check(TerminalLink(url(root.appendingPathComponent("missing").path)) == nil, "missing directory rejected")
check(TerminalLink(url("relative")) == nil, "relative directory rejected")
check(TerminalLink(url(folder.path + "\0ignored")) == nil, "NUL rejected before realpath")
check(TerminalLink(url(folder.path, extra: [URLQueryItem(name: "directory", value: root.path)])) == nil, "duplicate directory rejected")
check(TerminalLink(url(folder.path, extra: [URLQueryItem(name: "command", value: "echo nope")])) == nil, "command field rejected")
check(TerminalLink(URL(string: "ighostvt://new?command=echo")!) == nil, "command-only link rejected")
check(TerminalLink(URL(string: "ighostvt://new#fragment")!) == nil, "fragment rejected")
check(TerminalLink(URL(string: "ighostvt://user@new")!) == nil, "credentials rejected")
check(TerminalLink(URL(string: "ighostvt://new/extra")!) == nil, "unexpected path rejected")
check(TerminalLink(URL(string: "ighostvt://session/0")!) == nil, "zero session rejected")
check(TerminalLink(URL(string: "ighostvt://session/42/extra")!) == nil, "extra session path rejected")
exit(failures == 0 ? 0 : 1)
