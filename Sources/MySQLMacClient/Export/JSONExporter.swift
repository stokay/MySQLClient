import Foundation

/// A top-level JSON array of row objects, keyed by column name. Hand-rolled
/// rather than built on `JSONEncoder`/`JSONSerialization` — `RowValue`'s
/// cases need type-correct output (`.null` as the `null` literal, `.int`/
/// `.double` unquoted, everything else a quoted string), which is simplest
/// to control directly rather than bridging through `Any`/`Encodable`.
enum JSONExporter {
    /// One row as a JSON object literal — no trailing newline or comma;
    /// `write(...)` sequences those between rows.
    static func formatRow(_ columns: [ColumnInfo], _ values: [RowValue]) -> String {
        let pairs = zip(columns, values).map { column, value in
            "\"\(escapeString(column.name))\":\(jsonLiteral(value))"
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    private static func jsonLiteral(_ value: RowValue) -> String {
        switch value {
        case .null: return "null"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return "\"\(escapeString(value))\""
        case .date(let value): return "\"\(escapeString(RowValue.dateFormatter.string(from: value)))\""
        case .blob(let value): return "\"\(value.base64EncodedString())\""
        }
    }

    /// RFC 8259 string escaping — `"`, `\`, the named short escapes, and
    /// every other control character as `\u00XX`.
    static func escapeString(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    static func write(
        columns: [ColumnInfo],
        rows: [[RowValue]],
        to fileHandle: FileHandle
    ) throws {
        fileHandle.write(Data("[\n".utf8))
        for (index, row) in rows.enumerated() {
            let suffix = index == rows.count - 1 ? "\n" : ",\n"
            fileHandle.write(Data((formatRow(columns, row) + suffix).utf8))
        }
        fileHandle.write(Data("]\n".utf8))
    }
}
