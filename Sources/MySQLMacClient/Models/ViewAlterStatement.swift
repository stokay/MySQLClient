import Foundation

/// Reformats a MySQL `SHOW CREATE VIEW` definition (one compact line) into
/// the pretty-printed, `DELIMITER $$ ... $$ DELIMITER ;` statement the
/// sidebar's "Alter View" context-menu action appends to the query console
/// — one `SELECT` column per line with `AS` aliases vertically aligned,
/// `FROM`/`WHERE`/etc. each on their own line, the shape a DBA would
/// hand-format the definition into.
///
/// This is deliberately not a real SQL parser: it only needs to locate a
/// handful of top-level keywords and top-level commas in text MySQL itself
/// already regenerated (every identifier backtick-quoted, exactly one `AS`
/// per select-list column), so a depth/quote-aware scan is enough. Clause
/// *bodies* (the condition after `WHERE`, an expression before `AS`, …) are
/// copied verbatim — only the handful of clause keywords this reconstructs
/// itself (`SELECT`/`FROM`/`WHERE`/…) are normalized to uppercase; MySQL's
/// own casing inside e.g. a `WHERE` condition (`like` vs `LIKE`) is left
/// untouched rather than attempting a full keyword-aware re-caser.
///
/// Every scan below shares one index space by staying in `Substring` end to
/// end instead of copying slices back into fresh `String`s mid-parse —
/// `String.Index` values from a slice aren't valid offsets into a
/// newly-copied `String`, so mixing the two silently finds nothing (or the
/// wrong thing) instead of trapping.
enum ViewAlterStatement {
    static func format(database: String, view: String, createView: String) -> String {
        let statementBody: String
        let whole = Substring(createView)
        if let selectRange = firstTopLevelKeywordRange("select", in: whole, from: whole.startIndex) {
            let header = whole[whole.startIndex..<selectRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = whole[selectRange.lowerBound...]
            statementBody = "\(header) \n\(formatSelectBody(body))"
        } else {
            // Not the recognizable "CREATE VIEW ... AS select ..." shape —
            // fall back to the statement completely unformatted rather than
            // mangling something this scan can't make sense of.
            statementBody = createView
        }

        return [
            "DELIMITER $$",
            "",
            "USE `\(database)`$$",
            "",
            "DROP VIEW IF EXISTS `\(view)`$$",
            "",
            "\(statementBody)$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
    }

    /// `body` starts at the `select` keyword. Strips it, splits the
    /// select-list from whichever trailing clauses (`FROM`, `WHERE`, `GROUP
    /// BY`, `HAVING`, `ORDER BY`, `LIMIT`) are present, and reassembles
    /// everything with one column per line.
    private static func formatSelectBody(_ body: Substring) -> String {
        guard let selectKeyword = firstTopLevelKeywordRange("select", in: body, from: body.startIndex) else {
            return String(body)
        }
        let rest = body[selectKeyword.upperBound...]

        let clauseKeywords = ["from", "where", "group by", "having", "order by", "limit"]
        var boundaries: [(range: Range<Substring.Index>, keyword: String)] = []
        for keyword in clauseKeywords {
            if let range = firstTopLevelKeywordRange(keyword, in: rest, from: rest.startIndex) {
                boundaries.append((range, keyword.uppercased()))
            }
        }
        boundaries.sort { $0.range.lowerBound < $1.range.lowerBound }

        let selectListEnd = boundaries.first?.range.lowerBound ?? rest.endIndex
        let selectListText = rest[rest.startIndex..<selectListEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines = ["SELECT"]
        lines.append(formatColumnList(selectListText))

        for (index, boundary) in boundaries.enumerated() {
            let contentEnd = index + 1 < boundaries.count ? boundaries[index + 1].range.lowerBound : rest.endIndex
            let content = rest[boundary.range.upperBound..<contentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(boundary.keyword) \(content)")
        }

        return lines.joined(separator: "\n")
    }

    /// Splits the select-list on its top-level commas, splits each column
    /// on its top-level `AS`, then right-pads every expression to the
    /// longest one so every alias lines up in one vertical column.
    private static func formatColumnList(_ selectListText: String) -> String {
        let source = Substring(selectListText)
        let columns = splitTopLevel(source, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let parsed: [(expr: String, alias: String?)] = columns.map { column in
            let columnSlice = Substring(column)
            if let asRange = firstTopLevelKeywordRange("as", in: columnSlice, from: columnSlice.startIndex) {
                let expr = columnSlice[columnSlice.startIndex..<asRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let alias = columnSlice[asRange.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (expr, alias)
            }
            return (column, nil)
        }

        let maxExprLength = parsed.map(\.expr.count).max() ?? 0
        let formattedColumns = parsed.map { column -> String in
            let padding = String(repeating: " ", count: maxExprLength - column.expr.count)
            guard let alias = column.alias else { return column.expr }
            return "\(column.expr)\(padding) AS \(alias)"
        }

        return "  " + formattedColumns.joined(separator: ",\n  ")
    }

    // MARK: - Depth/quote-aware scanning

    /// The first occurrence of `keyword` (case-insensitive, possibly
    /// containing an internal space like "group by") that's a standalone
    /// word — not inside a backtick-quoted identifier, a single-quoted
    /// string literal, or a parenthesized group, i.e. at the statement's
    /// top syntactic level.
    private static func firstTopLevelKeywordRange(_ keyword: String, in text: Substring, from startIndex: Substring.Index) -> Range<Substring.Index>? {
        let lowerKeyword = keyword.lowercased()
        var depth = 0
        var inBacktick = false
        var inQuote = false
        var i = startIndex

        while i < text.endIndex {
            let c = text[i]
            if inBacktick {
                if c == "`" { inBacktick = false }
                i = text.index(after: i)
                continue
            }
            if inQuote {
                if c == "\\" {
                    i = text.index(after: i)
                    if i < text.endIndex { i = text.index(after: i) }
                    continue
                }
                if c == "'" { inQuote = false }
                i = text.index(after: i)
                continue
            }
            if c == "`" { inBacktick = true; i = text.index(after: i); continue }
            if c == "'" { inQuote = true; i = text.index(after: i); continue }
            if c == "(" { depth += 1; i = text.index(after: i); continue }
            if c == ")" { depth -= 1; i = text.index(after: i); continue }

            if depth == 0, let end = text.index(i, offsetBy: lowerKeyword.count, limitedBy: text.endIndex) {
                if text[i..<end].lowercased() == lowerKeyword {
                    let precededOK = i == text.startIndex || !isWordChar(text[text.index(before: i)])
                    let followedOK = end == text.endIndex || !isWordChar(text[end])
                    if precededOK && followedOK {
                        return i..<end
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Splits `text` on every occurrence of `separator` that sits outside a
    /// backtick-quoted identifier, a single-quoted string literal, or a
    /// parenthesized group — e.g. the top-level commas between select-list
    /// columns, not ones inside a nested `CONCAT(a, b)`.
    private static func splitTopLevel(_ text: Substring, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inBacktick = false
        var inQuote = false
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]
            if inBacktick {
                current.append(c)
                if c == "`" { inBacktick = false }
                i = text.index(after: i)
                continue
            }
            if inQuote {
                current.append(c)
                if c == "\\" {
                    i = text.index(after: i)
                    if i < text.endIndex {
                        current.append(text[i])
                        i = text.index(after: i)
                    }
                    continue
                }
                if c == "'" { inQuote = false }
                i = text.index(after: i)
                continue
            }
            if c == "`" { inBacktick = true; current.append(c); i = text.index(after: i); continue }
            if c == "'" { inQuote = true; current.append(c); i = text.index(after: i); continue }
            if c == "(" { depth += 1; current.append(c); i = text.index(after: i); continue }
            if c == ")" { depth -= 1; current.append(c); i = text.index(after: i); continue }
            if c == separator, depth == 0 {
                parts.append(current)
                current = ""
                i = text.index(after: i)
                continue
            }
            current.append(c)
            i = text.index(after: i)
        }
        parts.append(current)
        return parts
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
