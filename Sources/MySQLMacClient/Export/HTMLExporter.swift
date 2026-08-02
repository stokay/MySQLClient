import Foundation

/// A minimal, self-contained `<table>` document — no external CSS, no
/// dependency on anything else being on disk next to the exported file.
enum HTMLExporter {
    static func documentHeader(tableName: String, columnNames: [String]) -> String {
        let headerCells = columnNames.map { "<th>\(escape($0))</th>" }.joined()
        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><title>\(escape(tableName))</title></head>
        <body>
        <table border="1" cellspacing="0" cellpadding="4">
        <thead><tr>\(headerCells)</tr></thead>
        <tbody>

        """
    }

    static func formatRow(_ values: [RowValue]) -> String {
        let cells = values.map { "<td>\(escape(cellText($0)))</td>" }.joined()
        return "<tr>\(cells)</tr>\n"
    }

    static func documentFooter() -> String {
        """
        </tbody>
        </table>
        </body>
        </html>
        """
    }

    /// Deliberately not `RowValue.displayString` — see `CSVExporter
    /// .fieldText`'s identical rationale (NULL must not collapse into an
    /// indistinguishable empty string, `.blob` needs real bytes not a
    /// placeholder). HTML has no NULL marker any more than CSV does, so
    /// NULL still renders as an empty cell.
    private static func cellText(_ value: RowValue) -> String {
        switch value {
        case .null: return ""
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .date(let value): return RowValue.dateFormatter.string(from: value)
        case .blob(let value): return value.base64EncodedString()
        }
    }

    /// `&` first — replacing `<`/`>` afterward can't introduce a stray `&`
    /// for this pass to double-escape, but doing `&` second would mangle
    /// the entities this same call just produced.
    static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func write(
        tableName: String,
        columns: [ColumnInfo],
        rows: [[RowValue]],
        to fileHandle: FileHandle
    ) throws {
        fileHandle.write(Data(documentHeader(tableName: tableName, columnNames: columns.map(\.name)).utf8))
        for row in rows {
            fileHandle.write(Data(formatRow(row).utf8))
        }
        fileHandle.write(Data(documentFooter().utf8))
    }
}
