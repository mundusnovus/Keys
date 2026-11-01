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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 720)
        #endif
        .commands {
            CommandMenu("Vault") {
                Button("Lock Vault") { KeysRuntime.session?.lock() }
                    .keyboardShortcut("L", modifiers: [.command, .shift])
            }
        }
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
