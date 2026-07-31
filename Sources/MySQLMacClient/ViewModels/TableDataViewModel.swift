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
    /// One-shot: the row `insertBlankRow()` just added, for the grid to
    /// select and scroll into view. `SpreadsheetGridView` clears it once
    /// applied — same consume-then-nil pattern as the SQL editor's
    /// `pendingQueryInsertion`.
    @Published var rowIDToFocus: TableRow.ID?

    let databaseName: String
    let tableName: String
    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    /// Logs the writes this grid performs (cell edit, row insert, row
    /// delete) into the connection's query history — `nil` in tests.
    private let historyRecorder: QueryHistoryRecorder?
    private var primaryKeyColumns: [String] = []

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
        sortColumn = column
        sortAscending = ascending
        currentOffset = 0
        await reload()
    }

    // MARK: - Pagination

    func nextPage() async {
        guard currentOffset + pageSize < totalRowCount else { return }
        currentOffset += pageSize
        await reload()
    }

    func previousPage() async {
        guard currentOffset > 0 else { return }
        currentOffset = max(0, currentOffset - pageSize)
        await reload()
    }

    func changePageSize(_ newSize: Int) async {
        guard newSize > 0, newSize != pageSize else { return }
        pageSize = newSize
        currentOffset = 0
        await reload()
    }

    /// The "Sınırlı" checkbox: off loads every row in the table, ignoring
    /// `pageSize` entirely.
    func setPaginationEnabled(_ enabled: Bool) async {
        guard enabled != isPaginationEnabled else { return }
        isPaginationEnabled = enabled
        currentOffset = 0
        await reload()
    }

    // MARK: - Editing

    func commitEdit(rowId: TableRow.ID, column: String, newText: String) async {
        guard hasPrimaryKey, let index = rows.firstIndex(where: { $0.id == rowId }) else { return }
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

    /// Inserts a row of DEFAULT/NULL values (skipping auto-increment columns)
    /// so the user can then edit cells in place, matching common SQL GUI UX.
    /// A NOT NULL column with no default (including a manually-assigned,
    /// non-auto-increment primary key — common on imported/legacy schemas)
    /// used to get `NULL` here regardless, which MySQL always rejects: the
    /// insert failed every time on that first, unavoidable NULL rather than
    /// on anything the user actually did. A type-appropriate placeholder
    /// (0 / '' / now()) lets the insert succeed instead, so the row exists
    /// and the user fixes the placeholder value via ordinary, already
    /// PK-aware cell editing — same as fixing any other value.
    func insertBlankRow() async {
        guard hasPrimaryKey else { return }
        do {
            let insertable = columns.filter { !$0.isAutoIncrement }
            guard !insertable.isEmpty else { return }
            var columnNames: [String] = []
            var placeholders: [String] = []
            var binds: [MySQLData] = []
            // The primary-key values we're about to write, so the new row
            // can be found again after the reload.
            var insertedPrimaryKey: [String: String] = [:]
            for column in insertable {
                columnNames.append(try quoted(column.name))
                placeholders.append("?")
                let bind: MySQLData
                if let defaultValue = column.defaultValue {
                    bind = MySQLData(string: defaultValue)
                } else if column.isNullable {
                    bind = .null
                } else {
                    bind = placeholderValue(for: column)
                }
                binds.append(bind)
                if column.isPrimaryKey, let text = bind.string {
                    insertedPrimaryKey[column.name] = text
                }
            }
            let sql = "INSERT INTO \(try qualifiedTable()) (\(columnNames.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))"
            historyRecorder?.record(sql, binds: binds, database: databaseName, source: .app)
            let result = try await service.execute(sql, binds)
            await reload()
            await focusInsertedRow(primaryKey: insertedPrimaryKey, lastInsertID: result.lastInsertID)
        } catch {
            errorMessage = describe(error)
        }
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

    /// A conservative type sniff off `SHOW COLUMNS`' `Type` string (e.g.
    /// `int(11)`, `varchar(255)`, `datetime`) — good enough to avoid an
    /// outright type-mismatch error, not a claim of picking a *meaningful*
    /// value. The user is expected to overwrite this immediately.
    private func placeholderValue(for column: ColumnInfo) -> MySQLData {
        let type = column.mysqlType.lowercased()
        if type.contains("int") || type.contains("decimal") || type.contains("float") || type.contains("double") {
            return MySQLData(string: "0")
        }
        if type.contains("date") || type.contains("time") {
            return MySQLData(string: RowValue.dateFormatter.string(from: Date()))
        }
        return MySQLData(string: "")
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
                ddl = "(alınamadı)"
            }

            tableInfoText = TableInfoReport.assemble(
                tableName: tableName,
                columnHeaders: columnHeaders, columnRows: columnRows,
                indexHeaders: indexHeaders, indexRows: indexRows,
                ddl: ddl
            )
        } catch {
            tableInfoText = "Tablo bilgisi alınamadı: \(error.localizedDescription)"
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
