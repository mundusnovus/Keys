// The settings a person changes, on this device and (for the visual ones) across devices through iCloud
// key-value storage. Small values only; nothing secret ever goes here.
import Foundation
import Observation
import SwiftUI

enum AutoLockDelay: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .immediately: "Immediately"
        case .thirtySeconds: "After 30 seconds"
        case .oneMinute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .fifteenMinutes: "After 15 minutes"
        }
    }

    var shortLabel: String {
        switch self {
        case .immediately: "Immediately"
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .fiveMinutes: "5 minutes"
        case .fifteenMinutes: "15 minutes"
        }
    }
}

enum ClipboardClear: Int, CaseIterable, Identifiable, Sendable {
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case never = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .thirtySeconds: "After 30 seconds"
        case .oneMinute: "After 1 minute"
        case .twoMinutes: "After 2 minutes"
        case .never: "Never"
        }
    }
}

enum GlassStyle: String, CaseIterable, Identifiable, Sendable {
    case frosted, clear

    var id: String { rawValue }
    var label: String { self == .frosted ? "Frosted" : "Clear" }
    var explanation: String {
        self == .frosted ? "Soft, opaque glass that keeps text easy to read." : "More transparent glass that shows the colour behind it."
    }
}

/// One observable source of truth for settings. The visual choices follow the person through iCloud KVS;
/// device-specific choices stay in UserDefaults so a Mac setting cannot surprise an iPhone.
@MainActor
@Observable
final class KeysPreferences {
    static let shared = KeysPreferences()

    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default

    var accent: AccentChoice {
        didSet { write("accent", accent.rawValue, cloud: true) }
    }

    var autoLock: AutoLockDelay {
        didSet { write("autoLock", String(autoLock.rawValue)) }
    }

    var clipboardClear: ClipboardClear {
        didSet { write("clipboardClear", String(clipboardClear.rawValue)) }
    }

    var glassStyle: GlassStyle {
        didSet { write("glassStyle", glassStyle.rawValue, cloud: true) }
    }

    var biometricsEnabled: Bool {
        didSet { write("biometricsEnabled", String(biometricsEnabled)) }
    }

    var requireAuthToReveal: Bool {
        didSet { write("requireAuthToReveal", String(requireAuthToReveal)) }
    }

    var shareWithSiri: Bool {
        didSet { write("shareWithSiri", String(shareWithSiri)) }
    }

    var intelligenceEnabled: Bool {
        didSet { write("intelligenceEnabled", String(intelligenceEnabled)) }
    }

    var usePrivateCloudCompute: Bool {
        didSet { write("usePrivateCloudCompute", String(usePrivateCloudCompute)) }
    }

    var captureEnabled: Bool {
        didSet { write("captureEnabled", String(captureEnabled)) }
    }

    var securityCoachEnabled: Bool {
        didSet { write("securityCoachEnabled", String(securityCoachEnabled)) }
    }

    var smartSearchEnabled: Bool {
        didSet { write("smartSearchEnabled", String(smartSearchEnabled)) }
    }

    var showSiriTip: Bool {
        didSet { write("showSiriTip", String(showSiriTip)) }
    }

    private init() {
        cloud.synchronize()
        accent = Self.accentChoice(cloud.string(forKey: "accent") ?? defaults.string(forKey: "accent"))
        autoLock = AutoLockDelay(rawValue: Int(defaults.string(forKey: "autoLock") ?? "") ?? 60) ?? .oneMinute
        clipboardClear = ClipboardClear(rawValue: Int(defaults.string(forKey: "clipboardClear") ?? "") ?? 60) ?? .oneMinute
        glassStyle = GlassStyle(rawValue: cloud.string(forKey: "glassStyle") ?? defaults.string(forKey: "glassStyle") ?? "") ?? .frosted
        biometricsEnabled = defaults.bool(forKey: "biometricsEnabled")
        requireAuthToReveal = defaults.object(forKey: "requireAuthToReveal") as? Bool ?? false
        shareWithSiri = defaults.object(forKey: "shareWithSiri") as? Bool ?? true
        intelligenceEnabled = defaults.object(forKey: "intelligenceEnabled") as? Bool ?? true
        usePrivateCloudCompute = defaults.object(forKey: "usePrivateCloudCompute") as? Bool ?? true
        captureEnabled = defaults.object(forKey: "captureEnabled") as? Bool ?? true
        securityCoachEnabled = defaults.object(forKey: "securityCoachEnabled") as? Bool ?? true
        smartSearchEnabled = defaults.object(forKey: "smartSearchEnabled") as? Bool ?? true
        showSiriTip = defaults.object(forKey: "showSiriTip") as? Bool ?? true

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readCloudChanges() }
        }
    }

    /// A change made on another device. Validate every value: the other device may run an older build.
    private func readCloudChanges() {
        let newAccent = Self.accentChoice(cloud.string(forKey: "accent") ?? defaults.string(forKey: "accent"))
        if newAccent != accent { accent = newAccent }
        if let raw = cloud.string(forKey: "glassStyle"), let value = GlassStyle(rawValue: raw), value != glassStyle {
            glassStyle = value
        }
    }

    private func write(_ key: String, _ value: String, cloud: Bool = false) {
        defaults.set(value, forKey: key)
        if cloud { self.cloud.set(value, forKey: key) }
    }

    private static func accentChoice(_ raw: String?) -> AccentChoice {
        AccentChoice(rawValue: raw ?? "") ?? .sea
    }

    /// The glass style a person picked, as the type SwiftUI asks for.
    var glass: Glass {
        glassStyle == .frosted ? .regular : .clear
    }
}
