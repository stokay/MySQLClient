import Foundation
import MySQLNIO

/// Fills a parameterized statement's `?` placeholders back in with the
/// values that were bound to them, so the query history shows
/// `UPDATE widgets SET quantity = '42' WHERE id = '7'` rather than the
/// unreadable `UPDATE widgets SET quantity = ? WHERE id = ?`.
///
/// This is for *display and recall* — the statement the server actually
/// ran was the parameterized one, which is what keeps values from being
/// interpreted as SQL in the first place. The rendering here still quotes
/// and escapes properly so a recalled entry is safe to re-run by hand.
enum SQLStatementRenderer {
    static func render(_ sql: String, binds: [MySQLData]) -> String {
        guard !binds.isEmpty else { return sql }

        var rendered = ""
        var bindIndex = 0
        var inSingleQuote = false
        var inBacktick = false
        var index = sql.startIndex

        while index < sql.endIndex {
            let character = sql[index]

            if inSingleQuote {
                rendered.append(character)
                if character == "\\" {
                    // Escaped character inside a literal — copy both so a
                    // `\'` doesn't look like the literal ending.
                    index = sql.index(after: index)
                    if index < sql.endIndex {
                        rendered.append(sql[index])
                        index = sql.index(after: index)
                    }
                    continue
                }
                if character == "'" { inSingleQuote = false }
                index = sql.index(after: index)
                continue
            }

            if inBacktick {
                rendered.append(character)
                if character == "`" { inBacktick = false }
                index = sql.index(after: index)
                continue
            }

            switch character {
            case "'":
                inSingleQuote = true
                rendered.append(character)
            case "`":
                inBacktick = true
                rendered.append(character)
            case "?" where bindIndex < binds.count:
                // Only placeholders outside quotes/identifiers are real
                // parameters; a `?` inside a LIKE pattern is data.
                rendered.append(literal(binds[bindIndex]))
                bindIndex += 1
            default:
                rendered.append(character)
            }
            index = sql.index(after: index)
        }

        return rendered
    }

    /// SQL literal for one bound value. `NULL` for a null bind; everything
    /// else is rendered as a quoted string — the app binds values as
    /// strings and lets MySQL coerce, so re-running a rendered statement
    /// behaves the same way the original did.
    private static func literal(_ data: MySQLData) -> String {
        guard data.buffer != nil, let text = data.string else { return "NULL" }
        // Backslash first: escaping the quotes first would then double the
        // backslashes this step introduces.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }
}
