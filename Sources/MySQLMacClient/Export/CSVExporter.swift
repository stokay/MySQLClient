import Foundation

/// Pure row/field formatting (unit-tested with literal fixtures) plus a
/// thin `write(...)` that streams straight to a `FileHandle` — one row at a
/// time, so exporting a large table never holds one giant `String` for the
/// whole file in memory.
enum CSVExporter {
    static func formatHeader(_ columnNames: [String], options: CSVExportOptions) -> String {
        columnNames.map { escapeField($0, options: options) }.joined(separator: options.fieldTerminator) + "\r\n"
    }

    static func formatRow(_ values: [RowValue], options: CSVExportOptions) -> String {
        values.map { escapeField(fieldText($0), options: options) }.joined(separator: options.fieldTerminator) + "\r\n"
    }

    /// The exported text for one value — deliberately not `RowValue
    /// .displayString`, which renders NULL as an empty string with no way
    /// to tell it apart from a genuinely empty value. CSV itself has no
    /// separate NULL marker, so NULL still ends up as an empty field here;
    /// that's the format's own limitation (matches this app's own
    /// empty-text-means-NULL convention on the way back in), not something
    /// this exporter can improve on.
    private static func fieldText(_ value: RowValue) -> String {
        switch value {
        case .null: return ""
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .date(let value): return RowValue.dateFormatter.string(from: value)
        case .blob(let value): return value.base64EncodedString()
        }
    }

    /// Wraps `raw` in `fieldEnclosure` when it contains the terminator, the
    /// enclosure itself, or a line break, escaping any embedded enclosure
    /// occurrence with `fieldEscape` (or by doubling it, RFC 4180-style, if
    /// no escape character is configured).
    static func escapeField(_ raw: String, options: CSVExportOptions) -> String {
        guard !options.fieldEnclosure.isEmpty else { return raw }
        let needsQuoting = raw.contains(options.fieldTerminator)
            || raw.contains(options.fieldEnclosure)
            || raw.contains("\n") || raw.contains("\r")
        guard needsQuoting else { return raw }

        let escapedEnclosure = options.fieldEscape.isEmpty
            ? options.fieldEnclosure + options.fieldEnclosure
            : options.fieldEscape + options.fieldEnclosure
        let escaped = raw.replacingOccurrences(of: options.fieldEnclosure, with: escapedEnclosure)
        return options.fieldEnclosure + escaped + options.fieldEnclosure
    }

    static func write(
        columns: [ColumnInfo],
        rows: [[RowValue]],
        options: CSVExportOptions,
        to fileHandle: FileHandle
    ) throws {
        if options.includeHeaderRow {
            fileHandle.write(Data(formatHeader(columns.map(\.name), options: options).utf8))
        }
        for row in rows {
            fileHandle.write(Data(formatRow(row, options: options).utf8))
        }
    }
}
