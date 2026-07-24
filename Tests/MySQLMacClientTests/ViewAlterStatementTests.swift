import XCTest
@testable import MySQLMacClient

/// Pure string reformatting — no database needed. `createView` inputs below
/// are exactly what `SHOW CREATE VIEW` returns (verified against a real
/// MariaDB instance), already stripped of schema qualifiers by
/// `SchemaIntrospectionService.showCreateView`.
final class ViewAlterStatementTests: XCTestCase {
    func testFormatWrapsInDelimiterBlockWithUseAndDropView() {
        let createView = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `test` AS select `t`.`id` AS `id` from `t`"
        let sql = ViewAlterStatement.format(database: "mydb", view: "test", createView: createView)

        let expected = [
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
        XCTAssertEqual(sql, expected)
    }

    /// Mirrors the exact view (same column names) the "Alter View" feature
    /// was specified against, confirming the alignment padding lines up
    /// `AS` on every column against the longest expression.
    func testFormatAlignsMultipleColumnsAndPreservesWhereVerbatim() {
        let createView = """
        CREATE ALGORITHM=UNDEFINED DEFINER=`cantokay_st`@`%` SQL SECURITY DEFINER VIEW `test` AS select `ilceler_copy`.`ilce_id` AS `ilce_id`,`ilceler_copy`.`ilce_adi` AS `ilce_adi`,`ilceler_copy`.`ilce_adi_order_key` AS `ilce_adi_order_key`,`ilceler_copy`.`il_id` AS `il_id`,`ilceler_copy`.`il_adi` AS `il_adi` from `ilceler_copy` where `ilceler_copy`.`ilce_adi` like '%KÖY'
        """.trimmingCharacters(in: .whitespacesAndNewlines)

        let sql = ViewAlterStatement.format(database: "cantokay_adres_tr", view: "test", createView: createView)

        let expected = [
            "DELIMITER $$",
            "",
            "USE `cantokay_adres_tr`$$",
            "",
            "DROP VIEW IF EXISTS `test`$$",
            "",
            "CREATE ALGORITHM=UNDEFINED DEFINER=`cantokay_st`@`%` SQL SECURITY DEFINER VIEW `test` AS ",
            "SELECT",
            "  `ilceler_copy`.`ilce_id`            AS `ilce_id`,",
            "  `ilceler_copy`.`ilce_adi`           AS `ilce_adi`,",
            "  `ilceler_copy`.`ilce_adi_order_key` AS `ilce_adi_order_key`,",
            "  `ilceler_copy`.`il_id`              AS `il_id`,",
            "  `ilceler_copy`.`il_adi`             AS `il_adi`",
            "FROM `ilceler_copy`",
            "WHERE `ilceler_copy`.`ilce_adi` like '%KÖY'$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
        XCTAssertEqual(sql, expected)
    }

    /// A comma inside a function call's arguments must not be mistaken for
    /// a select-list separator.
    func testFormatDoesNotSplitCommasInsideNestedParentheses() {
        let createView = "CREATE VIEW `v` AS select concat(`a`.`x`, `a`.`y`) AS `combined`, `a`.`z` AS `z` from `a`"
        let sql = ViewAlterStatement.format(database: "db", view: "v", createView: createView)

        XCTAssertTrue(sql.contains("concat(`a`.`x`, `a`.`y`) AS `combined`,"))
        XCTAssertTrue(sql.contains("`a`.`z`                  AS `z`"))
    }

    /// A `WHERE` condition containing the literal substring "from" (inside
    /// a string literal) must not be mistaken for the `FROM` keyword.
    func testFormatIgnoresKeywordLikeSubstringsInsideStringLiterals() {
        let createView = "CREATE VIEW `v` AS select `a`.`x` AS `x` from `a` where `a`.`label` = 'from here'"
        let sql = ViewAlterStatement.format(database: "db", view: "v", createView: createView)

        XCTAssertTrue(sql.contains("FROM `a`"))
        XCTAssertTrue(sql.contains("WHERE `a`.`label` = 'from here'"))
        // Only one FROM line should have been produced.
        XCTAssertEqual(sql.components(separatedBy: "FROM ").count, 2)
    }

    /// Statements this scan can't make sense of (no top-level `select`
    /// found) fall back to the raw text unformatted rather than mangling it.
    func testFormatFallsBackToRawTextWhenNoSelectKeywordIsFound() {
        let createView = "CREATE VIEW `v` AS TABLE `other_view`"
        let sql = ViewAlterStatement.format(database: "db", view: "v", createView: createView)

        XCTAssertTrue(sql.contains("CREATE VIEW `v` AS TABLE `other_view`$$"))
    }
}
