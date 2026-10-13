import CoreFoundation
import Darwin
import Foundation

/// What the app keeps that this program reads as the same user: its paired
/// hosts (`PairedHostFile`), its relay, and the identity it pairs and
/// connects under. The CLI is this device to every host the app paired
/// with — not a device of its own — so it reads all of it rather than
/// keeping a copy.
///
/// The app is the bundle this program ships in. On the Mac it is
/// unsandboxed, and keeps its files in the user's own Application Support.
/// On the device it has no container: its home is mobile's — the
/// bootstrap's `var/mobile` under roothide, the system's `/var/mobile`
/// under rootless — and its Application Support is in there.
enum AppFiles {
    /// The app's preferences domain, which `RemoteDeviceIdentity` writes.
    private static let preferencesDomain = "wiki.qaq.iGhostVT" as CFString

    static var pairedHostsURL: URL {
        URL(fileURLWithPath: applicationSupport + "/" + PairedHostFile.fileName)
    }

    static var relayPath: String {
        #if os(macOS)
            RelayStoreFile.path
        #else
            applicationSupport + "/Relay.vtrpsc"
        #endif
    }

    private static var applicationSupport: String {
        #if os(macOS)
            return home + "/Library/Application Support/iGhostVT"
        #else
            return home + "/Library/Application Support"
        #endif
    }

    /// The account's home, not `$HOME`: under `sudo -u` the environment
    /// may still name the caller's. On the device, the app's.
    private static var home: String {
        #if os(macOS)
            return getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
                ?? NSHomeDirectory()
        #else
            // `<root>/Applications/iGhostVT.app/ighostvt-cli`, the
            // `/usr/bin` symlink resolved: `<root>` is the jbroot under
            // roothide and what `/var/jb` resolves to under rootless.
            let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
            let root = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let rootless = URL(fileURLWithPath: "/var/jb").resolvingSymlinksInPath()
            if root.standardizedFileURL.path == rootless.standardizedFileURL.path {
                return "/var/mobile"
            }
            return root.appendingPathComponent("var/mobile").path
        #endif
    }

    /// The relay the app uses; nil for none, or for a file it would not
    /// read either.
    static func relay() -> RelayConfiguration? {
        guard let data = FileManager.default.contents(atPath: relayPath), data.count <= 64 * 1024 else { return nil }
        return try? RelayConfiguration(data: data)
    }

    /// The id this device pairs and connects under, as the app keeps it;
    /// made and kept for the app when it has never paired.
    static func deviceID() -> String {
        if let id = preference("Remote.deviceID") {
            return id
        }
        // Every pairing carries it, should the preference be out of reach.
        if let id = PairedHostFile.read(at: pairedHostsURL).hosts.first?.deviceID {
            return id
        }
        let made = UUID().uuidString
        CFPreferencesSetAppValue("Remote.deviceID" as CFString, made as CFString, preferencesDomain)
        CFPreferencesAppSynchronize(preferencesDomain)
        return made
    }

    /// The name the app introduces this device by, nil when it has never
    /// said: a hello without one leaves the host's name for the device as
    /// it is, where a name of the CLI's own would rename it back and forth.
    static func deviceName() -> String? {
        preference("Remote.deviceName") ?? preference("Remote.systemDeviceName")
    }

    /// This device's own host id, which is never a host to pair with.
    static func ownHostID() -> String? {
        preference("Remote.ownHostID")
    }

    private static func preference(_ key: String) -> String? {
        (CFPreferencesCopyAppValue(key as CFString, preferencesDomain) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Remote access runs as the user the app runs as; root would read and
    /// write another account's keys, and on the Mac is no client at all.
    static func requireUser() throws {
        guard getuid() != 0 else { throw CLIError.remoteAsRoot }
    }
}

/// Which paired host a `--host` names: its id, its name (or the nickname
/// the app gave it), the address it last answered at, or the start of its
/// id — in that order, the first kind that names exactly one winning.
enum HostSelector {
    static func resolve(_ selector: String, in hosts: [PairedRemoteHost]) throws -> PairedRemoteHost {
        guard !hosts.isEmpty else { throw CLIError.noPairedHosts }
        let wanted = selector.lowercased()
        let rules: [(PairedRemoteHost) -> Bool] = [
            { $0.id.lowercased() == wanted },
            { $0.displayName.lowercased() == wanted || $0.name.lowercased() == wanted },
            { $0.lastAddress == selector },
            { wanted.count >= 4 && $0.id.lowercased().hasPrefix(wanted) },
        ]
        for rule in rules {
            let matches = hosts.filter(rule)
            if matches.count == 1 {
                return matches[0]
            }
            if matches.count > 1 {
                throw CLIError.hostAmbiguous(selector, matches.map { "\($0.displayName) (\($0.id))" })
            }
        }
        throw CLIError.hostNotPaired(selector)
    }
}
