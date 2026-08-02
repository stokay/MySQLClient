import XCTest
@testable import MySQLMacClient

final class JSONExporterTests: XCTestCase {
    private let columns = [
        ColumnInfo(name: "id", mysqlType: "int(11)", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, defaultValue: nil),
        ColumnInfo(name: "name", mysqlType: "varchar(100)", isNullable: false, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
        ColumnInfo(name: "quantity", mysqlType: "int(11)", isNullable: true, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
    ]

    func testFormatRowWithMixedTypesKeepsNumbersUnquoted() {
        let row = JSONExporter.formatRow(columns, [.int(1), .string("Bolt"), .double(3.5)])
        XCTAssertEqual(row, "{\"id\":1,\"name\":\"Bolt\",\"quantity\":3.5}")
    }

    func testNullRendersAsJSONNullLiteralNotAString() {
        let row = JSONExporter.formatRow(columns, [.int(1), .string("Bolt"), .null])
        XCTAssertEqual(row, "{\"id\":1,\"name\":\"Bolt\",\"quantity\":null}")
    }

    func testStringEscaping() {
        XCTAssertEqual(JSONExporter.escapeString("a\"b\\c\nd"), "a\\\"b\\\\c\\nd")
    }

    func testControlCharacterEscapesToUnicodeEscape() {
        XCTAssertEqual(JSONExporter.escapeString("\u{01}"), "\\u0001")
    }

    func testBlobRendersAsBase64String() {
        let data = Data([0x00, 0xFF, 0x10])
        let row = JSONExporter.formatRow([columns[0]], [.blob(data)])
        XCTAssertEqual(row, "{\"id\":\"\(data.base64EncodedString())\"}")
    }

    func testDateRendersAsQuotedRowValueFormat() {
        let date = RowValue.dateFormatter.date(from: "2024-01-15 10:30:00")!
        let row = JSONExporter.formatRow([columns[0]], [.date(date)])
        XCTAssertEqual(row, "{\"id\":\"2024-01-15 10:30:00\"}")
    }

    func testWriteProducesATopLevelArrayWithCommaSeparatedRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)

        try JSONExporter.write(
            columns: columns,
            rows: [[.int(1), .string("Bolt"), .int(100)], [.int(2), .string("Nut"), .null]],
            to: handle
        )
        try handle.close()

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0]["name"] as? String, "Bolt")
        XCTAssertTrue(parsed?[1]["quantity"] is NSNull)
    }
}
