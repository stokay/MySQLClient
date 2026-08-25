import XCTest
@testable import MySQLMacClient

/// Pure string wrapping — no database needed. Same shape as
/// `RoutineAlterStatementTests`.
final class TriggerAlterStatementTests: XCTestCase {
    func testFormatWrapsTriggerInDelimiterBlockWithUseAndDrop() {
        let createTrigger = """
            CREATE DEFINER=`root`@`localhost` TRIGGER `demo_trigger` BEFORE INSERT ON `widgets`
            FOR EACH ROW
            BEGIN
                SET NEW.name = UPPER(NEW.name);
            END
            """

        let sql = TriggerAlterStatement.format(
            trigger: TriggerInfo(database: "mydb", name: "demo_trigger", table: "widgets", timing: "BEFORE", event: "INSERT"),
            createStatement: createTrigger
        )

        let expected = [
            "DELIMITER $$",
            "",
            "USE `mydb`$$",
            "",
            "DROP TRIGGER IF EXISTS `demo_trigger`$$",
            "",
            "CREATE DEFINER=`root`@`localhost` TRIGGER `demo_trigger` BEFORE INSERT ON `widgets`",
            "FOR EACH ROW",
            "BEGIN",
            "    SET NEW.name = UPPER(NEW.name);",
            "END$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
        XCTAssertEqual(sql, expected)
    }

    /// The body is copied verbatim, same rationale as
    /// `RoutineAlterStatementTests.testFormatDoesNotAlterTheRoutineBody` —
    /// MySQL has no `ALTER TRIGGER` that could change it in place.
    func testFormatDoesNotAlterTheTriggerBody() {
        let createTrigger = "CREATE TRIGGER `t` BEFORE INSERT ON `w`\nFOR EACH ROW\nBEGIN\n  SET NEW.x = 1;\nEND"
        let sql = TriggerAlterStatement.format(
            trigger: TriggerInfo(database: "db", name: "t", table: "w", timing: "BEFORE", event: "INSERT"),
            createStatement: createTrigger
        )
        XCTAssertTrue(sql.contains(createTrigger))
    }
}
