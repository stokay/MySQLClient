import Foundation
import MySQLNIO

/// Native Swift representation of a `MySQLData` cell, used for display and
/// for detecting whether an edited cell actually changed.
enum RowValue: Equatable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
    case date(Date)
    /// A `TEXT`-family column's contents. Separate from `.string` because
    /// the two are shown very differently: a `VARCHAR` belongs inline in the
    /// grid, while a `TEXT` holding several paragraphs would drag its row's
    /// height over the neighbouring ones, so it shows a `<N bytes>`
    /// placeholder and opens in the value editor instead. Everything that
    /// consumes the *content* rather than the presentation — every exporter,
    /// the write-back encoding — treats it exactly like `.string`.
    case text(String)
    case blob(Data)

    /// MySQL DATETIME/TIMESTAMP has no timezone; MySQLNIO decodes/encodes it as GMT.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Text shown in the grid and used as the starting point for editing.
    /// Empty string is used for NULL so an emptied cell round-trips back to NULL.
    var displayString: String {
        switch self {
        case .null: return ""
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .date(let value): return Self.dateFormatter.string(from: value)
        case .text(let value): return "<\(value.utf8.count) bytes>"
        case .blob(let value): return "<\(value.count) bytes>"
        }
    }

    /// The content behind a `<N bytes>` placeholder, when it is something a
    /// person can meaningfully edit as text. `nil` for binary blobs: their
    /// bytes are not text, and round-tripping them through a text editor
    /// would corrupt them.
    var editableText: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    /// Whether the grid should show this as a placeholder that opens the
    /// value editor rather than editing it inline.
    var isLargeObject: Bool {
        switch self {
        case .text, .blob: return true
        default: return false
        }
    }

    /// Bind-ready encoding for writing this value back to MySQL — shared by
    /// the main grid and the query-result grid, both of which rebuild a
    /// row's original values into a `WHERE` clause via
    /// `primaryKeyWhereClause(for:primaryKeyColumns:)`.
    var mysqlData: MySQLData {
        switch self {
        case .null: return .null
        case .int(let value): return MySQLData(string: String(value))
        case .double(let value): return MySQLData(string: String(value))
        case .string(let value): return MySQLData(string: value)
        case .date(let value): return MySQLData(string: RowValue.dateFormatter.string(from: value))
        case .text(let value): return MySQLData(string: value)
        case .blob(let value): return MySQLData(string: String(decoding: value, as: UTF8.self))
        }
    }

    init(mysqlData: MySQLData) {
        guard mysqlData.buffer != nil else {
            self = .null
            return
        }
        switch mysqlData.type {
        case .tiny, .short, .long, .longlong, .int24, .bit, .year:
            if let value = mysqlData.int64 {
                self = .int(value)
            } else {
                self = .string(mysqlData.string ?? "")
            }
        case .float, .double, .newdecimal, .decimal:
            if let value = mysqlData.double {
                self = .double(value)
            } else {
                self = .string(mysqlData.string ?? "")
            }
        case .date, .datetime, .timestamp, .time:
            if let value = mysqlData.date {
                self = .date(value)
            } else {
                self = .string(mysqlData.string ?? "")
            }
        case .blob, .tinyBlob, .mediumBlob, .longBlob:
            // MySQL gives `TEXT`/`TINYTEXT`/`MEDIUMTEXT`/`LONGTEXT` the same
            // wire type codes as their `BLOB` counterparts — the only thing
            // separating them is the column's character set (`binary` for a
            // real BLOB, a text charset otherwise), which `MySQLData` does
            // not carry. Taking the type code at face value therefore made
            // every `TEXT` column render as "<N bytes>", uneditable in the
            // grid and base64/hex-encoded in every export.
            //
            // A *strict* UTF-8 decode is the practical stand-in: `TEXT`
            // content always decodes, and genuinely binary payloads
            // (images, compressed data) essentially never do.
            //
            // `String(data:encoding:.utf8)`, not `MySQLData.string` — the
            // latter goes through `ByteBuffer.readString`, which decodes
            // with `String(decoding:as:)` and so *never* fails: invalid
            // bytes come back as U+FFFD instead of `nil`. Classifying on
            // that would call every BLOB text, render it as mojibake, and —
            // far worse — write those replacement characters back over the
            // real bytes the first time the row was edited. Valid UTF-8, by
            // contrast, round-trips byte-identically through `.string`.
            if let buffer = mysqlData.buffer {
                let data = Data(buffer.readableBytesView)
                if let string = String(data: data, encoding: .utf8) {
                    self = .text(string)
                } else {
                    self = .blob(data)
                }
            } else {
                self = .null
            }
        default:
            self = .string(mysqlData.string ?? "")
        }
    }
}
