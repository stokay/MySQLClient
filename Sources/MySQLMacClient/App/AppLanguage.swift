import AppKit
import Foundation

/// In-app language override, mirroring `AppearanceMode`'s shape. Unlike
/// appearance, this one *does* carry a "follow the system" case: the
/// macOS-native default is to follow the system language, and forcing a
/// choice on first launch would be wrong for the majority of users whose
/// system language the app already supports.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case turkish = "tr"
    case english = "en"
    case spanish = "es"
    case german = "de"
    case hindi = "hi"
    case russian = "ru"
    case polish = "pl"

    var id: String { rawValue }

    /// Deliberately *not* localized: each option is written in its own
    /// language, the way macOS System Settings and every browser language
    /// picker does it. Someone who has accidentally set the app to a
    /// language they can't read still needs to find their way back, and a
    /// translated "İngilizce"/"English" pair wouldn't help them do that.
    /// `system` is the exception — it describes a behavior rather than
    /// naming a language, so it goes through the catalog.
    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .turkish: return "Türkçe"
        case .english: return "English"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .hindi: return "हिन्दी"
        case .russian: return "Русский"
        case .polish: return "Polski"
        }
    }

    /// The value written into `AppleLanguages`; `nil` means "remove the
    /// override and let the system decide".
    var localeCode: String? {
        self == .system ? nil : rawValue
    }
}

/// Persists the language override into `AppleLanguages`, the same
/// `UserDefaults` key macOS itself reads when resolving which `.lproj` a
/// bundle should load.
///
/// The change only takes effect on the next launch, and that is inherent
/// rather than a shortcut: `AppleLanguages` is read once while the process
/// is starting, before any of this app's code runs. Applying it live would
/// mean either swizzling `Bundle.localizedString(forKey:…)` or threading a
/// locale through every single `Text`, both of which are considerably more
/// fragile than asking the user to relaunch.
@MainActor
final class LanguageStore: ObservableObject {
    /// Apple's own key — not a name this app invented.
    private static let defaultsKey = "AppleLanguages"

    /// Set once at init to whatever was in effect *when the process
    /// started*, so the UI can tell whether the current selection is
    /// already live or still waiting for a relaunch.
    let languageAtLaunch: AppLanguage

    @Published var language: AppLanguage {
        didSet {
            guard let code = language.localeCode else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
                return
            }
            UserDefaults.standard.set([code], forKey: Self.defaultsKey)
        }
    }

    /// True once the user has picked something other than what the running
    /// process actually loaded — drives the "relaunch to apply" hint.
    var needsRelaunch: Bool { language != languageAtLaunch }

    /// Spawns a fresh instance of this same `.app` via `NSWorkspace` and
    /// terminates the running one — the standard macOS "relaunch to apply
    /// a setting" pattern. `AppleLanguages` was already written to
    /// `UserDefaults` by `language`'s `didSet` above, so the new process
    /// picks it up on its own at startup.
    ///
    /// Deliberately `NSWorkspace.openApplication`, not `Process` spawning
    /// `/usr/bin/open` directly: App Sandbox (the Release/DeveloperID
    /// configs both carry `com.apple.security.app-sandbox`) doesn't allow
    /// arbitrary child-process execution, only sanctioned system APIs like
    /// this one, which goes through Launch Services via XPC instead of a
    /// raw fork/exec.
    ///
    /// Only meaningful for a real `.app` bundle — under `swift run`,
    /// `Bundle.main.bundleURL` is just the build output directory, not an
    /// app bundle, so there is nothing valid to relaunch. Use
    /// `scripts/run-localized.sh` to test this for real.
    ///
    /// Terminates from *inside* the completion handler, not right after
    /// issuing the request: `openApplication` hands the launch off
    /// asynchronously, and terminating immediately after the call — before
    /// that request actually reached Launch Services — killed this process
    /// without ever spawning the new one. The handler only fires once the
    /// new instance has actually launched, which is exactly when it's safe
    /// to quit this one.
    ///
    /// `createsNewApplicationInstance = true` is the fix for a second,
    /// nastier bug found the same way (via `log stream`): `OpenConfiguration`
    /// defaults to *reusing* an already-running instance
    /// (`_kLSOpenOptionPreferRunningInstanceKey = 1`, confirmed in the log).
    /// Since the instance it found was this same still-running process,
    /// Launch Services just sent it a `reopen` Apple Event instead of
    /// spawning anything — the completion handler still fired (as far as
    /// it's concerned, the "open" succeeded), so this code proceeded to
    /// terminate the only instance that existed, and nothing was left
    /// running. Forcing a genuinely new instance is what actually launches
    /// a second process before this one exits.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    init() {
        // A stored override is an array whose first entry is the language;
        // anything else (never set, or set by macOS itself to the system
        // language list) counts as "follow the system".
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey)?.first
        let initial = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        languageAtLaunch = initial
        language = initial
    }
}
