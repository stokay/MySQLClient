import XCTest
@testable import MySQLMacClient

final class HTMLExporterTests: XCTestCase {
    private let columns = [
        ColumnInfo(name: "id", mysqlType: "int(11)", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, defaultValue: nil),
        ColumnInfo(name: "name", mysqlType: "varchar(100)", isNullable: false, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
    ]

    func testDocumentHeaderIncludesEscapedColumnNames() {
        let header = HTMLExporter.documentHeader(tableName: "widgets", columnNames: ["id", "name"])
        XCTAssertTrue(header.contains("<title>widgets</title>"))
        XCTAssertTrue(header.contains("<th>id</th><th>name</th>"))
    }

    func testFormatRowWithMixedTypes() {
        let row = HTMLExporter.formatRow([.int(1), .string("Bolt")])
        XCTAssertEqual(row, "<tr><td>1</td><td>Bolt</td></tr>\n")
    }

    func testNullRendersAsEmptyCellNotTheWordNull() {
        let row = HTMLExporter.formatRow([.int(1), .null])
        XCTAssertEqual(row, "<tr><td>1</td><td></td></tr>\n")
    }

    func testSpecialCharactersAreEscaped() {
        let row = HTMLExporter.formatRow([.string("<b>Bold & \"quoted\"</b>")])
        XCTAssertEqual(row, "<tr><td>&lt;b&gt;Bold &amp; \"quoted\"&lt;/b&gt;</td></tr>\n")
    }

    func testEscapeOrderDoesNotDoubleEscapeAmpersandsFromEntities() {
        // A raw "<" becomes "&lt;" — if "&" were escaped second, this would
        // wrongly become "&amp;lt;".
        XCTAssertEqual(HTMLExporter.escape("<"), "&lt;")
    }

    func testBlobRendersAsBase64() {
        let data = Data([0x00, 0xFF, 0x10])
        let row = HTMLExporter.formatRow([.blob(data)])
        XCTAssertEqual(row, "<tr><td>\(data.base64EncodedString())</td></tr>\n")
    }

    func testWriteProducesAWellFormedDocumentWrappingEveryRow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)

        try HTMLExporter.write(
            tableName: "widgets",
            columns: columns,
            rows: [[.int(1), .string("Bolt")], [.int(2), .null]],
            to: handle
        )
        try handle.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(contents.hasSuffix("</html>"))
        XCTAssertTrue(contents.contains("<tr><td>1</td><td>Bolt</td></tr>"))
        XCTAssertTrue(contents.contains("<tr><td>2</td><td></td></tr>"))
    }
}
