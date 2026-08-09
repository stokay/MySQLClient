import Foundation

enum CreateTableError: Error, LocalizedError {
    case emptyTableName
    case noColumns
    case invalidLength(column: String, value: String)
    case noChanges

    var errorDescription: String? {
        switch self {
        case .emptyTableName:
            return String(localized: "Table name cannot be empty.")
        case .noColumns:
            return String(localized: "You must add at least one column.")
        case .invalidLength(let column, let value):
            return String(localized: "Invalid length for column \"\(column)\": \(value)")
        case .noChanges:
            return String(localized: "No changes were made.")
        }
    }
}

/// Backs the "Yeni Tablo" form: a SQLyog-style column grid that's translated
/// into a single `CREATE TABLE` statement and executed against the chosen
/// database. The column grid rows are the shared `DraftColumn` model — the
/// Alter Table form uses the same rows seeded from the live schema.
@MainActor
final class CreateTableViewModel: ObservableObject {
    static let dataTypes = [
        "INT", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "FLOAT", "DOUBLE",
        "VARCHAR", "CHAR", "TEXT", "MEDIUMTEXT", "LONGTEXT",
        "DATE", "DATETIME", "TIMESTAMP", "TIME", "BOOLEAN", "JSON", "BLOB",
    ]
    static let engines = ["[default]", "InnoDB", "MyISAM", "MEMORY", "ARCHIVE", "CSV"]

    @Published var tableName: String = ""
    @Published var database: String
    @Published var engine: String = "[default]"
    /// Reloads `collationOptions` for the newly picked charset — the two are
    /// server-defined pairs, not an independent cross product, so switching
    /// charset without refiltering would let the user pick a nonsense
    /// combination `CREATE TABLE` would reject.
    @Published var charset: String = "[default]" {
        didSet {
            guard charset != oldValue else { return }
            Task { await loadCollationOptions() }
        }
    }
    @Published var collation: String = "[default]"
    @Published var columns: [DraftColumn]

    /// Populated from the server (`SHOW CHARACTER SET`/`SHOW COLLATION`)
    /// rather than a hardcoded handful of names — real servers offer far
    /// more than any static list would cover.
    @Published private(set) var charsetOptions: [String] = ["[default]"]
    @Published private(set) var collationOptions: [String] = ["[default]"]

    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?

    /// Live `CREATE TABLE` text for the "SQL Önizleme" section — recomputed
    /// on every access (cheap: local string building, no I/O), so it always
    /// reflects the current form state without needing its own `@Published`
    /// wiring to every field it depends on.
    var previewSQL: String {
        (try? buildSQL()) ?? String(localized: "-- SQL will appear here once you enter a table name and at least one column name --")
    }

    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    /// Logs the DDL this form runs into the connection's query history.
    private let historyRecorder: QueryHistoryRecorder?

    init(service: MySQLService, defaultDatabase: String, historyRecorder: QueryHistoryRecorder? = nil) {
        self.service = service
        self.historyRecorder = historyRecorder
        self.introspection = SchemaIntrospectionService(service: service)
        self.database = defaultDatabase
        self.columns = (0..<3).map { _ in DraftColumn() }
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
        !tableName.trimmingCharacters(in: .whitespaces).isEmpty
            && !database.trimmingCharacters(in: .whitespaces).isEmpty
            && columns.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            && !isSubmitting
    }

    /// Builds and runs the `CREATE TABLE` statement; returns the created
    /// table's info on success so the caller can refresh the sidebar and
    /// jump straight to it.
    func submit() async -> TableInfo? {
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
            historyRecorder?.record(sql, database: database, source: .app)
            try await service.execute(sql)
        } catch {
            errorMessage = String(localized: "Could not create table: \(error.localizedDescription)")
            return nil
        }

        return TableInfo(database: database, name: tableName.trimmingCharacters(in: .whitespaces), isView: false)
    }

    private func buildSQL() throws -> String {
        let trimmedName = tableName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw CreateTableError.emptyTableName }
        let qualifiedTable = try SchemaIntrospectionService.qualifiedIdentifier(database: database, name: trimmedName)

        let activeColumns = columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !activeColumns.isEmpty else { throw CreateTableError.noColumns }

        var columnClauses: [String] = []
        var primaryKeyColumns: [String] = []

        for column in activeColumns {
            columnClauses.append(try column.sqlDefinition())
            if column.isPrimaryKey {
                let name = column.name.trimmingCharacters(in: .whitespaces)
                primaryKeyColumns.append(try SchemaIntrospectionService.quotedIdentifier(name))
            }
        }

        if !primaryKeyColumns.isEmpty {
            columnClauses.append("PRIMARY KEY (\(primaryKeyColumns.joined(separator: ", ")))")
        }

        var sql = "CREATE TABLE \(qualifiedTable) (\n  \(columnClauses.joined(separator: ",\n  "))\n)"

        var tableOptions: [String] = []
        if engine != "[default]" { tableOptions.append("ENGINE=\(engine)") }
        if charset != "[default]" { tableOptions.append("DEFAULT CHARSET=\(charset)") }
        if collation != "[default]" { tableOptions.append("COLLATE=\(collation)") }
        if !tableOptions.isEmpty {
            sql += " " + tableOptions.joined(separator: " ")
        }

        return sql
    }
}
