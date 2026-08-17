import XCTest
@testable import MySQLMacClient

/// Pure logic, no database — same convention as `CSVImportParserTests`.
final class ColumnTypeInferenceTests: XCTestCase {
    private func infer(_ rows: [[String]], hasHeaderRow: Bool = true) -> [DraftColumn] {
        ColumnTypeInference.inferColumns(fromRows: rows, hasHeaderRow: hasHeaderRow)
    }

    func testEmptyInputProducesNoColumns() {
        XCTAssertTrue(infer([]).isEmpty)
    }

    // MARK: - Integer detection

    func testAllIntegerValuesSuggestINT() {
        let columns = infer([["id"], ["1"], ["2"], ["-3"]])
        XCTAssertEqual(columns.map(\.dataType), ["INT"])
        XCTAssertEqual(columns.first?.length, "")
    }

    func testValuesExceedingInt32RangeSuggestBIGINT() {
        let columns = infer([["big"], ["9999999999"], ["1"]])
        XCTAssertEqual(columns.map(\.dataType), ["BIGINT"])
    }

    // MARK: - Decimal detection

    func testDecimalValuesSuggestDECIMALWithInferredPrecisionAndScale() {
        // Widest integer part "123" (3 digits), widest scale "45" (2 digits) -> precision 5, scale 2.
        let columns = infer([["price"], ["1.5"], ["123.45"], ["-2.00"]])
        XCTAssertEqual(columns.map(\.dataType), ["DECIMAL"])
        XCTAssertEqual(columns.first?.length, "5,2")
    }

    /// A column mixing plain integers and decimals isn't safely summarized
    /// as either — falls through to a text guess rather than picking one.
    func testMixedIntegerAndDecimalValuesDoNotSuggestADecimalOrInteger() {
        let columns = infer([["mixed"], ["5"], ["5.5"]])
        XCTAssertEqual(columns.map(\.dataType), ["VARCHAR"])
    }

    // MARK: - Date detection

    func testISODateValuesSuggestDATE() {
        let columns = infer([["created"], ["2024-01-15"], ["2024-02-20"]])
        XCTAssertEqual(columns.map(\.dataType), ["DATE"])
        XCTAssertEqual(columns.first?.length, "")
    }

    func testDateTimeValuesSuggestDATETIME() {
        let columns = infer([["created"], ["2024-01-15 10:30:00"], ["2024-02-20 14:00:00"]])
        XCTAssertEqual(columns.map(\.dataType), ["DATETIME"])
    }

    // MARK: - Text detection / VARCHAR bucketing

    func testShortTextValuesSuggestVARCHARRoundedUpToANiceBucket() {
        let columns = infer([["name"], ["Ada"], ["Grace Hopper"]]) // longest is 12 chars
        XCTAssertEqual(columns.map(\.dataType), ["VARCHAR"])
        XCTAssertEqual(columns.first?.length, "20")
    }

    func testVeryLongTextValuesSuggestTEXTInsteadOfAHugeVARCHAR() {
        let longValue = String(repeating: "x", count: 1200)
        let columns = infer([["notes"], [longValue]])
        XCTAssertEqual(columns.map(\.dataType), ["TEXT"])
        XCTAssertEqual(columns.first?.length, "")
    }

    // MARK: - Nullability

    func testColumnWithNoEmptyValuesSuggestsNotNull() {
        let columns = infer([["id"], ["1"], ["2"]])
        XCTAssertEqual(columns.first?.isNotNull, true)
    }

    func testColumnWithAnyEmptyValueStaysNullable() {
        let columns = infer([["notes"], ["a note"], [""]])
        XCTAssertEqual(columns.first?.isNotNull, false)
    }

    func testColumnWithNoDataAtAllDefaultsToNullableVARCHAR255() {
        let columns = infer([["empty_column"], [""], [""]])
        XCTAssertEqual(columns.first?.dataType, "VARCHAR")
        XCTAssertEqual(columns.first?.length, "255")
        XCTAssertEqual(columns.first?.isNotNull, false)
    }

    // MARK: - Header handling

    func testMissingHeaderTextFallsBackToAPositionalPlaceholder() {
        let columns = infer([["", "name"], ["1", "Ada"]])
        XCTAssertEqual(columns[0].name, "Column 1")
        XCTAssertEqual(columns[1].name, "name")
    }

    func testHeaderPunctuationIsNormalizedToUnderscores() {
        let columns = infer([["Price ($)"], ["9.99"]])
        XCTAssertEqual(columns.first?.name, "Price")
    }

    func testNoHeaderRowTreatsEveryRowAsData() {
        let columns = infer([["1"], ["2"], ["3"]], hasHeaderRow: false)
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns.first?.name, "Column 1")
        XCTAssertEqual(columns.first?.dataType, "INT")
    }

    // MARK: - Ragged rows

    /// A row with fewer cells than the widest row is padded with empty
    /// values for the missing columns, not dropped or misaligned.
    func testRaggedRowsAreTreatedAsEmptyForMissingColumns() {
        let columns = infer([
            ["id", "note"],
            ["1", "has a note"],
            ["2"],
        ])
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[1].isNotNull, false, "eksik hücre nullable'ı tetiklemeli")
    }
}
