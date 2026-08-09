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
