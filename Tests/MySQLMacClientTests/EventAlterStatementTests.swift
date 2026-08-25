import XCTest
@testable import MySQLMacClient

/// Pure string wrapping — no database needed. Same shape as
/// `TriggerAlterStatementTests`.
final class EventAlterStatementTests: XCTestCase {
    func testFormatWrapsEventInDelimiterBlockWithUseAndDrop() {
        let createEvent = """
            CREATE DEFINER=`root`@`localhost` EVENT `demo_event` ON SCHEDULE EVERY 1 DAY DISABLE DO
            BEGIN
                DELETE FROM widget_logs_nopk WHERE created_at < NOW() - INTERVAL 30 DAY;
            END
            """

        let sql = EventAlterStatement.format(
            event: EventInfo(database: "mydb", name: "demo_event", status: "DISABLED"),
            createStatement: createEvent
        )

        let expected = [
            "DELIMITER $$",
            "",
            "USE `mydb`$$",
            "",
            "DROP EVENT IF EXISTS `demo_event`$$",
            "",
            "CREATE DEFINER=`root`@`localhost` EVENT `demo_event` ON SCHEDULE EVERY 1 DAY DISABLE DO",
            "BEGIN",
            "    DELETE FROM widget_logs_nopk WHERE created_at < NOW() - INTERVAL 30 DAY;",
            "END$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
        XCTAssertEqual(sql, expected)
    }

    func testFormatDoesNotAlterTheEventBody() {
        let createEvent = "CREATE EVENT `e` ON SCHEDULE EVERY 1 DAY DO\nBEGIN\n  SELECT 1;\nEND"
        let sql = EventAlterStatement.format(
            event: EventInfo(database: "db", name: "e", status: "ENABLED"),
            createStatement: createEvent
        )
        XCTAssertTrue(sql.contains(createEvent))
    }
}
