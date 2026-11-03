#if DEBUG
import Foundation
import LocalAuthentication

/// A launch-argument check for the keychain path that Face ID and Touch ID use.
///
/// Run with `-biometric-selftest`. The result is written beside the vault so a simulator run can prove
/// save → non-prompting probe → authenticated read → delete without opening the UI.
/// This never ships: the whole file is inside `#if DEBUG`.
@MainActor
enum BiometricDiagnostics {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-biometric-selftest") else { return }
        Task { await run() }
    }

    private static func run() async {
        var lines: [String] = []
        let key = VaultCrypto.randomBytes(32)
        let context = LAContext()
        context.localizedFallbackTitle = "Cancel"
        do {
            DeviceKey.delete()
            lines.append("delete=\(DeviceKey.state)")
            try DeviceKey.save(key)
            lines.append("save=ok")
            lines.append("probe=\(DeviceKey.state)")
            let loaded = try DeviceKey.load(context: context)
            lines.append(loaded == key ? "load=ok" : "load=mismatch")
            lines.append("afterLoad=\(DeviceKey.state)")
            DeviceKey.delete()
            lines.append("deleteAfter=\(DeviceKey.state)")
        } catch {
            lines.append("error=\(error.localizedDescription)")
            lines.append("state=\(DeviceKey.state)")
        }
        let url = VaultDisk.directory.appendingPathComponent("biometric-selftest.txt")
        try? FileManager.default.createDirectory(at: VaultDisk.directory, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        print("BIOMETRIC-SELFTEST\n" + lines.joined(separator: "\n"))
    }
}
#endif
