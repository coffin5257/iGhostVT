import Darwin
import Foundation

/// Public navigation only: a session, a new tab, or a new shell's directory.
/// No URL field is ever interpreted as a command or typed into a terminal.
enum TerminalLink: Equatable {
    case session(UInt64)
    case new(directory: String?)

    init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "ighostvt",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        switch parts.host?.lowercased() {
        case "session":
            let path = parts.path.split(separator: "/")
            guard parts.query == nil, path.count == 1, let id = UInt64(path[0]), id > 0 else { return nil }
            self = .session(id)
        case "new":
            guard parts.path.isEmpty || parts.path == "/" else { return nil }
            guard let query = parts.queryItems else { self = .new(directory: nil); return }
            guard query.count == 1, query[0].name == "directory", let path = query[0].value,
                  path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < Int(MAXPATHLEN),
                  let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            var info = stat()
            guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            self = .new(directory: String(cString: resolved))
        default:
            return nil
        }
    }
}
