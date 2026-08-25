import SwiftUI
import AppKit

/// Manages app lifecycle. A proper .app bundle (Xcode/App Store build) gets
/// its activation policy from Info.plist; a bare SPM executable
/// (`swift run`) does NOT — without the manual activation below its window
/// draws and takes clicks, but keyboard focus stays with whatever app was
/// frontmost before launch (e.g. the IDE) and every keystroke leaks there.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bundle check keeps this a no-op for the .app builds while
        // restoring keyboard input for `swift run` development builds.
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        AnalyticsService.trackAppOpen()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Only when nothing is key yet (the launch case) — unconditionally
        // fronting the first window here would yank focus away from the
        // Ayarlar window on every app re-activation.
        if NSApp.keyWindow == nil {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct MySQLMacClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var appState = AppState()
    @StateObject private var appearanceStore = AppearanceStore()
    @StateObject private var languageStore = LanguageStore()
    /// Wraps the shared singleton (AppKit drawing code reads
    /// `SettingsStore.shared` directly), observed here so SwiftUI reacts.
    @StateObject private var settingsStore = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if let session = appState.activeSession {
                    MainWindowView(session: session) {
                        Task { await appState.disconnect() }
                    }
                } else {
                    ConnectionFormView(connectionStore: connectionStore, appState: appState)
                }
            }
            .frame(minWidth: 800, minHeight: 560)
            .environmentObject(appearanceStore)
            .environmentObject(settingsStore)
            .preferredColorScheme(appearanceStore.mode.colorScheme)
            .toolbar {
                // Placed at the app root (not inside MainWindowView) so it
                // stays put as more items get added here later, regardless
                // of which screen (connection form vs. main window) is
                // showing. `.navigation` placement is what puts it at the
                // toolbar's leading edge.
                ToolbarItem(placement: .navigation) {
                    Button {
                        Task { await appState.disconnect() }
                    } label: {
                        Label {
                            Text("New Connection")
                        } icon: {
                            Image.bundled(
                                "new_connection",
                                fallbackSystemImage: "plus.circle",
                                pointSize: settingsStore.settings.general.toolbarIconSize
                            )
                        }
                    }
                    .help("New Connection")
                }
            }
        }

        // Environment/appearance must be re-attached here — a `Settings`
        // scene does not inherit the WindowGroup's modifiers.
        Settings {
            SettingsView()
                .environmentObject(appearanceStore)
                .environmentObject(settingsStore)
                .environmentObject(languageStore)
                .preferredColorScheme(appearanceStore.mode.colorScheme)
        }
    }
}
