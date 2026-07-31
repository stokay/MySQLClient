import XCTest
@testable import MySQLMacClient

/// Pure string wrapping — no database needed.
final class RoutineAlterStatementTests: XCTestCase {
    func testFormatWrapsProcedureInDelimiterBlockWithUseAndDrop() {
        let createProcedure = """
            CREATE DEFINER=`root`@`localhost` PROCEDURE `demo_proc`(IN newQuantity INT)
            BEGIN
                UPDATE widgets SET quantity = newQuantity WHERE name = 'Bolt';
                SELECT ROW_COUNT() AS affected;
            END
            """

        let sql = RoutineAlterStatement.format(
            routine: RoutineInfo(database: "mydb", name: "demo_proc", kind: .procedure),
            createStatement: createProcedure
        )

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

    /// A function differs only by the `DROP` keyword — the same wrapper has
    /// to emit `DROP FUNCTION`, not `DROP PROCEDURE`, or the generated
    /// script fails against a same-named routine of the other kind.
    func testFormatUsesTheFunctionKeywordForAFunction() {
        let createFunction = """
            CREATE DEFINER=`root`@`localhost` FUNCTION `ilce_count`(p_il_id INT) RETURNS int(11)
                READS SQL DATA
            BEGIN
                RETURN 1;
            END
            """

        let sql = RoutineAlterStatement.format(
            routine: RoutineInfo(database: "mydb", name: "ilce_count", kind: .function),
            createStatement: createFunction
        )

        XCTAssertTrue(sql.contains("DROP FUNCTION IF EXISTS `ilce_count`$$"))
        XCTAssertFalse(sql.contains("DROP PROCEDURE"))
        XCTAssertTrue(sql.contains("USE `mydb`$$"))
    }

    /// The body is copied verbatim — internal semicolons, casing,
    /// whitespace, all untouched. This is the whole point: no attempt to
    /// parse or reformat procedural SQL.
    func testFormatDoesNotAlterTheRoutineBody() {
        let createProcedure = "CREATE PROCEDURE `p`()\nBEGIN\n  SELECT 1;\nEND"
        let sql = RoutineAlterStatement.format(
            routine: RoutineInfo(database: "db", name: "p", kind: .procedure),
            createStatement: createProcedure
        )
        XCTAssertTrue(sql.contains(createProcedure))
    }

    /// A procedure and a function may share a name in the same database, so
    /// identity has to include the kind — otherwise the two sidebar rows
    /// collide in SwiftUI's `ForEach`.
    func testRoutineIdentityIncludesKind() {
        let procedure = RoutineInfo(database: "db", name: "same", kind: .procedure)
        let function = RoutineInfo(database: "db", name: "same", kind: .function)
        XCTAssertNotEqual(procedure.id, function.id)
    }
}
