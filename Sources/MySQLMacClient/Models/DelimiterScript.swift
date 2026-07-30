import Foundation

/// Splits a `DELIMITER $$ ... $$ DELIMITER ;`-style script (the shape the
/// sidebar's "Oluştur ▸ Stored Procedure/Function/Trigger/Event" templates
/// and the "Alter View" action both produce) into the individual statements
/// the query console needs to run.
///
/// `DELIMITER` is a `mysql`-CLI-only directive, not real SQL — MySQL's wire
/// protocol has no such statement, so sending the literal text straight to
/// the server (as every other query the console runs does) fails with a
/// syntax error at `DELIMITER`. This mirrors what the real `mysql` CLI does
/// with the same script: track a current statement terminator (starting at
/// `;`), swap it whenever a `DELIMITER <token>` line is seen, and cut a new
/// statement out every time that terminator is hit at the end of a line.
enum DelimiterScript {
    /// `nil` when `script` has no `DELIMITER` line at all — the caller
    /// should fall back to sending it unmodified, exactly as before this
    /// existed, since every other kind of query the console runs (a plain
    /// `SELECT`, a hand-typed multi-line `INSERT`, …) must keep behaving
    /// identically. "Çalıştır" uses this: a `CREATE PROCEDURE`/`FUNCTION`/
    /// `TRIGGER` body with its own internal `;`s is only safe to send
    /// whole (today's behavior) when nothing here decides to split it —
    /// see `allStatements(from:)` for the always-split version "Tümünü
    /// Çalıştır" uses instead, and why *that* one carries a real caveat
    /// for exactly this case.
    static func statements(from script: String) -> [String]? {
        // `[ \t]`, not `\s` — this must only match a directive that's
        // complete on one line, matching `parseDelimiterDirective`'s
        // per-line check below (`\s` would let the token match across a
        // newline, e.g. treating a stray "DELIMITER" line as directive by
        // borrowing the next line's first word as its token).
        guard script.range(of: #"(?im)^[ \t]*DELIMITER[ \t]+\S+[ \t]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return allStatements(from: script)
    }

    /// Always splits — with a `DELIMITER` directive honored wherever one
    /// appears, defaulting to `;` everywhere else. Unlike `statements(from:)`,
    /// this never opts out just because the script has no `DELIMITER` line,
    /// which is exactly what "Tümünü Çalıştır" needs for a plain script like
    /// `USE db;\ncall proc();` — two independent statements with no
    /// `DELIMITER` in sight.
    ///
    /// The tradeoff: this has no `BEGIN…END` awareness (same as the real
    /// `mysql` CLI without `DELIMITER`), so a pasted `CREATE PROCEDURE`/
    /// `FUNCTION`/`TRIGGER` body that relies on being sent as one statement
    /// gets cut apart at its own internal `;`s instead of erroring clearly.
    /// That's why this isn't what the plain "Çalıştır" button uses.
    static func allStatements(from script: String) -> [String] {
        var statements: [String] = []
        var buffer = ""
        var currentDelimiter = ";"

        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if let newDelimiter = parseDelimiterDirective(trimmedLine) {
                currentDelimiter = newDelimiter
                continue
            }

            if !buffer.isEmpty { buffer += "\n" }
            buffer += String(line)

            let trimmedBuffer = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBuffer.hasSuffix(currentDelimiter) {
                let statement = String(trimmedBuffer.dropLast(currentDelimiter.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !statement.isEmpty {
                    statements.append(statement)
                }
                buffer = ""
            }
        }

        let leftover = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty {
            statements.append(leftover)
        }

        return statements
    }

    /// `"DELIMITER $$"` → `"$$"`, `"delimiter ;"` → `";"`. Requires at least
    /// one token after the keyword — a bare `"DELIMITER"` (or blank token)
    /// isn't a directive this can act on, so it's left for the surrounding
    /// statement accumulation to handle (harmlessly, as ordinary text).
    private static func parseDelimiterDirective(_ trimmedLine: String) -> String? {
        guard trimmedLine.lowercased().hasPrefix("delimiter ") else { return nil }
        let token = trimmedLine.dropFirst("delimiter ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}
