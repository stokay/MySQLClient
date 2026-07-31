import Foundation
import MySQLNIO

/// Bundles everything a statement needs to reach the query history — the
/// store, which connection profile it belongs to, and whether the user has
/// history switched on — so the ten places that run SQL on the user's
/// behalf can log with one call instead of each carrying three properties.
///
/// Optional at every call site: a view model built without one (tests, or
/// a console with no profile behind it) simply doesn't record.
@MainActor
struct QueryHistoryRecorder {
    let store: QueryHistoryStore
    let profileID: UUID
    /// Read per statement rather than captured once, so toggling the
    /// setting takes effect immediately; injectable so tests don't depend
    /// on the user's real settings.json.
    var isEnabled: @MainActor () -> Bool = { SettingsStore.shared.settings.editor.saveQueryHistory }

    func record(
        _ sql: String,
        binds: [MySQLData] = [],
        database: String? = nil,
        source: QueryHistoryEntry.Source
    ) {
        guard isEnabled() else { return }
        store.record(
            SQLStatementRenderer.render(sql, binds: binds),
            profileID: profileID,
            database: database,
            source: source
        )
    }

    func entries() -> [QueryHistoryEntry] {
        store.entries(for: profileID)
    }

    func clear() {
        store.clear(profileID: profileID)
    }
}
