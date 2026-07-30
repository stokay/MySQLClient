import Foundation

/// Wraps a `SHOW CREATE PROCEDURE` definition into the `DELIMITER $$ ...
/// DELIMITER ;` statement the sidebar's "Alter Procedure" context-menu
/// action appends to the query console.
///
/// Unlike `ViewAlterStatement`, this doesn't reformat the body at all — a
/// view's body is exactly one `SELECT`, worth pretty-printing column by
/// column, but a procedure's body is arbitrary procedural SQL (loops,
/// conditionals, several statements). Reformatting that would mean
/// actually parsing MySQL's procedural-SQL grammar, not just a `SELECT`
/// list; copying the server's own text verbatim (already exactly what a
/// human wrote) is both simpler and safer. `MySQL` also doesn't support
/// changing a procedure's body in place — its real `ALTER PROCEDURE` only
/// touches characteristics like `COMMENT`/`SQL SECURITY` — so "altering" a
/// procedure always means drop-and-recreate, same as `ViewAlterStatement`.
enum ProcedureAlterStatement {
    static func format(database: String, name: String, createProcedure: String) -> String {
        [
            "DELIMITER $$",
            "",
            "USE `\(database)`$$",
            "",
            "DROP PROCEDURE IF EXISTS `\(name)`$$",
            "",
            "\(createProcedure)$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
    }
}
