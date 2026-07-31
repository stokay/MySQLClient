import XCTest
import MySQLNIO
@testable import MySQLMacClient

/// Pure string rendering — no database needed.
final class SQLStatementRendererTests: XCTestCase {
    func testFillsPlaceholdersInOrder() {
        let sql = "UPDATE `widgets` SET `quantity` = ? WHERE `id` = ?"
        let rendered = SQLStatementRenderer.render(sql, binds: [MySQLData(string: "42"), MySQLData(string: "7")])
        XCTAssertEqual(rendered, "UPDATE `widgets` SET `quantity` = '42' WHERE `id` = '7'")
    }

    func testNullBindRendersAsNULL() {
        let sql = "UPDATE `t` SET `notes` = ? WHERE `id` = ?"
        let rendered = SQLStatementRenderer.render(sql, binds: [.null, MySQLData(string: "1")])
        XCTAssertEqual(rendered, "UPDATE `t` SET `notes` = NULL WHERE `id` = '1'")
    }

    /// A value containing a quote must not be able to close the literal —
    /// the rendered entry is text the user may well re-run by hand.
    func testSingleQuotesInValuesAreEscaped() {
        let sql = "INSERT INTO `t` (`name`) VALUES (?)"
        let rendered = SQLStatementRenderer.render(sql, binds: [MySQLData(string: "O'Brien")])
        XCTAssertEqual(rendered, "INSERT INTO `t` (`name`) VALUES ('O''Brien')")
    }

    func testBackslashesInValuesAreEscaped() {
        let sql = "INSERT INTO `t` (`path`) VALUES (?)"
        let rendered = SQLStatementRenderer.render(sql, binds: [MySQLData(string: #"C:\temp"#)])
        XCTAssertEqual(rendered, #"INSERT INTO `t` (`path`) VALUES ('C:\\temp')"#)
    }

    /// A `?` that's part of data rather than a placeholder — inside a
    /// string literal — must be left alone, or the binds shift by one and
    /// every later value lands in the wrong column.
    func testQuestionMarkInsideAStringLiteralIsNotAPlaceholder() {
        let sql = "UPDATE `t` SET `note` = 'why?' WHERE `id` = ?"
        let rendered = SQLStatementRenderer.render(sql, binds: [MySQLData(string: "5")])
        XCTAssertEqual(rendered, "UPDATE `t` SET `note` = 'why?' WHERE `id` = '5'")
    }

    /// Same for a backtick-quoted identifier that happens to contain `?`.
    func testQuestionMarkInsideAnIdentifierIsNotAPlaceholder() {
        let sql = "SELECT `odd?column` FROM `t` WHERE `id` = ?"
        let rendered = SQLStatementRenderer.render(sql, binds: [MySQLData(string: "1")])
        XCTAssertEqual(rendered, "SELECT `odd?column` FROM `t` WHERE `id` = '1'")
    }

    func testStatementWithoutBindsIsUnchanged() {
        let sql = "DROP TABLE `widgets`"
        XCTAssertEqual(SQLStatementRenderer.render(sql, binds: []), sql)
    }

    /// Fewer binds than placeholders shouldn't crash or mis-shift; the
    /// unmatched `?` simply stays as-is.
    func testExtraPlaceholdersAreLeftAlone() {
        let sql = "UPDATE `t` SET `a` = ?, `b` = ? WHERE `id` = ?"
        let rendered = SQLStatementRenderer.render(sql, binds: [MySQLData(string: "1")])
        XCTAssertEqual(rendered, "UPDATE `t` SET `a` = '1', `b` = ? WHERE `id` = ?")
    }
}
