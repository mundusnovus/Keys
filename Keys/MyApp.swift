import AppIntents
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@main
struct MyApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(KeysNotifications.self) private var notifications
    #elseif canImport(AppKit)
    @NSApplicationDelegateAdaptor(KeysNotifications.self) private var notifications
    #endif

    @State private var session = VaultSession(preferences: KeysPreferences.shared)
    @State private var preferences = KeysPreferences.shared

    init() {
        _ = BrandFont.isRegistered
        KeysShortcuts.updateAppShortcutParameters()
        KeysIntelligence.prewarm()
        #if DEBUG
        BiometricDiagnostics.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(session: session, preferences: preferences)
                .environment(preferences)
                .task {
                    KeysRuntime.attach(session)
                    await session.start()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Login") { session.newItemRequest = .login }
                    .keyboardShortcut("n")
                Button("New Secure Note") { session.newItemRequest = .note }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Card") { session.newItemRequest = .card }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandMenu("Vault") {
                Button("Lock Vault") { session.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Sync Now") { Task { await session.syncNow() } }
                    .keyboardShortcut("r")
                Divider()
                Button("Find in Keys") { session.searchRequest = "" }
                    .keyboardShortcut("f")
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(session)
                .environment(preferences)
        }
        #endif
    }
}

#if canImport(UIKit)
final class KeysNotifications: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await KeysRuntime.session?.syncNow()
        return .newData
    }
}
#elseif canImport(AppKit)
final class KeysNotifications: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await KeysRuntime.session?.syncNow() }
    }
}
#endif
