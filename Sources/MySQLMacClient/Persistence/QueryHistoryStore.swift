import Foundation

/// Persists the SQL console's query history as JSON under Application
/// Support, keyed by `ConnectionProfile.id` so each saved connection keeps
/// its own list. Same file-per-concern pattern as `ConnectionStore` /
/// `SettingsStore`; nothing here ever leaves the machine.
///
/// A single shared instance backs the whole app (`shared`) so every window
/// sees the same list, with `fileURL` injectable for tests.
@MainActor
final class QueryHistoryStore: ObservableObject {
    static let shared = QueryHistoryStore()

    /// Per profile. Newest first — the order the history menu shows.
    @Published private(set) var entriesByProfile: [UUID: [QueryHistoryEntry]] = [:]

    /// Older entries are dropped past this. Deliberately per profile, not
    /// global: a rarely-used connection shouldn't have its history evicted
    /// by a busy one.
    /// Raised from 200 once app-generated statements (cell edits, row
    /// inserts/deletes, DDL) started being recorded alongside typed
    /// queries: a busy editing session would otherwise evict the queries
    /// the user actually wrote.
    static let maximumEntriesPerProfile = 500

    /// Entries longer than this aren't recorded at all. `save()` re-encodes
    /// and rewrites the *whole* profile's list to disk on every `record()`
    /// call, so one many-megabyte entry (confirmed real case: a ~15.7MB
    /// pasted SQL dump) would make every subsequent query — not just this
    /// one — pay for a multi-megabyte JSON encode and disk write on the
    /// main actor. A history entry that large also isn't something anyone
    /// picks out of a menu and re-runs anyway.
    static let maximumRecordedSQLLength = 200_000

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Görünen addan bağımsız, sabit veri klasörü — gerekçe için
            // `ConnectionStore`'daki nota bakın.
            let directory = appSupport.appendingPathComponent("MySQLMacClient", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("query_history.json")
        }
        load()
    }

    func entries(for profileID: UUID) -> [QueryHistoryEntry] {
        entriesByProfile[profileID] ?? []
    }

    /// Records a query that was *sent* — successful or not, since a query
    /// that failed on a typo is exactly the one worth recalling to fix.
    /// Re-running the query that's already newest just moves its timestamp
    /// forward instead of filling the list with duplicates.
    ///
    /// Whether history is kept at all is the caller's call (see
    /// `SQLConsoleViewModel`); this stays a plain persistence layer so it
    /// can be tested without reaching for the settings singleton.
    func record(
        _ sql: String,
        profileID: UUID,
        database: String? = nil,
        source: QueryHistoryEntry.Source = .console,
        at date: Date = Date()
    ) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumRecordedSQLLength else { return }

        var entries = entriesByProfile[profileID] ?? []
        if let first = entries.first, first.sql == trimmed, first.source == source {
            entries[0].executedAt = date
            entries[0].database = database
        } else {
            entries.insert(QueryHistoryEntry(sql: trimmed, executedAt: date, database: database, source: source), at: 0)
            if entries.count > Self.maximumEntriesPerProfile {
                entries.removeLast(entries.count - Self.maximumEntriesPerProfile)
            }
        }
        entriesByProfile[profileID] = entries
        save()
    }

    func clear(profileID: UUID) {
        entriesByProfile[profileID] = nil
        save()
    }

    func clearAll() {
        entriesByProfile = [:]
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entriesByProfile = (try? JSONDecoder().decode([UUID: [QueryHistoryEntry]].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entriesByProfile) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
