import Foundation

/// Backs the "Alter Table" form: seeds the shared `DraftColumn` grid from
/// the table's live schema, then diffs the edited drafts against that
/// snapshot to produce a single `ALTER TABLE` statement — `DROP COLUMN` for
/// removed rows, `ADD COLUMN` for new ones, `CHANGE COLUMN` for renames/
/// redefinitions (which also covers keeping the comment intact), plus
/// DROP/ADD PRIMARY KEY and `RENAME TO` when those change.
@MainActor
final class AlterTableViewModel: ObservableObject {
    let database: String
    let originalTableName: String

    @Published var tableName: String
    @Published var columns: [DraftColumn] = []
    /// The standard picker list, extended with any server type the table
    /// actually uses that the list doesn't cover (ENUM, SET, …) — otherwise
    /// the picker couldn't even display the loaded value.
    @Published private(set) var availableDataTypes: [String] = CreateTableViewModel.dataTypes
    @Published private(set) var isLoading = true
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?

    /// Snapshot of the schema at load time, keyed by the column's server
    /// name — what the diff in `buildSQL` compares against.
    private var originalDraftsByName: [String: DraftColumn] = [:]
    private var originalColumnOrder: [String] = []

    private let service: MySQLService
    private let introspection: SchemaIntrospectionService
    /// Logs the DDL this form runs into the connection's query history.
    private let historyRecorder: QueryHistoryRecorder?

    init(service: MySQLService, table: TableInfo, historyRecorder: QueryHistoryRecorder? = nil) {
        self.service = service
        self.historyRecorder = historyRecorder
        self.introspection = SchemaIntrospectionService(service: service)
        self.database = table.database
        self.originalTableName = table.name
        self.tableName = table.name
    }

    /// Shown in place of the DDL while the form is untouched. Named
    /// (rather than inlined) so tests can assert against it without
    /// hardcoding a translated string.
    static var noChangesPreview: String { String(localized: "-- No changes yet --") }

    var previewSQL: String {
        do {
            return try buildSQL()
        } catch CreateTableError.noChanges {
            return Self.noChangesPreview
        } catch {
            return "-- \(error.localizedDescription) --"
        }
    }

    var canSubmit: Bool {
        !isSubmitting && !isLoading && (try? buildSQL()) != nil
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let infos = try await introspection.columns(forTable: originalTableName, inDatabase: database)
            let drafts = infos.map(DraftColumn.init(from:))
            columns = drafts
            originalDraftsByName = Dictionary(uniqueKeysWithValues: drafts.compactMap { draft in
                draft.originalName.map { ($0, draft) }
            })
            originalColumnOrder = infos.map(\.name)

            var types = CreateTableViewModel.dataTypes
            for draft in drafts where !types.contains(draft.dataType) {
                types.append(draft.dataType)
            }
            availableDataTypes = types
        } catch {
            errorMessage = String(localized: "Could not read table structure: \(error.localizedDescription)")
        }
    }

    /// Runs the generated `ALTER TABLE`; returns the table's (possibly
    /// renamed) info on success so the caller can refresh the sidebar and
    /// reselect it.
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
            errorMessage = String(localized: "Alter failed: \(error.localizedDescription)")
            return nil
        }

        return TableInfo(database: database, name: tableName.trimmingCharacters(in: .whitespaces), isView: false)
    }

    private func buildSQL() throws -> String {
        let trimmedTable = tableName.trimmingCharacters(in: .whitespaces)
        guard !trimmedTable.isEmpty else { throw CreateTableError.emptyTableName }
        let activeColumns = columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !activeColumns.isEmpty else { throw CreateTableError.noColumns }

        var clauses: [String] = []

        let keptOriginalNames = Set(activeColumns.compactMap(\.originalName))
        for name in originalColumnOrder where !keptOriginalNames.contains(name) {
            clauses.append("DROP COLUMN \(try SchemaIntrospectionService.quotedIdentifier(name))")
        }

        // PK membership is compared by column *identity* (original name
        // where one exists), so renaming a PK column alone doesn't read as
        // a key change, while moving the key to a different column does.
        let originalPK = Set(originalDraftsByName.values.filter(\.isPrimaryKey).compactMap(\.originalName))
        let newPKColumns = activeColumns.filter(\.isPrimaryKey)
        let newPKIdentity = Set(newPKColumns.map { $0.originalName ?? "\u{0}new:\($0.name)" })
        let primaryKeyChanged = originalPK != newPKIdentity
        if primaryKeyChanged, !originalPK.isEmpty {
            clauses.append("DROP PRIMARY KEY")
        }

        // Reorder support: kept columns on the longest common subsequence
        // of (original order) vs (new order) already sit in the right
        // relative order and need no position clause; everything else gets
        // an explicit FIRST/AFTER. Clauses apply left-to-right within one
        // ALTER, and drafts are processed in target order, so an AFTER can
        // safely name the *final* (possibly renamed, possibly just-added)
        // predecessor — by the time the clause runs, that predecessor is
        // already in place under that name.
        let originalKeptOrder = originalColumnOrder.filter { keptOriginalNames.contains($0) }
        let newKeptOrder = activeColumns.compactMap(\.originalName)
        let stablyOrdered = Set(Self.longestCommonSubsequence(originalKeptOrder, newKeptOrder))

        func positionSuffix(at index: Int) throws -> String {
            guard index > 0 else { return " FIRST" }
            let previousName = activeColumns[index - 1].name.trimmingCharacters(in: .whitespaces)
            return " AFTER \(try SchemaIntrospectionService.quotedIdentifier(previousName))"
        }

        for (index, draft) in activeColumns.enumerated() {
            if let originalName = draft.originalName, let original = originalDraftsByName[originalName] {
                let needsMove = !stablyOrdered.contains(originalName)
                if needsMove {
                    clauses.append("CHANGE COLUMN \(try SchemaIntrospectionService.quotedIdentifier(originalName)) \(try draft.sqlDefinition())\(try positionSuffix(at: index))")
                } else if !draft.describesSameColumn(as: original) {
                    clauses.append("CHANGE COLUMN \(try SchemaIntrospectionService.quotedIdentifier(originalName)) \(try draft.sqlDefinition())")
                }
            } else {
                // A plain ADD appends at the end, so new columns only need
                // a position when something *kept* comes after them.
                let isTailAppend = activeColumns[(index + 1)...].allSatisfy { $0.originalName == nil }
                let suffix = isTailAppend ? "" : try positionSuffix(at: index)
                clauses.append("ADD COLUMN \(try draft.sqlDefinition())\(suffix)")
            }
        }

        // After ADD COLUMN clauses, so a brand-new column can be (part of)
        // the new key.
        if primaryKeyChanged, !newPKColumns.isEmpty {
            let quotedNames = try newPKColumns.map {
                try SchemaIntrospectionService.quotedIdentifier($0.name.trimmingCharacters(in: .whitespaces))
            }
            clauses.append("ADD PRIMARY KEY (\(quotedNames.joined(separator: ", ")))")
        }

        if trimmedTable != originalTableName {
            clauses.append("RENAME TO \(try SchemaIntrospectionService.quotedIdentifier(trimmedTable))")
        }

        guard !clauses.isEmpty else { throw CreateTableError.noChanges }

        let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: database, name: originalTableName)
        return "ALTER TABLE \(qualified)\n  \(clauses.joined(separator: ",\n  "))"
    }

    /// Classic O(n·m) LCS — column counts are tiny. The elements on the LCS
    /// are exactly the columns whose relative order survived the user's
    /// reordering, i.e. the ones that don't need a FIRST/AFTER clause.
    nonisolated static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let n = a.count
        let m = b.count
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var result: [String] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                result.append(a[i])
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
