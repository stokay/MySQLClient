import AppKit
import Foundation
import MySQLNIO

/// Backs the "Export..." sheet: independent of `TableDataViewModel` (and
/// therefore of whatever filter/sort/page the grid happens to have active)
/// — this always fetches the entire table, by design.
@MainActor
final class TableExportViewModel: ObservableObject {
    let table: TableInfo

    /// Re-suffixes `outputFileURL` whenever the format tab changes, so the
    /// saved file's extension always matches what's about to be written —
    /// without this, switching from CSV to (say) SQL left the suggested
    /// path stuck on ".csv" while the file's actual contents were correct
    /// for the newly selected format.
    @Published var options = TableExportOptions() {
        didSet {
            guard oldValue.format != options.format, let outputFileURL else { return }
            self.outputFileURL = outputFileURL
                .deletingPathExtension()
                .appendingPathExtension(options.format.defaultFileExtension)
        }
    }
    @Published private(set) var allColumns: [ColumnInfo] = []
    @Published var selectedColumnNames: Set<String> = []
    @Published var outputFileURL: URL?
    @Published private(set) var isLoadingColumns = true
    @Published private(set) var isExporting = false
    @Published var errorMessage: String?

    private let service: MySQLService
    private let introspection: SchemaIntrospectionService

    init(service: MySQLService, table: TableInfo) {
        self.service = service
        self.table = table
        self.introspection = SchemaIntrospectionService(service: service)
    }

    /// Called from the sheet's `.task` on appearance. All columns start
    /// checked, and the "Save to file" field is pre-filled with a sensible
    /// default (Desktop/<table>.<format's extension>) so the user can hit
    /// Export immediately without having to browse first.
    func loadColumns() async {
        isLoadingColumns = true
        defer { isLoadingColumns = false }
        do {
            allColumns = try await introspection.columns(forTable: table.name, inDatabase: table.database)
            selectedColumnNames = Set(allColumns.map(\.name))
            outputFileURL = defaultOutputURL()
        } catch {
            errorMessage = describe(error)
        }
    }

    func selectAllColumns() {
        selectedColumnNames = Set(allColumns.map(\.name))
    }

    func deselectAllColumns() {
        selectedColumnNames.removeAll()
    }

    private func defaultOutputURL() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return desktop.appendingPathComponent(table.name).appendingPathExtension(options.format.defaultFileExtension)
    }

    /// `NSApp.keyWindow` rather than a dedicated `NSViewRepresentable`
    /// window-accessor — simpler, and sufficient since the export sheet is
    /// always the key window when its own "..." button is the thing that
    /// was just clicked.
    func chooseOutputFile() {
        let panel = NSSavePanel()
        let seed = outputFileURL ?? defaultOutputURL()
        panel.nameFieldStringValue = seed.lastPathComponent
        panel.directoryURL = seed.deletingLastPathComponent()
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFileURL = url
    }

    /// Fetches every row of every checked column (ignoring any grid filter/
    /// sort/page — this is a table-level export, not a view of the grid),
    /// then hands them to the matching serializer. Returns `true` on
    /// success so the view can dismiss the sheet.
    @discardableResult
    func runExport() async -> Bool {
        guard let outputFileURL else { return false }
        let exportColumns = allColumns.filter { selectedColumnNames.contains($0.name) }
        guard !exportColumns.isEmpty else { return false }

        isExporting = true
        defer { isExporting = false }
        errorMessage = nil

        do {
            let rows = try await fetchRows(columns: exportColumns)

            FileManager.default.createFile(atPath: outputFileURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: outputFileURL)
            defer { try? fileHandle.close() }

            switch options.format {
            case .csv:
                try CSVExporter.write(columns: exportColumns, rows: rows, options: options.csv, to: fileHandle)
            case .html:
                try HTMLExporter.write(tableName: table.name, columns: exportColumns, rows: rows, to: fileHandle)
            case .json:
                try JSONExporter.write(columns: exportColumns, rows: rows, to: fileHandle)
            case .sql where table.isView:
                // `SHOW CREATE TABLE` on a view doesn't fail — it silently
                // redirects to the view's own definition, but under a
                // `Create View` column instead of `Create Table`, which is
                // why this has its own branch rather than falling through
                // to the table path below.
                let rawDDL = try await introspection.showCreateView(table.name, inDatabase: table.database)
                let createViewSQL = SQLExporter.createViewStatement(rawShowCreateView: rawDDL)
                fileHandle.write(Data((createViewSQL + "\n").utf8))
            case .sql:
                let rawDDL = try await introspection.showCreateTable(table.name, inDatabase: table.database)
                let createTableSQL = SQLExporter.createTableStatement(rawShowCreateTable: rawDDL)
                try SQLExporter.write(
                    database: table.database, table: table.name, createTableSQL: createTableSQL,
                    columns: exportColumns, rows: rows, to: fileHandle
                )
            case .xlsx:
                // Doesn't use `fileHandle` — a `.xlsx` is a zip archive, so
                // it can't be streamed the way the textual formats are; it
                // writes (and atomically replaces) `outputFileURL` itself.
                try XLSXExporter.write(columns: exportColumns, rows: rows, includeHeaderRow: true, to: outputFileURL)
            }
            return true
        } catch {
            errorMessage = describe(error)
            return false
        }
    }

    /// `SELECT` only the checked columns, in their display order — this
    /// both avoids fetching columns nobody wants and guarantees the row
    /// arrays line up with `exportColumns` for free.
    ///
    /// Fetched a page at a time for the same reason `DatabaseBackupViewModel
    /// .dumpTableData` does: one un-LIMITed `SELECT` over a very large table
    /// makes the server hold (and ship) the whole result at once, which is
    /// what dropped the connection on a real multi-million-row table. Note
    /// this bounds the *server* side only — every page still accumulates
    /// here, because the format serializers take the complete row set (and
    /// `.xlsx`, being a zip, genuinely needs it all before it can write
    /// anything). Making the textual formats stream page-by-page to disk is
    /// a separate change.
    private func fetchRows(columns: [ColumnInfo]) async throws -> [[RowValue]] {
        let qualifiedTable = try SchemaIntrospectionService.qualifiedIdentifier(database: table.database, name: table.name)
        let columnList = try columns.map { try SchemaIntrospectionService.quotedIdentifier($0.name) }.joined(separator: ", ")
        let keyColumns = allColumns.filter(\.isPrimaryKey).map(\.name)
        // `LIMIT`/`OFFSET` across separate queries has no row-order
        // guarantee without an `ORDER BY` — without one, rows could repeat
        // or go missing between pages.
        let orderClause = keyColumns.isEmpty
            ? ""
            : " ORDER BY " + (try keyColumns.map { try SchemaIntrospectionService.quotedIdentifier($0) }.joined(separator: ", "))

        var rows: [[RowValue]] = []
        var offset = 0
        while true {
            let sql = "SELECT \(columnList) FROM \(qualifiedTable)\(orderClause) LIMIT \(Self.fetchPageSize) OFFSET \(offset)"
            let mysqlRows = try await service.query(sql)
            guard !mysqlRows.isEmpty else { break }
            rows.append(contentsOf: mysqlRows.map { row in
                columns.map { column in
                    row.column(column.name).map(RowValue.init(mysqlData:)) ?? .null
                }
            })
            offset += mysqlRows.count
            if mysqlRows.count < Self.fetchPageSize { break }
        }
        return rows
    }

    private static let fetchPageSize = 1000

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }
}
