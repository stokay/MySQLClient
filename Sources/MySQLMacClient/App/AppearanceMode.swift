import SwiftUI
import AppKit

/// User-chosen appearance, independent of the macOS system setting — the
/// user asked for an in-app override rather than just following System
/// Settings' Light/Dark toggle, and explicitly just Açık/Koyu, no "follow
/// system" third option.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var systemImage: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Reads the persisted choice directly from `UserDefaults`, for
    /// call sites (`AnalyticsService`) that need the current value without
    /// holding a reference to the `@MainActor` `AppearanceStore` instance.
    /// Same key and fallback as `AppearanceStore.init()` — kept in sync by
    /// living right next to it.
    static var current: AppearanceMode {
        let raw = UserDefaults.standard.string(forKey: AppearanceStore.defaultsKey) ?? AppearanceMode.light.rawValue
        return AppearanceMode(rawValue: raw) ?? .light
    }
}

/// `.preferredColorScheme` (set from `mode.colorScheme`) covers SwiftUI's
/// own rendering; `NSApp.appearance` is set alongside it because the
/// custom `NSViewRepresentable` grids (`SpreadsheetGridView`,
/// `QueryResultGridView`, `SQLTextView`) and their semantic AppKit colors
/// (`.labelColor`, `.separatorColor`, etc.) resolve against the app's
/// effective appearance, not SwiftUI's environment.
@MainActor
final class AppearanceStore: ObservableObject {
    fileprivate nonisolated static let defaultsKey = "appearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultsKey)
            NSApp.appearance = mode.nsAppearance
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppearanceMode.light.rawValue
        let initialMode = AppearanceMode(rawValue: raw) ?? .light
        mode = initialMode
        NSApp.appearance = initialMode.nsAppearance
    }
}
