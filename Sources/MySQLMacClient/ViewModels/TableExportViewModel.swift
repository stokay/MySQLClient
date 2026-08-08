import AppKit
import Foundation
import MySQLNIO

/// Backs the "Export..." sheet: independent of `TableDataViewModel` (and
/// therefore of whatever filter/sort/page the grid happens to have active)
/// — this always fetches the entire table, by design.
@MainActor
final class TableExportViewModel: ObservableObject {
    /// A single-table export has no object-count dimension the way a
    /// database backup does — just rows completed against the total,
    /// counted once up front via `SELECT COUNT(*)`.
    struct Progress: Equatable {
        var completedRows: Int
        var totalRows: Int
        var percentage: Double {
            guard totalRows > 0 else { return 0 }
            return min(1, Double(completedRows) / Double(totalRows))
        }
    }

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
    @Published private(set) var progress: Progress?
    @Published var errorMessage: String?
    /// Flips to `true` once the file is genuinely, atomically on disk
    /// (after `AtomicFileWriter`'s commit, or after `XLSXExporter.write`'s
    /// own atomic write, both already succeeded — never set on
    /// cancellation or failure), so the view can show a completion alert.
    /// A plain settable `@Published`, not `private(set)`: SwiftUI's
    /// `.alert(isPresented:)` needs a two-way binding and sets this back to
    /// `false` itself once the alert is dismissed.
    @Published var didFinishSuccessfully = false

    /// Zero in production (no behavior change); overridable only by the
    /// cancellation test, so it can deterministically catch a running
    /// export mid-page instead of racing a near-instant export against a
    /// tiny seed table — same pattern as `DatabaseBackupViewModel
    /// .interObjectDelay`.
    var interPageDelay: Duration = .zero
    /// Rows fetched per round trip — same purpose as `DatabaseBackupViewModel
    /// .dataPageSize`. Settable so paging tests can force a page boundary
    /// with a handful of rows instead of inserting thousands.
    var fetchPageSize = 1000
    /// Defaults to the format's real ceiling (`XLSXExporter
    /// .maxRowsPerSheet`); settable so a test can shrink it instead of
    /// having to seed over a million rows to exercise the guard.
    var xlsxRowLimit = XLSXExporter.maxRowsPerSheet

    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    private var exportTask: Task<Void, Never>?

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

    // MARK: - Running the export

    /// Owns its own `Task` rather than being launched from the view's own
    /// `Task { }`, because cancellation must be reachable from a
    /// *different* button ("Kapat") than the one that started it ("Dışa
    /// Aktar") — same design as `DatabaseBackupViewModel.startBackup`.
    func startExport() {
        guard !isExporting else { return }
        // Set synchronously, before the task is even scheduled — a `Task {}`
        // body doesn't necessarily begin running before control returns
        // here, so flipping this inside `performExport` would leave a
        // window where `isExporting` is still false long enough for a
        // second tap to start a competing export over the same file.
        isExporting = true
        errorMessage = nil
        exportTask = Task { [self] in await performExport() }
    }

    /// Called from "Kapat" while running. Doesn't block on completion —
    /// cancellation and cleanup happen inside `performExport` itself
    /// (via `AtomicFileWriter`, which discards its temp file and leaves
    /// whatever was at `outputFileURL` untouched), which is allowed to keep
    /// running briefly after the sheet dismisses.
    func cancelExport() {
        exportTask?.cancel()
    }

    private func performExport() async {
        defer { isExporting = false; exportTask = nil }

        guard let outputFileURL else { return }
        let exportColumns = allColumns.filter { selectedColumnNames.contains($0.name) }
        guard !exportColumns.isEmpty else { return }

        let totalRows = (try? await rowCount()) ?? 0
        progress = Progress(completedRows: 0, totalRows: totalRows)

        do {
            switch options.format {
            case .csv:
                try await AtomicFileWriter.write(to: outputFileURL) { fileHandle in
                    try await self.streamCSV(columns: exportColumns, to: fileHandle)
                }
            case .html:
                try await AtomicFileWriter.write(to: outputFileURL) { fileHandle in
                    try await self.streamHTML(columns: exportColumns, to: fileHandle)
                }
            case .json:
                try await AtomicFileWriter.write(to: outputFileURL) { fileHandle in
                    try await self.streamJSON(columns: exportColumns, to: fileHandle)
                }
            case .sql where table.isView:
                // `SHOW CREATE TABLE` on a view doesn't fail — it silently
                // redirects to the view's own definition, but under a
                // `Create View` column instead of `Create Table`, which is
                // why this has its own branch rather than falling through
                // to the table path below. A view has no data of its own,
                // so this is the whole export — no streaming needed.
                try await AtomicFileWriter.write(to: outputFileURL) { fileHandle in
                    let rawDDL = try await self.introspection.showCreateView(self.table.name, inDatabase: self.table.database)
                    let createViewSQL = SQLExporter.createViewStatement(rawShowCreateView: rawDDL)
                    fileHandle.write(Data((createViewSQL + "\n").utf8))
                }
            case .sql:
                try await AtomicFileWriter.write(to: outputFileURL) { fileHandle in
                    try await self.streamSQL(columns: exportColumns, to: fileHandle)
                }
            case .xlsx:
                // Checked before any fetch — not just before the write —
                // because a table over the limit (a real 1.15M-row one hit
                // this) would otherwise burn through the whole fetch first
                // only to fail at the very end. Excel's row ceiling is a
                // property of the file format, not something this app can
                // relax: past it, Excel doesn't just refuse the file, it
                // silently "recovers" (truncates) it, which is worse than
                // failing loudly up front.
                let maxDataRows = xlsxRowLimit - 1 // one row reserved for the header this call always writes
                guard totalRows <= maxDataRows else {
                    errorMessage = "Bu tablo (\(totalRows) satır) Excel'in \(maxDataRows) satır sınırını aşıyor. Lütfen CSV, SQL ya da HTML formatını kullanın."
                    progress = nil
                    return
                }
                // `.xlsx` is a zip archive built from complete XML parts —
                // it genuinely can't be streamed row-by-row to disk, so the
                // fetch still accumulates every row here before the one
                // atomic write at the end. `XLSXExporter.write` already
                // performs its own safe temp-then-.atomic write via
                // `Data.write(to:options:.atomic)`, so it does NOT go
                // through `AtomicFileWriter` — it doesn't need it and
                // already isn't the buggy direct-FileHandle pattern that
                // did. Progress still moves during the fetch, so a huge
                // table isn't a silent, indefinite wait even though the
                // final write itself is one unwatched step.
                let rows = try await fetchAllRowsReportingProgress(columns: exportColumns)
                try Task.checkCancellation()
                try XLSXExporter.write(columns: exportColumns, rows: rows, includeHeaderRow: true, to: outputFileURL)
            }
            progress?.completedRows = progress?.totalRows ?? 0
            didFinishSuccessfully = true
        } catch is CancellationError {
            // User-initiated — not an error to surface.
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Paging

    /// Keyset-paginates by primary key when the table has one *and* every
    /// key column is among the checked export columns — a PK column the
    /// user deliberately unchecked isn't in the `SELECT` list, so there's
    /// nothing to extract a "last value" from. Falls back to `OFFSET` in
    /// that case, same as a table with no primary key at all — that's the
    /// slow path, but it's rare and keeps this from having to fetch PK
    /// columns nobody asked for just to strip them back out.
    ///
    /// Same technique as `DatabaseBackupViewModel.dumpTableData`: pages by
    /// `WHERE (pk) > (lastPage'sLastPKValues) ORDER BY pk`, not `OFFSET n`,
    /// because `OFFSET` makes the server walk and discard all n preceding
    /// rows on every page — measured 44x slower than a key range on a deep
    /// page against this project's own test server.
    private func fetchPages(
        columns: [ColumnInfo],
        onPage: @MainActor ([[RowValue]]) async throws -> Void
    ) async throws {
        let qualifiedTable = try SchemaIntrospectionService.qualifiedIdentifier(database: table.database, name: table.name)
        let columnList = try columns.map { try SchemaIntrospectionService.quotedIdentifier($0.name) }.joined(separator: ", ")
        let keyColumns = allColumns.filter(\.isPrimaryKey)
        let quotedKeyList = try keyColumns.map { try SchemaIntrospectionService.quotedIdentifier($0.name) }.joined(separator: ", ")
        let keyIndexes = keyColumns.compactMap { key in columns.firstIndex { $0.name == key.name } }
        let canSeekByKey = !keyColumns.isEmpty && keyIndexes.count == keyColumns.count

        var lastKeyValues: [RowValue]?
        var offset = 0
        while true {
            try Task.checkCancellation()
            var sql = "SELECT \(columnList) FROM \(qualifiedTable)"
            if canSeekByKey {
                if let lastKeyValues {
                    // Row-constructor comparison, so a composite key pages
                    // correctly as one ordered tuple rather than needing a
                    // hand-expanded chain of ORs.
                    let literals = lastKeyValues.map(SQLExporter.sqlLiteral).joined(separator: ", ")
                    sql += " WHERE (\(quotedKeyList)) > (\(literals))"
                }
                sql += " ORDER BY \(quotedKeyList)"
            }
            sql += " LIMIT \(fetchPageSize)"
            if !canSeekByKey {
                sql += " OFFSET \(offset)"
            }

            let mysqlRows = try await service.query(sql)
            guard !mysqlRows.isEmpty else { break }
            let rows: [[RowValue]] = mysqlRows.map { row in
                columns.map { column in row.column(column.name).map(RowValue.init(mysqlData:)) ?? .null }
            }
            try await onPage(rows)

            if canSeekByKey, let lastRow = rows.last {
                lastKeyValues = keyIndexes.map { lastRow[$0] }
            } else {
                offset += rows.count
            }
            if interPageDelay != .zero {
                try await Task.sleep(for: interPageDelay)
            }
            if mysqlRows.count < fetchPageSize { break }
        }
    }

    private func rowCount() async throws -> Int {
        let qualifiedTable = try SchemaIntrospectionService.qualifiedIdentifier(database: table.database, name: table.name)
        let rows = try await service.query("SELECT COUNT(*) AS cnt FROM \(qualifiedTable)")
        return rows.first?.column("cnt")?.int ?? 0
    }

    // MARK: - Per-format streaming

    private func streamCSV(columns: [ColumnInfo], to fileHandle: FileHandle) async throws {
        if options.csv.includeHeaderRow {
            fileHandle.write(Data(CSVExporter.formatHeader(columns.map(\.name), options: options.csv).utf8))
        }
        var completedRows = 0
        try await fetchPages(columns: columns) { rows in
            for row in rows {
                fileHandle.write(Data(CSVExporter.formatRow(row, options: self.options.csv).utf8))
            }
            completedRows += rows.count
            self.progress?.completedRows = completedRows
        }
    }

    private func streamHTML(columns: [ColumnInfo], to fileHandle: FileHandle) async throws {
        fileHandle.write(Data(HTMLExporter.documentHeader(tableName: table.name, columnNames: columns.map(\.name)).utf8))
        var completedRows = 0
        try await fetchPages(columns: columns) { rows in
            for row in rows {
                fileHandle.write(Data(HTMLExporter.formatRow(row).utf8))
            }
            completedRows += rows.count
            self.progress?.completedRows = completedRows
        }
        fileHandle.write(Data(HTMLExporter.documentFooter().utf8))
    }

    /// Comma placement matches the whole-array `JSONExporter.write(rows:)`
    /// byte-for-byte (`[\n{r0},\n{r1},\n{r2}\n]\n`), just computed without
    /// knowing the total row count up front: the separator goes *before*
    /// every row except the first, instead of after every row except the
    /// last — the last row isn't knowable until the next fetch comes back
    /// empty.
    private func streamJSON(columns: [ColumnInfo], to fileHandle: FileHandle) async throws {
        fileHandle.write(Data("[\n".utf8))
        var isFirstRow = true
        var completedRows = 0
        try await fetchPages(columns: columns) { rows in
            for row in rows {
                if !isFirstRow {
                    fileHandle.write(Data(",\n".utf8))
                }
                fileHandle.write(Data(JSONExporter.formatRow(columns, row).utf8))
                isFirstRow = false
            }
            completedRows += rows.count
            self.progress?.completedRows = completedRows
        }
        fileHandle.write(Data("\n]\n".utf8))
    }

    /// Inlines the per-row `INSERT` write instead of buffering the whole
    /// table into `SQLExporter.write(rows:)` the way this used to — the
    /// same OOM risk `DatabaseBackupViewModel.dumpTableData` was fixed for.
    /// No extended-insert option here (unlike DB Backup), so this keeps one
    /// `INSERT` per row, preserving the existing row-count assertions in
    /// `TableExportViewModelTests`.
    private func streamSQL(columns: [ColumnInfo], to fileHandle: FileHandle) async throws {
        let rawDDL = try await introspection.showCreateTable(table.name, inDatabase: table.database)
        let createTableSQL = SQLExporter.createTableStatement(rawShowCreateTable: rawDDL)
        fileHandle.write(Data((createTableSQL + "\n\n").utf8))

        var completedRows = 0
        try await fetchPages(columns: columns) { rows in
            for row in rows {
                let statement = SQLExporter.insertStatement(database: self.table.database, table: self.table.name, columns: columns, values: row)
                fileHandle.write(Data((statement + "\n").utf8))
            }
            completedRows += rows.count
            self.progress?.completedRows = completedRows
        }
    }

    private func fetchAllRowsReportingProgress(columns: [ColumnInfo]) async throws -> [[RowValue]] {
        var allRows: [[RowValue]] = []
        var completedRows = 0
        try await fetchPages(columns: columns) { rows in
            allRows.append(contentsOf: rows)
            completedRows += rows.count
            self.progress?.completedRows = completedRows
        }
        return allRows
    }

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }
}
