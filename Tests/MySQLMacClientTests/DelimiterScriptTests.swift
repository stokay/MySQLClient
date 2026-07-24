import XCTest
@testable import MySQLMacClient

/// Pure string splitting — no database needed.
final class DelimiterScriptTests: XCTestCase {
    func testReturnsNilWhenNoDelimiterDirectiveIsPresent() {
        XCTAssertNil(DelimiterScript.statements(from: "SELECT * FROM `t`;"))
        XCTAssertNil(DelimiterScript.statements(from: "INSERT INTO `t` (`a`) VALUES ('x');\nINSERT INTO `t` (`a`) VALUES ('y');"))
    }

    /// The exact shape "Alter View" produces: `USE`, `DROP VIEW IF EXISTS`,
    /// then a multi-line `CREATE VIEW`, each `$$`-terminated.
    func testSplitsAlterViewScriptIntoThreeStatements() {
        let script = [
            "DELIMITER $$",
            "",
            "USE `mydb`$$",
            "",
            "DROP VIEW IF EXISTS `test`$$",
            "",
            "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `test` AS ",
            "SELECT",
            "  `t`.`id` AS `id`",
            "FROM `t`$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")

        let statements = DelimiterScript.statements(from: script)
        XCTAssertEqual(statements, [
            "USE `mydb`",
            "DROP VIEW IF EXISTS `test`",
            "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `test` AS \nSELECT\n  `t`.`id` AS `id`\nFROM `t`",
        ])
    }

    /// A `CREATE PROCEDURE ... BEGIN ... END$$` body's internal `;`s must
    /// stay untouched — only the `$$` terminator ends the statement.
    func testPreservesSemicolonsInsideDelimiterTerminatedBody() {
        let script = [
            "DELIMITER $$",
            "",
            "CREATE PROCEDURE `p`()",
            "BEGIN",
            "    SELECT 1;",
            "    SELECT 2;",
            "END$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")

        let statements = DelimiterScript.statements(from: script)
        XCTAssertEqual(statements?.count, 1)
        XCTAssertEqual(statements?.first, "CREATE PROCEDURE `p`()\nBEGIN\n    SELECT 1;\n    SELECT 2;\nEND")
    }

    func testIgnoresBareDelimiterLineWithNoToken() {
        // Malformed input (no token after the keyword) shouldn't crash or
        // silently swallow the rest of the script.
        let script = "DELIMITER\nSELECT 1;"
        XCTAssertNil(DelimiterScript.statements(from: script))
    }
}
