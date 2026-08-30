import Foundation
import MySQLNIO

/// Set when the query panel's last-run SQL was recognized as a simple,
/// single-table `SELECT` whose result includes every primary-key column of
/// that table — the minimum needed to build a safe `WHERE` clause for
/// editing. Its presence is what makes "Editable" in the query panel
/// actually do something instead of silently no-op-ing.
struct QueryEditContext {
    let database: String
    let table: String
    let primaryKeyColumns: [String]
    let columns: [ColumnInfo]
}

/// One result set of a query's response. Ordinary statements produce at
/// most one; a `CALL` to a procedure whose body runs several `SELECT`s
/// produces one per `SELECT`, which the console shows as separate tabs.
struct QueryResultSet: Identifiable {
    let id: Int
    let columns: [String]
    var rows: [TableRow]
}

/// Backs the SQL query panel as a *session*-level concern, not a per-table
/// one: one instance lives for the whole connected window
/// (`MainWindowView`) and is shared by every table's grid and by the
/// no-table-selected placeholder alike. This is what lets a brand-new,
/// still-empty database — nothing to select in the sidebar yet — still open
/// the editor and run a `CREATE TABLE`, which a panel embedded in a
/// per-table view model could never do.
@MainActor
final class SQLConsoleViewModel: ObservableObject {
    @Published var isQueryPanelVisible = false
    @Published var queryText: String = ""
    /// One-shot: set by a sidebar double-click, consumed by `SQLTextView`
    /// (inserted at the cursor, then cleared back to `nil`).
    @Published var pendingQueryInsertion: String?
    /// Like `pendingQueryInsertion`, but appended to the end of the editor
    /// (after a blank line) and left selected — used by the sidebar's
    /// "SQL Sorgu Ekle" statement templates.
    @Published var pendingQueryAppend: String?
    @Published private(set) var isExecutingQuery = false
    @Published var queryErrorMessage: String?
    @Published private(set) var queryMessage: String?
    @Published private(set) var isShowingQueryResult = false
    /// Every result set the last query returned, in order. The grid renders
    /// `selectedResultSetIndex`'s entry; more than one turns on the tab bar.
    @Published private(set) var queryResultSets: [QueryResultSet] = []
    @Published var selectedResultSetIndex = 0
    @Published var isQueryResultEditableRequested = false
    @Published private(set) var queryEditContext: QueryEditContext?

    /// The result set currently on screen — the grid and the row-editing
    /// paths below all work against this one, never across tabs. Guarded
    /// against a stale index (a new query can return fewer result sets than
    /// the previous one while `selectedResultSetIndex` still points high).
    private var selectedResultSet: QueryResultSet? {
        guard queryResultSets.indices.contains(selectedResultSetIndex) else { return queryResultSets.first }
        return queryResultSets[selectedResultSetIndex]
    }

    var queryResultColumns: [String] { selectedResultSet?.columns ?? [] }
    var queryResultRows: [TableRow] { selectedResultSet?.rows ?? [] }

    /// `true` once both the user asked for editing and the last query
    /// actually qualifies (single table, PK included in the result).
    var isQueryResultEditable: Bool { isQueryResultEditableRequested && queryEditContext != nil }

    /// Shown next to the Editable toggle when the user turned it on but the
    /// current result doesn't qualify, so the toggle doesn't look broken.
    var queryResultEditabilityNote: String? {
        guard isShowingQueryResult, isQueryResultEditableRequested, queryEditContext == nil else { return nil }
        return String(localized: "This result is not editable (requires a single table and a primary key column in the result).")
    }

    /// Live selection inside the SQL editor, kept up to date by
    /// `SQLTextView`'s coordinator. Deliberately *not* `@Published`: no view
    /// renders it, and publishing would re-invalidate the UI on every
    /// caret drag.
    var querySelectedText: String?

    /// The database of whichever table is currently selected in the
    /// sidebar (nil when none is) — the fallback schema `runQuery` assumes
    /// for an unqualified single-table `SELECT` (`SELECT * FROM widgets`
    /// rather than `` SELECT * FROM `db`.`widgets` ``). Kept in sync by
    /// `MainWindowView` as the selection changes; a query that explicitly
    /// qualifies its table never needs this at all.
    var currentDatabaseHint: String?

    /// Called after `clearQueryResult()` finishes clearing the console's own
    /// state — set by whichever table grid is currently showing, pointing
    /// at *its* `reload()`, so "Tablo Görünümüne Dön" never leaves stale
    /// pre-query data on screen if the query was a write. `MainWindowView`
    /// reassigns this every time the selected table changes, and clears it
    /// to `nil` when nothing is selected.
    var onQueryResultCleared: (() async -> Void)?

    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    private let defaultSelectLimit: Int
    /// Query history is per connection profile; `nil` for a console with no
    /// profile behind it (tests), which simply doesn't record.
    private let historyRecorder: QueryHistoryRecorder?

    /// `defaultSelectLimit` defaults to the persisted setting; tests pass
    /// an explicit value and never touch the singleton.
    init(
        service: MySQLService,
        introspection: SchemaIntrospectionService,
        defaultSelectLimit: Int? = nil,
        historyRecorder: QueryHistoryRecorder? = nil
    ) {
        self.service = service
        self.introspection = introspection
        self.defaultSelectLimit = defaultSelectLimit ?? SettingsStore.shared.settings.editor.defaultSelectLimit
        self.historyRecorder = historyRecorder
    }

    /// Newest-first history for this console's profile — what the query
    /// panel's history menu lists. Empty when there's no profile.
    var queryHistory: [QueryHistoryEntry] {
        historyRecorder?.entries() ?? []
    }

    func clearQueryHistory() {
        historyRecorder?.clear()
    }

    /// `defaultTable`, when given, seeds a first-open empty editor with a
    /// ready-to-run `SELECT * FROM ...` for that table — the convenience a
    /// table's own "SQL Sorgusu" toolbar button provides. The
    /// no-table-selected placeholder calls this with `nil`, opening a
    /// genuinely blank editor (there's no table to default to).
    func toggleQueryPanel(defaultTable: (database: String, table: String)? = nil) {
        isQueryPanelVisible.toggle()
        if isQueryPanelVisible, queryText.isEmpty, let defaultTable,
           let qualified = try? SchemaIntrospectionService.qualifiedIdentifier(database: defaultTable.database, name: defaultTable.table) {
            queryText = "SELECT * FROM \(qualified) LIMIT \(defaultSelectLimit);"
        }
    }

    /// Runs the editor's *selected* text when there is a selection, the
    /// whole editor otherwise (the SQLyog/DBeaver convention) — so part of
    /// a longer script can be executed by selecting just those lines.
    /// Results replace the editable table grid until `clearQueryResult()`.
    /// Whether they're actually *editable* depends on `resolveQueryEditContext`
    /// recognizing the query as a simple single-table SELECT — arbitrary SQL
    /// (joins, computed columns, aggregates) generally isn't safely mappable
    /// back to a row's primary key, so those stay read-only regardless of
    /// the Editable toggle.
    func runQuery() async {
        guard let sqlToRun = prepareToRunQuery() else { return }
        defer { isExecutingQuery = false }

        // A `DELIMITER $$ ... DELIMITER ;`-wrapped script (the sidebar's
        // "Oluştur ▸ Stored Procedure/…" templates, "Alter View") isn't
        // valid SQL to send as one blob — `DELIMITER` is a `mysql`-CLI-only
        // directive the server has never heard of. `DelimiterScript`
        // returns `nil` for every other query, so this only ever changes
        // behavior for scripts that actually contain one.
        if let statements = DelimiterScript.statements(from: sqlToRun) {
            await runStatements(statements)
            return
        }

        do {
            try await useCurrentDatabaseIfKnown()
            let result = try await service.rawQuery(sqlToRun)
            await applyResult(result, executedSQL: sqlToRun)
            AnalyticsService.trackFeatureUsed("sql_query_run")
        } catch {
            queryErrorMessage = describe(error, sql: sqlToRun, serverVersion: await service.serverVersion)
            isShowingQueryResult = false
            queryEditContext = nil
            AnalyticsService.trackError(error, feature: "sql_query_run")
        }
    }

    /// "Tümünü Çalıştır": splits the editor's selected text (or the whole
    /// editor — same "selection wins" convention as `runQuery()`) on every
    /// top-level `;` and runs each resulting statement in order, with no
    /// `DELIMITER` directive required first — unlike `runQuery()`, which
    /// only ever splits a script that already has one. Only safe for
    /// scripts made of independent simple statements (`USE db;\ncall
    /// proc();`, …): see `DelimiterScript.allStatements(from:)` for why a
    /// `CREATE PROCEDURE`/`FUNCTION`/`TRIGGER` body still needs `DELIMITER`
    /// wrapping even with this button.
    func runAllStatements() async {
        guard let sqlToRun = prepareToRunQuery() else { return }
        defer { isExecutingQuery = false }
        await runStatements(DelimiterScript.allStatements(from: sqlToRun))
    }

    /// Shared by `runQuery()`/`runAllStatements()`: resolves which text to
    /// run (selection wins over the whole editor), resets the previous
    /// run's error/message state, and flips `isExecutingQuery` — `nil`
    /// when there's nothing to run, which both callers treat as "do
    /// nothing" (no `isExecutingQuery` flip, no `defer` to unwind).
    private func prepareToRunQuery() -> String? {
        let selection = querySelectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sqlToRun = selection.isEmpty ? queryText : selection
        let trimmed = sqlToRun.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Recorded here, before the query runs, so a statement that fails
        // is remembered too — a long query that failed on a typo is
        // exactly the one worth recalling to fix.
        historyRecorder?.record(sqlToRun, database: currentDatabaseHint, source: .console)
        isExecutingQuery = true
        queryErrorMessage = nil
        queryMessage = nil
        return sqlToRun
    }

    /// Runs a `DELIMITER`-split script's statements one at a time, in order
    /// (a `DROP VIEW` before its replacing `CREATE VIEW`, etc.) — stopping
    /// and reporting immediately on the first failure, since the
    /// server has no notion of the script as a whole to roll back. Only the
    /// last statement's result populates the grid, matching what running
    /// just that one statement by itself would have shown.
    /// The "N rows affected" status line. Named (rather than inlined) so
    /// tests can assert against it without hardcoding a translated string —
    /// it also carries the plural variation, which a literal wouldn't.
    static func affectedRowsMessage(_ count: UInt64) -> String {
        String(localized: "\(count) rows affected.")
    }

    private func runStatements(_ statements: [String]) async {
        do {
            try await useCurrentDatabaseIfKnown()
        } catch {
            queryErrorMessage = describe(error)
            isShowingQueryResult = false
            queryEditContext = nil
            return
        }
        for (index, statement) in statements.enumerated() {
            do {
                let result = try await service.rawQuery(statement)
                if index == statements.count - 1 {
                    await applyResult(result, executedSQL: statement)
                    queryMessage = String(localized: "\(statements.count) statements executed. \(queryMessage ?? "")")
                        .trimmingCharacters(in: .whitespaces)
                }
            } catch {
                let detail = describe(error, sql: statement, serverVersion: await service.serverVersion)
                queryErrorMessage = String(localized: "Statement \(index + 1)/\(statements.count) failed: \(detail)")
                isShowingQueryResult = false
                queryEditContext = nil
                return
            }
        }
    }

    /// Keeps the server's own default-database context in sync with the
    /// sidebar selection before running console SQL. No view-model-generated
    /// statement in this app relies on it — every one is fully qualified —
    /// but arbitrary/pasted SQL run here (an exported table dump's
    /// unqualified `CREATE TABLE`, for instance) does, and this app's
    /// connection is never given a default database at connect time (it
    /// browses multiple databases from one connection), so unqualified SQL
    /// otherwise fails with "No database selected" even with a table
    /// clearly selected in the sidebar.
    private func useCurrentDatabaseIfKnown() async throws {
        guard let currentDatabaseHint else { return }
        // `rawQuery`, not `execute`: `USE` isn't valid over the prepared
        // statement (binary) protocol `execute` uses — even with zero
        // binds, MySQL/MariaDB rejects it with "This command is not
        // supported in the prepared statement protocol yet".
        _ = try await service.rawQuery("USE \(try SchemaIntrospectionService.quotedIdentifier(currentDatabaseHint))")
    }

    private func applyResult(_ result: RawQueryResult, executedSQL: String) async {
        let sets: [QueryResultSet] = result.resultSets.enumerated().compactMap { index, rows in
            guard let firstRow = rows.first else { return nil }
            let columnNames = firstRow.columnDefinitions.map(\.name)
            return QueryResultSet(
                id: index,
                columns: columnNames,
                rows: rows.map { mysqlRow in
                    var values: [String: RowValue] = [:]
                    for definition in mysqlRow.columnDefinitions {
                        if let data = mysqlRow.column(definition.name) {
                            values[definition.name] = RowValue(mysqlData: data)
                        }
                    }
                    return TableRow(values: values)
                }
            )
        }

        guard let first = sets.first else {
            queryResultSets = []
            selectedResultSetIndex = 0
            isShowingQueryResult = false
            queryEditContext = nil
            if let affected = result.affectedRows {
                queryMessage = Self.affectedRowsMessage(affected)
            } else {
                queryMessage = String(localized: "Query completed, no results.")
            }
            return
        }

        queryResultSets = sets
        selectedResultSetIndex = 0
        isShowingQueryResult = true
        if sets.count > 1 {
            let total = sets.reduce(0) { $0 + $1.rows.count }
            queryMessage = String(localized: "\(sets.count) result sets returned, \(total) rows in total.")
        } else {
            queryMessage = String(localized: "\(first.rows.count) rows returned.")
        }
        // Editing is only ever offered for a single, simple single-table
        // SELECT — a multi-result `CALL` can't map a row back to one table.
        if sets.count == 1 {
            await resolveQueryEditContext(executedSQL: executedSQL, columnNames: first.columns)
        } else {
            queryEditContext = nil
        }
    }

    /// Also triggers `onQueryResultCleared` — the query that was just
    /// showing results may well have been a write, so the grid it's
    /// switching back to shouldn't show stale pre-query data.
    func clearQueryResult() async {
        isShowingQueryResult = false
        queryResultSets = []
        selectedResultSetIndex = 0
        queryMessage = nil
        queryEditContext = nil
        await onQueryResultCleared?()
    }

    /// Same reset as `clearQueryResult()`, minus the `onQueryResultCleared`
    /// callback — for when the sidebar selection is moving to a *different*
    /// table, whose own `TableDataGridView` already loads itself via its
    /// `.task(id:)`. Calling `clearQueryResult()` there raced that load:
    /// `onQueryResultCleared` is rebound to the new table the instant its
    /// view appears, so the awaited callback landed on the new view's
    /// model too, firing a second concurrent query over the same
    /// connection — mysql-nio only tolerates one at a time and asserted
    /// "Statement not closed", crashing the app. Synchronous and
    /// callback-free closes that race entirely.
    func resetQueryResultForTableSwitch() {
        isShowingQueryResult = false
        queryResultSets = []
        selectedResultSetIndex = 0
        queryMessage = nil
        queryEditContext = nil
    }

    func commitQueryResultEdit(rowId: TableRow.ID, column: String, newText: String) async {
        // `queryEditContext` is only ever non-nil for a single result set
        // (see `applyResult`), so editing always targets set 0.
        guard let context = queryEditContext, isQueryResultEditableRequested,
              !queryResultSets.isEmpty,
              let index = queryResultSets[0].rows.firstIndex(where: { $0.id == rowId }) else { return }
        queryResultSets[0].rows[index].editedText[column] = newText
        guard queryResultSets[0].rows[index].isDirty(column) else { return }

        do {
            try await updateQueryResultRow(queryResultSets[0].rows[index], changedColumn: column, context: context)
            queryResultSets[0].rows[index].acceptEdits(for: [column])
            queryErrorMessage = nil
        } catch {
            queryErrorMessage = describe(error)
        }
    }

    func deleteQueryResultRow(_ row: TableRow) async {
        guard let context = queryEditContext, isQueryResultEditableRequested else { return }
        do {
            let (whereSQL, whereBinds) = try primaryKeyWhereClause(for: row, primaryKeyColumns: context.primaryKeyColumns)
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: context.database, name: context.table)
            let sql = "DELETE FROM \(qualified) WHERE \(whereSQL)"
            historyRecorder?.record(sql, binds: whereBinds, database: context.database, source: .app)
            try await service.execute(sql, whereBinds)
            await runQuery()
        } catch {
            queryErrorMessage = describe(error)
        }
    }

    private func updateQueryResultRow(_ row: TableRow, changedColumn: String, context: QueryEditContext) async throws {
        let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: context.database, name: context.table)
        let columnInfo = context.columns.first(where: { $0.name == changedColumn })
        let text = row.editedText[changedColumn] ?? ""
        let value: MySQLData = (text.isEmpty && (columnInfo?.isNullable ?? false)) ? .null : MySQLData(string: text)
        let setClause = "\(try SchemaIntrospectionService.quotedIdentifier(changedColumn)) = ?"
        let (whereSQL, whereBinds) = try primaryKeyWhereClause(for: row, primaryKeyColumns: context.primaryKeyColumns)
        let sql = "UPDATE \(qualified) SET \(setClause) WHERE \(whereSQL)"
        let binds = [value] + whereBinds
        historyRecorder?.record(sql, binds: binds, database: context.database, source: .app)
        try await service.execute(sql, binds)
    }

    /// Deliberately conservative: only recognizes `SELECT ... FROM
    /// [\`db\`.]\`table\` [WHERE/ORDER/LIMIT ...]` with no JOIN/UNION/second
    /// table. False negatives just fall back to read-only (safe); this
    /// never needs to be a real SQL parser for that reason.
    private func detectSingleTableSelect(_ sql: String) -> (database: String, table: String)? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^select\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        guard trimmed.range(of: #"\b(join|union)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        guard let fromRange = trimmed.range(of: #"\bfrom\b"#, options: [.regularExpression, .caseInsensitive]) else { return nil }

        let afterFrom = trimmed[fromRange.upperBound...]
        guard let identifierRange = afterFrom.range(
            of: #"^\s*(`[^`]+`|\w+)(\.(`[^`]+`|\w+))?"#,
            options: .regularExpression
        ) else { return nil }

        let remainder = afterFrom[identifierRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !remainder.hasPrefix(",") else { return nil }

        let identifierText = afterFrom[identifierRange].trimmingCharacters(in: .whitespaces)
        let parts = identifierText.components(separatedBy: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
        switch parts.count {
        case 2: return (database: parts[0], table: parts[1])
        case 1:
            guard let currentDatabaseHint else { return nil }
            return (database: currentDatabaseHint, table: parts[0])
        default: return nil
        }
    }

    private func resolveQueryEditContext(executedSQL: String, columnNames: [String]) async {
        queryEditContext = nil
        guard let detected = detectSingleTableSelect(executedSQL) else { return }
        do {
            let pkColumns = try await introspection.primaryKeyColumnNames(forTable: detected.table, inDatabase: detected.database)
            guard !pkColumns.isEmpty, Set(pkColumns).isSubset(of: Set(columnNames)) else { return }
            let tableColumns = try await introspection.columns(forTable: detected.table, inDatabase: detected.database)
            let relevantColumns = tableColumns.filter { columnNames.contains($0.name) }
            queryEditContext = QueryEditContext(
                database: detected.database,
                table: detected.table,
                primaryKeyColumns: pkColumns,
                columns: relevantColumns
            )
        } catch {
            queryEditContext = nil
        }
    }

    private func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "\(mysqlError)"
        }
        return error.localizedDescription
    }

    /// `describe`, plus a nudge toward "Run All" when the failure is
    /// specifically "Run sent one packet bigger than the server accepts"
    /// *and* the script would actually split into several statements.
    ///
    /// "Run" deliberately sends the editor's text as a single statement, so
    /// a pasted multi-statement dump hits `max_allowed_packet` as one huge
    /// packet — while "Run All" splits it and sends each statement on its
    /// own, which is what the user wanted. The size check isn't enough on
    /// its own: a single oversized `INSERT` (one extended-values statement
    /// bigger than the limit) can't be helped by splitting, and suggesting
    /// it there would just send someone down a dead end.
    /// `describe`, plus whichever hint the specific failure earns — the
    /// server's own message says *what* broke, these say what to do about
    /// it. `serverVersion` is `MySQLService`'s cached `SELECT VERSION()`
    /// result, passed in rather than awaited here so this stays sync.
    private func describe(_ error: Error, sql: String, serverVersion: String?) -> String {
        var described = describe(error)
        guard case .server(let packet)? = error as? MySQLError else { return described }

        if packet.errorCode == .NET_PACKET_TOO_LARGE, let hint = Self.runAllHint(forFailedSQL: sql) {
            described += "\n" + hint
        }
        if packet.errorCode == .UNKNOWN_COLLATION,
           let hint = Self.unknownCollationHint(errorMessage: packet.errorMessage, serverVersion: serverVersion) {
            described += "\n" + hint
        }
        return described
    }

    /// The hint text, or `nil` when splitting wouldn't actually help.
    /// Internal (not private) so it can be tested without provoking a real
    /// oversized-packet error from a server.
    static func runAllHint(forFailedSQL sql: String) -> String? {
        guard DelimiterScript.allStatements(from: sql).count > 1 else { return nil }
        return String(localized: "This script holds several statements. \"Run\" sends them as one packet; use \"Run All\" to send them one at a time.")
    }

    /// Explains an `ER_UNKNOWN_COLLATION` in terms of the two servers
    /// involved. Restoring a MySQL 8 dump onto MariaDB is the common way
    /// to hit this — MySQL 8's default `utf8mb4_0900_*` collations don't
    /// exist in MariaDB at all — and the server's bare "Unknown collation"
    /// gives no hint that a *server mismatch* is the reason.
    ///
    /// Internal for testability: provoking a real one would mean depending
    /// on which server the test happens to run against, which is exactly
    /// the variable being described here.
    static func unknownCollationHint(errorMessage: String, serverVersion: String?) -> String? {
        guard let collation = errorMessage.firstMatch(of: /Unknown collation: '([^']+)'/)?.1 else { return nil }
        let collationName = String(collation)
        let server = serverVersion.map(Self.describeServer)

        // `utf8mb4_0900_ai_ci` and its siblings arrived with MySQL 8.0 and
        // have no MariaDB equivalent under that name, so this case can say
        // something much more specific than "not supported".
        if collationName.contains("_0900_") {
            if let server {
                return String(localized: "'\(collationName)' is a MySQL 8.0 collation, but this connection is to \(server). Replace it (utf8mb4_unicode_ci is the usual substitute) or restore into MySQL 8.0 or newer.")
            }
            return String(localized: "'\(collationName)' is a MySQL 8.0 collation. Replace it (utf8mb4_unicode_ci is the usual substitute) or restore into MySQL 8.0 or newer.")
        }
        if let server {
            return String(localized: "Collation '\(collationName)' does not exist on \(server). Replace it with one this server supports.")
        }
        return String(localized: "Collation '\(collationName)' does not exist on the server you are connected to. Replace it with one this server supports.")
    }

    /// `SELECT VERSION()`'s raw string as something worth showing a person:
    /// `"10.4.32-MariaDB"` → `"MariaDB 10.4.32"`, `"8.0.45-cll-lve"` →
    /// `"MySQL 8.0.45"`. MariaDB puts its name in that string; MySQL's
    /// suffix is a build tag, so anything without "MariaDB" is MySQL.
    static func describeServer(_ rawVersion: String) -> String {
        let number = rawVersion.split(separator: "-").first.map(String.init) ?? rawVersion
        let isMariaDB = rawVersion.localizedCaseInsensitiveContains("mariadb")
        return "\(isMariaDB ? "MariaDB" : "MySQL") \(number)"
    }
}
