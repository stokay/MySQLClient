import Foundation
import MySQLNIO

@MainActor
final class TableDataViewModel: ObservableObject {
    @Published private(set) var columns: [ColumnInfo] = []
    @Published private(set) var rows: [TableRow] = []
    @Published var pageSize: Int = 1000
    /// Off = the "Sınırlı" checkbox unchecked: `fetchPage()` sends no
    /// `LIMIT` at all, loading the whole table regardless of `pageSize`.
    @Published private(set) var isPaginationEnabled: Bool = true
    @Published private(set) var currentOffset: Int = 0
    @Published private(set) var totalRowCount: Int = 0
    @Published var sortColumn: String?
    @Published var sortAscending: Bool = true
    @Published var filterColumn: String?
    @Published var filterValue: String = ""
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var hasPrimaryKey = true
    /// One-shot: the row "Satır Ekle" just added (or the real row a draft
    /// turned into), for the grid to select and scroll into view.
    /// `SpreadsheetGridView` clears it once applied — same consume-then-nil
    /// pattern as the SQL editor's `pendingQueryInsertion`.
    @Published var rowIDToFocus: TableRow.ID?
    /// The pending, not-yet-INSERTed row, if any. At most one exists at a
    /// time; `nil` means everything in `rows` is a real database row.
    @Published private(set) var draftRowID: TableRow.ID?
    /// Bumped every time `rows` is refetched, so the grid can tell a
    /// wholesale refresh (new `TableRow` instances for the same records —
    /// its selection has to be re-found) from an in-place change like a
    /// committed cell edit (where its own selection is still valid).
    @Published private(set) var dataVersion: Int = 0

    let databaseName: String
    let tableName: String
    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    /// Logs the writes this grid performs (cell edit, row insert, row
    /// delete) into the connection's query history — `nil` in tests.
    private let historyRecorder: QueryHistoryRecorder?
    private var primaryKeyColumns: [String] = []
    /// True while the draft row's INSERT is in flight — see `insertDraftRow`.
    private var isInsertingDraftRow = false

    /// `pageSize` defaults to the persisted setting; tests pass an explicit
    /// value and never touch the singleton.
    init(
        databaseName: String,
        tableName: String,
        service: MySQLService,
        introspection: SchemaIntrospectionService,
        pageSize: Int? = nil,
        historyRecorder: QueryHistoryRecorder? = nil
    ) {
        self.databaseName = databaseName
        self.tableName = tableName
        self.service = service
        self.introspection = introspection
        self.historyRecorder = historyRecorder
        // Resolved here (inside @MainActor context) rather than as a
        // default parameter value — Swift 6 strict concurrency forbids
        // referencing @MainActor-isolated properties in default parameters.
        self.pageSize = pageSize ?? SettingsStore.shared.settings.grid.defaultPageSize
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            columns = try await introspection.columns(forTable: tableName, inDatabase: databaseName)
            primaryKeyColumns = columns.filter(\.isPrimaryKey).map(\.name)
            hasPrimaryKey = !primaryKeyColumns.isEmpty
            currentOffset = 0
            try await reloadOrThrow()
        } catch {
            errorMessage = describe(error)
        }
    }

    func reload() async {
        guard await flushDraftRow() else { return }
        errorMessage = nil
        do {
            try await reloadOrThrow()
        } catch {
            errorMessage = describe(error)
        }
    }

    private func reloadOrThrow() async throws {
        totalRowCount = try await fetchTotalCount()
        rows = try await fetchPage()
        dataVersion += 1
    }

    // MARK: - Fetching

    private func fetchTotalCount() async throws -> Int {
        var sql = "SELECT COUNT(*) AS cnt FROM \(try qualifiedTable())"
        var binds: [MySQLData] = []
        if let clause = try whereClause() {
            sql += " WHERE \(clause.sql)"
            binds = clause.binds
        }
        let result = try await service.query(sql, binds)
        return result.first?.column("cnt")?.int ?? 0
    }

    private func fetchPage() async throws -> [TableRow] {
        var sql = "SELECT * FROM \(try qualifiedTable())"
        var binds: [MySQLData] = []
        if let clause = try whereClause() {
            sql += " WHERE \(clause.sql)"
            binds = clause.binds
        }
        if let sortColumn, columns.contains(where: { $0.name == sortColumn }) {
            sql += " ORDER BY \(try quoted(sortColumn)) \(sortAscending ? "ASC" : "DESC")"
        }
        if isPaginationEnabled {
            sql += " LIMIT \(pageSize) OFFSET \(currentOffset)"
        }

        let mysqlRows = try await service.query(sql, binds)
        return mysqlRows.map { mysqlRow in
            var values: [String: RowValue] = [:]
            for definition in mysqlRow.columnDefinitions {
                if let data = mysqlRow.column(definition.name) {
                    values[definition.name] = RowValue(mysqlData: data)
                }
            }
            return TableRow(values: values)
        }
    }

    private func whereClause() throws -> (sql: String, binds: [MySQLData])? {
        guard let filterColumn, !filterValue.isEmpty,
              columns.contains(where: { $0.name == filterColumn }) else {
            return nil
        }
        let quotedColumn = try quoted(filterColumn)
        return ("\(quotedColumn) LIKE ?", [MySQLData(string: "%\(filterValue)%")])
    }

    func applyFilter(column: String?, value: String) async {
        guard await flushDraftRow() else { return }
        filterColumn = column
        filterValue = value
        currentOffset = 0
        await reload()
    }

    /// Direction is driven by the caller rather than toggled in here —
    /// `SpreadsheetGridView` reads it off `NSTableColumn.sortDescriptorPrototype`,
    /// which AppKit already flips for same-column re-clicks and resets to
    /// ascending when a different column header is clicked.
    func applySort(column: String, ascending: Bool) async {
        guard await flushDraftRow() else { return }
        sortColumn = column
        sortAscending = ascending
        currentOffset = 0
        await reload()
    }

    // MARK: - Pagination

    func nextPage() async {
        guard await flushDraftRow() else { return }
        guard currentOffset + pageSize < totalRowCount else { return }
        currentOffset += pageSize
        await reload()
    }

    func previousPage() async {
        guard await flushDraftRow() else { return }
        guard currentOffset > 0 else { return }
        currentOffset = max(0, currentOffset - pageSize)
        await reload()
    }

    func changePageSize(_ newSize: Int) async {
        guard await flushDraftRow() else { return }
        guard newSize > 0, newSize != pageSize else { return }
        pageSize = newSize
        currentOffset = 0
        await reload()
    }

    /// The "Sınırlı" checkbox: off loads every row in the table, ignoring
    /// `pageSize` entirely.
    func setPaginationEnabled(_ enabled: Bool) async {
        guard await flushDraftRow() else { return }
        guard enabled != isPaginationEnabled else { return }
        isPaginationEnabled = enabled
        currentOffset = 0
        await reload()
    }

    // MARK: - Editing

    func commitEdit(rowId: TableRow.ID, column: String, newText: String) async {
        guard hasPrimaryKey, let index = rows.firstIndex(where: { $0.id == rowId }) else { return }
        // The draft row has nothing to UPDATE yet: what's typed is held in
        // memory and goes out as a single INSERT when the row is left.
        guard !rows[index].isDraft else {
            rows[index].editedText[column] = newText
            return
        }
        rows[index].editedText[column] = newText
        guard rows[index].isDirty(column) else { return }

        do {
            try await updateRow(rows[index], changedColumns: [column])
            rows[index].acceptEdits(for: [column])
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    private func updateRow(_ row: TableRow, changedColumns: [String]) async throws {
        guard !changedColumns.isEmpty else { return }
        var setClauses: [String] = []
        var binds: [MySQLData] = []
        for column in changedColumns {
            setClauses.append("\(try quoted(column)) = ?")
            binds.append(bindValue(text: row.editedText[column] ?? "", column: column))
        }
        let (whereSQL, whereBinds) = try primaryKeyWhereClause(for: row, primaryKeyColumns: primaryKeyColumns)
        let sql = "UPDATE \(try qualifiedTable()) SET \(setClauses.joined(separator: ", ")) WHERE \(whereSQL)"
        historyRecorder?.record(sql, binds: binds + whereBinds, database: databaseName, source: .app)
        try await service.execute(sql, binds + whereBinds)
    }

    private func bindValue(text: String, column: String) -> MySQLData {
        guard let info = columns.first(where: { $0.name == column }) else {
            return MySQLData(string: text)
        }
        if text.isEmpty && info.isNullable {
            return .null
        }
        return MySQLData(string: text)
    }

    func deleteRow(_ row: TableRow) async {
        // The trash button on the draft row just throws the pending row
        // away — there's nothing in the database to DELETE.
        if row.isDraft {
            rows.removeAll { $0.id == row.id }
            if draftRowID == row.id { draftRowID = nil }
            return
        }
        guard hasPrimaryKey else { return }
        do {
            let (whereSQL, whereBinds) = try primaryKeyWhereClause(for: row, primaryKeyColumns: primaryKeyColumns)
            let sql = "DELETE FROM \(try qualifiedTable()) WHERE \(whereSQL)"
            historyRecorder?.record(sql, binds: whereBinds, database: databaseName, source: .app)
            try await service.execute(sql, whereBinds)
            await reload()
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Adding a row

    /// "Satır Ekle": appends an empty row **to the grid only**, the way
    /// other SQL clients do it. Nothing is written until the user leaves
    /// the row (`commitDraftRow()`).
    ///
    /// This used to INSERT a row of placeholder values (`0` / `''` /
    /// `now()` for NOT NULL columns) on the spot, which meant a click alone
    /// left a junk row behind whenever the user changed their mind, burned
    /// an AUTO_INCREMENT id every time, and could trip UNIQUE constraints
    /// or insert triggers on values nobody asked for.
    func addDraftRow() {
        guard hasPrimaryKey, !columns.isEmpty else { return }
        // One pending row at a time: a second click just goes back to it.
        if let draftRowID {
            rowIDToFocus = draftRowID
            return
        }
        let draft = TableRow(draftColumns: columns.map(\.name))
        rows.append(draft)
        draftRowID = draft.id
        rowIDToFocus = draft.id
    }

    /// Called when the user leaves the draft row — Enter, Tab past its last
    /// column, or selecting another row — the same moment an edit to an
    /// existing row commits. On success the page is refetched, so the row
    /// picks up AUTO_INCREMENT ids, DEFAULTs and anything a trigger wrote.
    ///
    /// `focusingInsertedRow` is what Enter and Tab want (they leave the user
    /// on the row they just filled in); a click on a *different* row passes
    /// `false`, since moving the highlight would override the row the user
    /// deliberately picked.
    func commitDraftRow(focusingInsertedRow: Bool = true) async {
        guard let inserted = await insertDraftRow() else { return }
        await reload()
        if focusingInsertedRow {
            await focusInsertedRow(primaryKey: inserted.primaryKey, lastInsertID: inserted.lastInsertID)
        }
    }

    /// The INSERT itself, without the refetch — `nil` when nothing was
    /// written.
    ///
    /// Only columns the user actually typed into are listed, so everything
    /// else gets the server's own DEFAULT / AUTO_INCREMENT instead of a
    /// value guessed here; an empty cell on a nullable column still writes
    /// NULL through `bindValue`. A draft nothing was typed into is dropped
    /// silently — clicking "Satır Ekle" and changing your mind must not
    /// write anything.
    ///
    /// If the INSERT fails (NOT NULL without a default, UNIQUE, FK …) the
    /// row stays a draft with the server's message in `errorMessage`, so
    /// the user can fix the value instead of losing what they typed.
    private func insertDraftRow() async -> (primaryKey: [String: String], lastInsertID: UInt64?)? {
        // One gesture can reach here twice — leaving the row by clicking
        // another one both changes the selection and ends the cell's edit,
        // and the INSERT is awaited in between — which would insert the row
        // twice. `draftRowID` alone can't guard that: it's only cleared once
        // the INSERT comes back.
        guard !isInsertingDraftRow else { return nil }
        guard let draftRowID, let index = rows.firstIndex(where: { $0.id == draftRowID }) else { return nil }
        isInsertingDraftRow = true
        defer { isInsertingDraftRow = false }
        let draft = rows[index]
        let filledColumns = columns.filter { draft.isDirty($0.name) }
        guard !filledColumns.isEmpty else {
            rows.remove(at: index)
            self.draftRowID = nil
            return nil
        }

        do {
            var columnNames: [String] = []
            var placeholders: [String] = []
            var binds: [MySQLData] = []
            // The primary-key values we're about to write, so the new row
            // can be found again after the reload.
            var insertedPrimaryKey: [String: String] = [:]
            for column in filledColumns {
                let text = draft.editedText[column.name] ?? ""
                columnNames.append(try quoted(column.name))
                placeholders.append("?")
                binds.append(bindValue(text: text, column: column.name))
                if column.isPrimaryKey {
                    insertedPrimaryKey[column.name] = text
                }
            }
            let sql = "INSERT INTO \(try qualifiedTable()) (\(columnNames.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))"
            historyRecorder?.record(sql, binds: binds, database: databaseName, source: .app)
            let result = try await service.execute(sql, binds)
            self.draftRowID = nil
            errorMessage = nil
            return (insertedPrimaryKey, result.lastInsertID)
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// Every refetch (Yenile, sort, filter, page change) replaces `rows`,
    /// which would drop a pending draft on the floor — so it's committed
    /// first, exactly as leaving the row would. Returns `false` when a
    /// draft is still there because its INSERT failed: the caller then
    /// abandons its own operation, leaving the error on screen and the
    /// half-typed row in place to be fixed.
    private func flushDraftRow() async -> Bool {
        guard draftRowID != nil else { return true }
        _ = await insertDraftRow()
        return draftRowID == nil
    }

    /// Points the grid at the row that was just inserted. An
    /// auto-increment key isn't part of the `INSERT`, so its value comes
    /// from the server's `lastInsertID`; a manually-assigned key is
    /// whatever we bound.
    ///
    /// With an auto-increment key the new row sorts to the very end, which
    /// on a paginated table is usually *not* the page being viewed — so if
    /// it isn't here, jump to the last page and look again before giving
    /// up. It can still legitimately not be found (an active filter the
    /// blank row doesn't match), in which case nothing is focused.
    private func focusInsertedRow(primaryKey: [String: String], lastInsertID: UInt64?) async {
        var target = primaryKey
        if let lastInsertID, lastInsertID > 0,
           let autoColumn = columns.first(where: { $0.isAutoIncrement && $0.isPrimaryKey }) {
            target[autoColumn.name] = String(lastInsertID)
        }
        guard !primaryKeyColumns.isEmpty, target.count == primaryKeyColumns.count else { return }

        func matchingRowID() -> TableRow.ID? {
            rows.first { row in
                primaryKeyColumns.allSatisfy { target[$0] == row.originalValues[$0]?.displayString }
            }?.id
        }

        if let id = matchingRowID() {
            rowIDToFocus = id
            return
        }

        guard isPaginationEnabled, totalRowCount > 0 else { return }
        let lastPageOffset = ((totalRowCount - 1) / pageSize) * pageSize
        guard lastPageOffset != currentOffset else { return }
        currentOffset = lastPageOffset
        await reload()
        rowIDToFocus = matchingRowID()
    }

    // MARK: - Table info ("İnfo" context-menu action)

    /// Non-nil replaces the grid with the plain-text info report; "Tablo
    /// Görünümüne Dön" sets it back to nil.
    @Published var tableInfoText: String?

    /// Builds the SQLyog-style text report (columns / indexes / DDL) for
    /// this table from `SHOW FULL COLUMNS`, `SHOW INDEX` and
    /// `SHOW CREATE TABLE`.
    func showTableInfo() async {
        do {
            let qualified = try qualifiedTable()
            let columnsResult = try await service.rawQuery("SHOW FULL COLUMNS FROM \(qualified)")
            let indexResult = try await service.rawQuery("SHOW INDEX FROM \(qualified)")
            let ddlResult = try await service.rawQuery("SHOW CREATE TABLE \(qualified)")

            let (columnHeaders, columnRows) = Self.tabulate(columnsResult.rows)
            let (indexHeaders, indexRows) = Self.tabulate(indexResult.rows)
            // Column 2 of SHOW CREATE TABLE ("Create Table") is the DDL.
            let ddl: String
            if let firstRow = ddlResult.rows.first, firstRow.columnDefinitions.count >= 2 {
                ddl = Self.reportString(firstRow.column(firstRow.columnDefinitions[1].name))
            } else {
                ddl = String(localized: "(unavailable)")
            }

            tableInfoText = TableInfoReport.assemble(
                tableName: tableName,
                columnHeaders: columnHeaders, columnRows: columnRows,
                indexHeaders: indexHeaders, indexRows: indexRows,
                ddl: ddl
            )
        } catch {
            tableInfoText = String(localized: "Could not load table info: \(error.localizedDescription)")
        }
    }

    /// Result-set → ordered header names + stringified cells, preserving
    /// the server's own column order (`columnDefinitions`).
    private nonisolated static func tabulate(_ rows: [MySQLRow]) -> (headers: [String], rows: [[String]]) {
        guard let firstRow = rows.first else { return ([], []) }
        let headers = firstRow.columnDefinitions.map(\.name)
        let values = rows.map { row in
            headers.map { Self.reportString(row.column($0)) }
        }
        return (headers, values)
    }

    /// `(NULL)` for SQL NULL (the report shows it explicitly, unlike the
    /// grid); tries `.string` first because SHOW-command result columns
    /// often arrive typed as blobs that are really text.
    private nonisolated static func reportString(_ data: MySQLData?) -> String {
        guard let data, data.buffer != nil else { return "(NULL)" }
        if let string = data.string { return string }
        let value = RowValue(mysqlData: data)
        return value.isNull ? "(NULL)" : value.displayString
    }

    // MARK: - Helpers

    private func quoted(_ identifier: String) throws -> String {
        try SchemaIntrospectionService.quotedIdentifier(identifier)
    }

    private func qualifiedTable() throws -> String {
        try SchemaIntrospectionService.qualifiedIdentifier(database: databaseName, name: tableName)
    }

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }
}
