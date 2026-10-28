//
//  NetworkAccess.swift
//  iGhostVT
//

import Foundation

/// The app's own network: CoreTelephony's per-app data policy, the switch
/// Settings calls Wireless Data — WLAN & Cellular on a device sold in China,
/// where it holds Wi-Fi as well as cellular. An app a package manager
/// installed is never asked about it, and where the system holds it denied,
/// everything the app dials fails as if there were no network: a paired
/// device, direct or through the relay, and Check for Updates. The policy is
/// keyed by bundle id, so it never binds the daemon or its helpers, which
/// are not apps — this device's own host side keeps working either way.
///
/// Once a launch, off the main thread, the app reads its policy and, unless
/// Wi-Fi and cellular are both allowed already, allows both, as Apelin
/// (`NetworkAccess`) and Irisin (`CellularPolicy`) do for themselves and
/// icli's `app network repair` does for another app; a change, or a refusal,
/// is in the journal. CoreTelephony asks for
/// `com.apple.CommCenter.fine-grained` (`spi`, `data-allowed-write`), which
/// the packager requires. Ghost Remote carries no entitlement and needs
/// none: installed as any other app is, it gets the system's own question.
enum NetworkAccess {
    private static let cellular = "kCTCellularDataUsagePolicy"
    private static let wifi = "kCTWiFiDataUsagePolicy"
    private static let alwaysAllow = "kCTCellularDataUsagePolicyAlwaysAllow"

    private typealias Create = @convention(c) (CFAllocator?, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFTypeRef>?
    private typealias CopyPolicy = @convention(c) (CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Int64
    private typealias SetPolicy = @convention(c) (CFTypeRef, CFString, CFDictionary) -> Int64

    static func start() {
        #if !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
            guard !AppEdition.isRemoteOnly, let bundleID = Bundle.main.bundleIdentifier else { return }
            DispatchQueue.global(qos: .utility).async {
                guard let outcome = allow(bundleID) else { return }
                if outcome.failed {
                    AppLog.warning(.app, outcome.note)
                } else {
                    AppLog.info(.app, outcome.note)
                }
            }
        #endif
    }

    /// What was changed or went wrong; nil when both were allowed already.
    private static func allow(_ bundleID: String) -> (failed: Bool, note: String)? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_NOW),
              let create = dlsym(handle, "_CTServerConnectionCreate"),
              let copy = dlsym(handle, "_CTServerConnectionCopyCellularUsagePolicy"),
              let set = dlsym(handle, "_CTServerConnectionSetCellularUsagePolicy")
        else { return (true, "data policy: CoreTelephony's calls are unavailable") }
        guard let connection = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault, nil, nil)?
            .takeRetainedValue()
        else { return (true, "data policy: CoreTelephony did not answer") }

        // a policy that cannot be read is written all the same, as Irisin does
        var copied: Unmanaged<CFDictionary>?
        let read = unsafeBitCast(copy, to: CopyPolicy.self)(connection, bundleID as CFString, &copied)
        let policy = read == 0 ? (copied?.takeRetainedValue() as? [String: Any]) ?? [:] : nil
        if let policy, policy[cellular] as? String == alwaysAllow, policy[wifi] as? String == alwaysAllow {
            return nil
        }
        let before = policy.map { "\($0)" } ?? "unreadable (\(read))"
        let wanted = [cellular: alwaysAllow, wifi: alwaysAllow] as CFDictionary
        let written = unsafeBitCast(set, to: SetPolicy.self)(connection, bundleID as CFString, wanted)
        guard written == 0 else {
            return (true, "data policy: \(before) could not be changed (\(written))")
        }
        return (false, "data policy: Wi-Fi and cellular data allowed; it was \(before)")
    }
}
