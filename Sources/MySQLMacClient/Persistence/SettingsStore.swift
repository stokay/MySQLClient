import Foundation

/// Persists `AppSettings` as JSON under Application Support, mirroring
/// `ConnectionStore`'s pattern. The app-level `@StateObject` wraps
/// `SettingsStore.shared` — the singleton exists because the AppKit-side
/// drawing code (`ColoredHeaderCell.draw`, `SelectedColorRowView`, the
/// `NSColor` dynamic providers) has no path to the SwiftUI environment.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { save() }
    }

    private let fileURL: URL

    /// `fileURL` is injectable for tests; production uses
    /// `~/Application Support/MySQL Client/settings.json`.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let directory = appSupport.appendingPathComponent("MySQL Client", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("settings.json")
        }

        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .defaults
        }
    }

    func resetToDefaults() {
        settings = .defaults
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
