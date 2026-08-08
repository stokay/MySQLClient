import AppKit
import Foundation
import MySQLNIO
import UniformTypeIdentifiers

/// Backs the "Import..." sheet: reads a CSV file and `INSERT`s its rows
/// into `table`, entirely inside one transaction — either every row lands,
/// or (on any failed row, or user cancellation) none of them do.
@MainActor
final class TableImportViewModel: ObservableObject {
    struct Progress: Equatable {
        var completedRows: Int
        var totalRows: Int
        var percentage: Double {
            guard totalRows > 0 else { return 0 }
            return min(1, Double(completedRows) / Double(totalRows))
        }
    }

    /// One column found in the source file's header (or, when there's no
    /// header row, a positional "Kolon N" placeholder). `id` is the
    /// column's index in the file, not a stable identity across re-parses,
    /// but the mapping UI only ever exists alongside one loaded mapping.
    struct ColumnMapping: Identifiable, Equatable {
        let id: Int
        let sourceHeaderName: String
        var targetColumnName: String?
    }

    let table: TableInfo

    @Published var csvOptions = CSVImportParser.Options()
    @Published var hasHeaderRow = true
    @Published var sourceFileURL: URL?
    @Published private(set) var allColumns: [ColumnInfo] = []
    @Published private(set) var isLoadingColumns = true
    @Published var columnMappings: [ColumnMapping] = []
    @Published private(set) var isImporting = false
    @Published private(set) var progress: Progress?
    @Published var errorMessage: String?
    /// Flips to `true` only after `COMMIT` genuinely succeeds — never on a
    /// cancelled or rolled-back run. Plain settable `@Published`, not
    /// `private(set)`, because SwiftUI's `.alert(isPresented:)` needs a
    /// two-way binding and resets this itself once dismissed.
    @Published var didFinishSuccessfully = false

    /// How many rows are scanned to detect the file's column count —
    /// deliberately small so choosing a multi-gigabyte file doesn't stall
    /// the sheet. Only the header row matters for a well-formed CSV; a few
    /// extra data rows are scanned too so a ragged file (more columns in
    /// the data than the header) still gets every column mappable.
    let columnDetectionRowLimit = 10

    /// Zero in production; overridable only by the cancellation test, so it
    /// can deterministically catch a running import mid-batch — same
    /// pattern as `TableExportViewModel.interPageDelay`.
    var interBatchDelay: Duration = .zero
    /// Rows per `INSERT` statement. Settable so paging/rollback tests can
    /// force multiple batches with a handful of rows instead of seeding
    /// thousands — same purpose as `TableExportViewModel.fetchPageSize`.
    var insertBatchSize = 500

    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    private var importTask: Task<Void, Never>?

    init(service: MySQLService, table: TableInfo) {
        self.service = service
        self.table = table
        self.introspection = SchemaIntrospectionService(service: service)
    }

    func loadColumns() async {
        isLoadingColumns = true
        defer { isLoadingColumns = false }
        do {
            allColumns = try await introspection.columns(forTable: table.name, inDatabase: table.database)
        } catch {
            errorMessage = describe(error)
        }
    }

    /// `NSApp.keyWindow` rather than a dedicated `NSViewRepresentable`
    /// window-accessor — same reasoning as `TableExportViewModel
    /// .chooseOutputFile`: the import sheet is always the key window when
    /// its own "..." button is what was just clicked.
    func chooseSourceFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceFileURL = url
        Task { await refreshColumnMappings() }
    }

    /// Re-reads just the first `columnDetectionRowLimit` rows of
    /// `sourceFileURL` and re-derives `columnMappings` — called after a
    /// new file is chosen and whenever the view's CSV option controls
    /// change, so the auto-mapping always reflects the options currently
    /// on screen.
    func refreshColumnMappings() async {
        columnMappings = []
        guard let sourceFileURL else { return }
        errorMessage = nil
        do {
            let fileHandle = try FileHandle(forReadingFrom: sourceFileURL)
            defer { try? fileHandle.close() }
            let rowsToRead = columnDetectionRowLimit + (hasHeaderRow ? 1 : 0)
            let rows = try await CSVImportParser.preview(fileHandle: fileHandle, options: csvOptions, limit: rowsToRead)
            guard !rows.isEmpty else { return }

            let headerRow = hasHeaderRow ? rows[0] : nil
            let columnCount = rows.map(\.count).max() ?? 0
            columnMappings = (0..<columnCount).map { index in
                let sourceHeaderName = (headerRow?.indices.contains(index) == true) ? headerRow![index] : "Kolon \(index + 1)"
                let normalized = sourceHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let match = allColumns.first { $0.name.lowercased() == normalized }
                return ColumnMapping(id: index, sourceHeaderName: sourceHeaderName, targetColumnName: match?.name)
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Running the import

    /// Owns its own `Task`, same reasoning as `TableExportViewModel
    /// .startExport`: cancellation must be reachable from "Kapat", a
    /// different button than the one that started the run.
    func startImport() {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        importTask = Task { [self] in await performImport() }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func performImport() async {
        defer { isImporting = false; importTask = nil }

        guard let sourceFileURL else { return }
        let mapping = columnMappings.compactMap { entry -> (sourceIndex: Int, targetColumn: ColumnInfo)? in
            guard let targetName = entry.targetColumnName,
                  let column = allColumns.first(where: { $0.name == targetName }) else { return nil }
            return (entry.id, column)
        }
        guard !mapping.isEmpty else {
            errorMessage = "İçe aktarmak için en az bir kolonu eşlemelisiniz."
            return
        }

        do {
            let totalRows = try await countDataRows(at: sourceFileURL)
            progress = Progress(completedRows: 0, totalRows: totalRows)

            _ = try await service.rawQuery("START TRANSACTION")
            do {
                try await insertAllRows(from: sourceFileURL, mapping: mapping)
            } catch {
                _ = try? await service.rawQuery("ROLLBACK")
                throw error
            }
            _ = try await service.rawQuery("COMMIT")
            progress?.completedRows = progress?.totalRows ?? 0
            didFinishSuccessfully = true
        } catch is CancellationError {
            // User-initiated — not an error to surface.
        } catch {
            errorMessage = describe(error)
        }
    }

    /// One full pass over the file just to establish `Progress.totalRows`
    /// up front — mirrors `TableExportViewModel.rowCount()`'s upfront
    /// `SELECT COUNT(*)`, except there's no server-side count to ask for
    /// here, so the file itself has to be scanned once.
    private func countDataRows(at url: URL) async throws -> Int {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        var count = 0
        try await CSVImportParser.parse(fileHandle: fileHandle, options: csvOptions) { _, _ in count += 1 }
        return hasHeaderRow ? max(0, count - 1) : count
    }

    /// Re-opens the file (the counting pass above already consumed the
    /// first handle to EOF) and streams it through in `insertBatchSize`-row
    /// batches — each batch is one multi-row parameterized `INSERT`, so a
    /// huge file is never held in memory as one array, and file content
    /// never becomes literal SQL text (it's untrusted user data, bound as
    /// parameters throughout, same discipline as `TableDataViewModel
    /// .bindValue`).
    private func insertAllRows(
        from url: URL,
        mapping: [(sourceIndex: Int, targetColumn: ColumnInfo)]
    ) async throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let qualifiedTable = try SchemaIntrospectionService.qualifiedIdentifier(database: table.database, name: table.name)
        let columnList = try mapping.map { try SchemaIntrospectionService.quotedIdentifier($0.targetColumn.name) }.joined(separator: ", ")
        let placeholderGroup = "(" + Array(repeating: "?", count: mapping.count).joined(separator: ", ") + ")"

        var batchBinds: [MySQLData] = []
        var batchRowCount = 0
        var completedRows = 0

        try await CSVImportParser.parse(fileHandle: fileHandle, options: csvOptions) { rowIndex, fields in
            if self.hasHeaderRow && rowIndex == 0 { return }

            for entry in mapping {
                let text = entry.sourceIndex < fields.count ? fields[entry.sourceIndex] : ""
                batchBinds.append(self.bindValue(text: text, column: entry.targetColumn))
            }
            batchRowCount += 1

            if batchRowCount >= self.insertBatchSize {
                try Task.checkCancellation()
                let valuesClause = Array(repeating: placeholderGroup, count: batchRowCount).joined(separator: ", ")
                try await self.service.execute("INSERT INTO \(qualifiedTable) (\(columnList)) VALUES \(valuesClause)", batchBinds)
                completedRows += batchRowCount
                self.progress?.completedRows = completedRows
                batchBinds.removeAll(keepingCapacity: true)
                batchRowCount = 0
                if self.interBatchDelay != .zero {
                    try await Task.sleep(for: self.interBatchDelay)
                }
            }
        }

        if batchRowCount > 0 {
            try Task.checkCancellation()
            let valuesClause = Array(repeating: placeholderGroup, count: batchRowCount).joined(separator: ", ")
            try await service.execute("INSERT INTO \(qualifiedTable) (\(columnList)) VALUES \(valuesClause)", batchBinds)
            completedRows += batchRowCount
            progress?.completedRows = completedRows
        }
    }

    /// Same NULL rule as `TableDataViewModel.bindValue`: an empty source
    /// field on a nullable column becomes `NULL`; everything else is
    /// passed straight through as text and left for MySQL's own coercion
    /// (matches this app's existing "don't second-guess the server's own
    /// CAST" convention).
    private func bindValue(text: String, column: ColumnInfo) -> MySQLData {
        if text.isEmpty && column.isNullable {
            return .null
        }
        return MySQLData(string: text)
    }

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }
}
