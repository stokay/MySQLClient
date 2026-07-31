import Foundation

/// Wraps a `SHOW CREATE PROCEDURE`/`FUNCTION` definition into the
/// `DELIMITER $$ ... DELIMITER ;` statement the sidebar's "Alter
/// Procedure"/"Alter Function" context-menu actions append to the query
/// console.
///
/// Unlike `ViewAlterStatement`, this doesn't reformat the body at all — a
/// view's body is exactly one `SELECT`, worth pretty-printing column by
/// column, but a routine's body is arbitrary procedural SQL (loops,
/// conditionals, several statements). Reformatting that would mean
/// actually parsing MySQL's procedural-SQL grammar, not just a `SELECT`
/// list; copying the server's own text verbatim (already exactly what a
/// human wrote) is both simpler and safer. MySQL also doesn't support
/// changing a routine's body in place — its real `ALTER PROCEDURE`/
/// `ALTER FUNCTION` only touches characteristics like `COMMENT`/`SQL
/// SECURITY` — so "altering" one always means drop-and-recreate, same as
/// `ViewAlterStatement`.
enum RoutineAlterStatement {
    static func format(routine: RoutineInfo, createStatement: String) -> String {
        [
            "DELIMITER $$",
            "",
            "USE `\(routine.database)`$$",
            "",
            "DROP \(routine.kind.sqlKeyword) IF EXISTS `\(routine.name)`$$",
            "",
            "\(createStatement)$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
    }
}
