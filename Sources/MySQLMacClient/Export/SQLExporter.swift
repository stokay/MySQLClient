import Foundation

/// Schema + data: a `CREATE TABLE IF NOT EXISTS` (built from the server's
/// own `SHOW CREATE TABLE` output — see `SchemaIntrospectionService
/// .showCreateTable`, reusing its exact DDL rather than reconstructing one,
/// the same convention `showCreateView`/`showCreateRoutine` already use)
/// followed by one `INSERT INTO` statement per row.
enum SQLExporter {
    /// Swaps the leading `CREATE TABLE` for `CREATE TABLE IF NOT EXISTS` and
    /// terminates the statement — `SHOW CREATE TABLE`'s own output has
    /// neither the `IF NOT EXISTS` clause nor a trailing `;`.
    static func createTableStatement(rawShowCreateTable: String) -> String {
        guard let range = rawShowCreateTable.range(of: "CREATE TABLE ") else {
            return rawShowCreateTable + ";"
        }
        var result = rawShowCreateTable
        result.replaceSubrange(range, with: "CREATE TABLE IF NOT EXISTS ")
        return result + ";"
    }

    /// A view's SQL export is just its (re-runnable) definition — unlike a
    /// table, a view has no data of its own to freeze as `INSERT`
    /// statements; re-running the view's own query is what reproduces its
    /// rows, and most views aren't even `INSERT`-able in the first place.
    ///
    /// `SHOW CREATE VIEW`'s raw output already starts with `CREATE
    /// [ALGORITHM=...] [DEFINER=...] [SQL SECURITY ...] VIEW ...` — `OR
    /// REPLACE` is spliced in right after the leading `CREATE ` so
    /// re-running the exported file redefines the view instead of failing
    /// on "view already exists".
    static func createViewStatement(rawShowCreateView: String) -> String {
        guard let range = rawShowCreateView.range(of: "CREATE ") else {
            return rawShowCreateView + ";"
        }
        var result = rawShowCreateView
        result.replaceSubrange(range, with: "CREATE OR REPLACE ")
        return result + ";"
    }

    /// One row, one statement — not a batched multi-row `VALUES (...),(...)`
    /// list. Simpler, keeps this function pure/single-purpose, and matches
    /// the HeidiSQL-style export this dialog is modeled on.
    static func insertStatement(
        database: String,
        table: String,
        columns: [ColumnInfo],
        values: [RowValue]
    ) -> String {
        let qualified = "`\(database)`.`\(table)`"
        let columnList = columns.map { "`\($0.name)`" }.joined(separator: ", ")
        let valueList = values.map(sqlLiteral).joined(separator: ", ")
        return "INSERT INTO \(qualified) (\(columnList)) VALUES (\(valueList));"
    }

    private static func sqlLiteral(_ value: RowValue) -> String {
        switch value {
        case .null: return "NULL"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return "'\(escapeStringLiteral(value))'"
        case .date(let value): return "'\(escapeStringLiteral(RowValue.dateFormatter.string(from: value)))'"
        case .blob(let value): return hexLiteral(value)
        }
    }

    /// Backslash first, then the quote — doubling the quote after
    /// backslash-escaping is safe (MySQL accepts both escaping styles for a
    /// literal quote simultaneously), whereas the reverse order would
    /// re-mangle the backslashes this same pass just inserted.
    static func escapeStringLiteral(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    /// MySQL's native binary literal syntax — used for `.blob` values
    /// rather than trying to force raw bytes through a quoted string.
    static func hexLiteral(_ data: Data) -> String {
        guard !data.isEmpty else { return "X''" }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return "X'\(hex)'"
    }

    static func write(
        database: String,
        table: String,
        createTableSQL: String,
        columns: [ColumnInfo],
        rows: [[RowValue]],
        to fileHandle: FileHandle
    ) throws {
        fileHandle.write(Data((createTableSQL + "\n\n").utf8))
        for row in rows {
            let statement = insertStatement(database: database, table: table, columns: columns, values: row)
            fileHandle.write(Data((statement + "\n").utf8))
        }
    }
}
