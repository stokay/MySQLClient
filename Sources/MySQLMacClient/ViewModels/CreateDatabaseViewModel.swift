import Foundation

enum CreateDatabaseError: Error, LocalizedError {
    case emptyDatabaseName

    var errorDescription: String? {
        switch self {
        case .emptyDatabaseName:
            return String(localized: "Database name cannot be empty.")
        }
    }
}

/// Backs the root sidebar row's "Create Database..." form — the sidebar's
/// only action that isn't scoped to an existing database. Charset/collation
/// follow the same server-driven, reactive pattern as `CreateTableViewModel`
/// (switching charset re-filters collation options, since the two are
/// server-defined pairs, not an independent cross product).
@MainActor
final class CreateDatabaseViewModel: ObservableObject {
    @Published var databaseName: String = ""
    @Published var charset: String = "[default]" {
        didSet {
            guard charset != oldValue else { return }
            Task { await loadCollationOptions() }
        }
    }
    @Published var collation: String = "[default]"

    @Published private(set) var charsetOptions: [String] = ["[default]"]
    @Published private(set) var collationOptions: [String] = ["[default]"]

    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?

    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    private let historyRecorder: QueryHistoryRecorder?

    init(service: MySQLService, historyRecorder: QueryHistoryRecorder? = nil) {
        self.service = service
        self.historyRecorder = historyRecorder
        self.introspection = SchemaIntrospectionService(service: service)
    }

    func loadCharsetOptions() async {
        if let sets = try? await introspection.characterSets() {
            charsetOptions = ["[default]"] + sets
        }
        await loadCollationOptions()
    }

    private func loadCollationOptions() async {
        let filterCharset = charset == "[default]" ? nil : charset
        guard let collations = try? await introspection.collations(forCharset: filterCharset) else { return }
        collationOptions = ["[default]"] + collations
        if !collationOptions.contains(collation) {
            collation = "[default]"
        }
    }

    var canSubmit: Bool {
        !databaseName.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    /// Builds and runs the `CREATE DATABASE` statement; returns the created
    /// database's name on success so the caller can refresh the sidebar.
    func submit() async -> String? {
        errorMessage = nil
        let sql: String
        do {
            sql = try buildSQL()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        isSubmitting = true
        defer { isSubmitting = false }
        do {
            historyRecorder?.record(sql, source: .app)
            try await service.execute(sql)
            AnalyticsService.trackFeatureUsed("create_database")
        } catch {
            errorMessage = String(localized: "Could not create database: \(error.localizedDescription)")
            AnalyticsService.trackError(error, feature: "create_database")
            return nil
        }

        return databaseName.trimmingCharacters(in: .whitespaces)
    }

    private func buildSQL() throws -> String {
        let trimmedName = databaseName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw CreateDatabaseError.emptyDatabaseName }
        let quoted = try SchemaIntrospectionService.quotedIdentifier(trimmedName)

        var sql = "CREATE DATABASE \(quoted)"
        if charset != "[default]" { sql += " CHARACTER SET \(charset)" }
        if collation != "[default]" { sql += " COLLATE \(collation)" }
        return sql
    }
}
