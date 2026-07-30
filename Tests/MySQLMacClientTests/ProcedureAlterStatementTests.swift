import XCTest
@testable import MySQLMacClient

/// Pure string wrapping — no database needed.
final class ProcedureAlterStatementTests: XCTestCase {
    func testFormatWrapsInDelimiterBlockWithUseAndDropProcedure() {
        let createProcedure = """
            CREATE DEFINER=`root`@`localhost` PROCEDURE `demo_proc`(IN newQuantity INT)
            BEGIN
                UPDATE widgets SET quantity = newQuantity WHERE name = 'Bolt';
                SELECT ROW_COUNT() AS affected;
            END
            """

        let sql = ProcedureAlterStatement.format(database: "mydb", name: "demo_proc", createProcedure: createProcedure)

        let expected = [
            "DELIMITER $$",
            "",
            "USE `mydb`$$",
            "",
            "DROP PROCEDURE IF EXISTS `demo_proc`$$",
            "",
            "CREATE DEFINER=`root`@`localhost` PROCEDURE `demo_proc`(IN newQuantity INT)",
            "BEGIN",
            "    UPDATE widgets SET quantity = newQuantity WHERE name = 'Bolt';",
            "    SELECT ROW_COUNT() AS affected;",
            "END$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
        XCTAssertEqual(sql, expected)
    }

    /// The body is copied verbatim — internal semicolons, casing,
    /// whitespace, all untouched. This is the whole point: no attempt to
    /// parse or reformat procedural SQL.
    func testFormatDoesNotAlterTheProcedureBody() {
        let createProcedure = "CREATE PROCEDURE `p`()\nBEGIN\n  SELECT 1;\nEND"
        let sql = ProcedureAlterStatement.format(database: "db", name: "p", createProcedure: createProcedure)
        XCTAssertTrue(sql.contains(createProcedure))
    }
}
