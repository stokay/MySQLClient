import XCTest
@testable import MySQLMacClient

/// Pure logic — no database. A server numbers the lines of a syntax error
/// from the start of the text it was sent; these cover turning that back
/// into a line of the editor when only part of the editor was sent.
@MainActor
final class SQLConsoleErrorLineTests: XCTestCase {
    private let syntaxError = "MySQL error: Invalid syntax: You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'SETA NAMES utf8mb4' at line 5"

    /// The reported case: lines 10–14 of the editor were run, the mistake
    /// was on the last of them, and the message said "line 5".
    func testErrorLineIsShiftedByTheLinesAboveWhatWasSent() {
        let relocated = SQLConsoleViewModel.relocatingErrorLine(in: syntaxError, by: 9)
        XCTAssertTrue(relocated.hasSuffix("near 'SETA NAMES utf8mb4' at line 14"), relocated)
    }

    func testErrorLineIsLeftAloneWhenTheWholeEditorWasSent() {
        XCTAssertEqual(SQLConsoleViewModel.relocatingErrorLine(in: syntaxError, by: 0), syntaxError)
    }

    /// Only the line number the message *ends* with is the server's own —
    /// the same words inside the quoted SQL are the user's text.
    func testOnlyTheTrailingLineNumberIsRewritten() {
        let message = "MySQL error: Invalid syntax: … near 'SELECT 'stopped at line 3' FROMM t' at line 2"
        XCTAssertEqual(
            SQLConsoleViewModel.relocatingErrorLine(in: message, by: 10),
            "MySQL error: Invalid syntax: … near 'SELECT 'stopped at line 3' FROMM t' at line 12"
        )
    }

    func testMessagesWithoutALineNumberAreLeftAlone() {
        let message = "MySQL error: Table 'db.missing' doesn't exist"
        XCTAssertEqual(SQLConsoleViewModel.relocatingErrorLine(in: message, by: 7), message)
    }

    // MARK: - Where a selection starts

    func testSelectionOffsetCountsTheLinesAboveIt() {
        let text = "-- one\n-- two\n\nSELECT 1;\nSELECT 2;"
        let start = (text as NSString).range(of: "SELECT 2;").location
        XCTAssertEqual(SQLConsoleViewModel.lineOffset(ofSelection: "SELECT 2;", startingAt: start, in: text), 4)
        XCTAssertEqual(SQLConsoleViewModel.lineOffset(ofSelection: "-- one", startingAt: 0, in: text), 0)
    }

    /// A selection dragged from the end of the previous line opens with a
    /// line break that's trimmed off before sending — the statement the
    /// server sees starts one line further down than the selection does.
    func testSelectionOffsetIncludesTheBlankLinesItOpensWith() {
        let text = "SELECT 1;\n\n  SELECT 2;"
        let selection = "\n\n  SELECT 2;"
        let start = (text as NSString).range(of: selection).location
        XCTAssertEqual(SQLConsoleViewModel.lineOffset(ofSelection: selection, startingAt: start, in: text), 2)
    }

    /// Offsets are UTF-16, as `NSTextView` reports them — text above the
    /// selection that isn't ASCII must not throw the count off.
    func testSelectionOffsetIsCountedInUTF16() {
        let text = "-- Türkiye 🇹🇷 — Côte d'Ivoire\n-- ikinci satır\nSELECT 1;"
        let start = (text as NSString).range(of: "SELECT 1;").location
        XCTAssertEqual(SQLConsoleViewModel.lineOffset(ofSelection: "SELECT 1;", startingAt: start, in: text), 2)
    }

    func testSelectionOffsetSurvivesAStaleOrMissingStart() {
        XCTAssertEqual(SQLConsoleViewModel.lineOffset(ofSelection: "SELECT 1", startingAt: nil, in: "a\nb"), 0)
        XCTAssertEqual(SQLConsoleViewModel.lineOffset(ofSelection: "SELECT 1", startingAt: 999, in: "a\nb"), 1)
    }
}
