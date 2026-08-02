import XCTest
@testable import MySQLMacClient

/// Pure string-building — no database needed.
final class CSVExporterTests: XCTestCase {
    private let columns = [
        ColumnInfo(name: "id", mysqlType: "int(11)", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, defaultValue: nil),
        ColumnInfo(name: "name", mysqlType: "varchar(100)", isNullable: false, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
        ColumnInfo(name: "notes", mysqlType: "varchar(255)", isNullable: true, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
    ]

    func testFormatHeaderJoinsColumnNamesWithTerminatorAndCRLF() {
        let header = CSVExporter.formatHeader(["id", "name", "notes"], options: CSVExportOptions())
        XCTAssertEqual(header, "id,name,notes\r\n")
    }

    func testFormatRowWithMixedTypes() {
        let row = CSVExporter.formatRow([.int(1), .string("Bolt"), .double(3.5)], options: CSVExportOptions())
        XCTAssertEqual(row, "1,Bolt,3.5\r\n")
    }

    func testNullRendersAsEmptyFieldNotTheWordNull() {
        let row = CSVExporter.formatRow([.int(1), .null, .string("x")], options: CSVExportOptions())
        XCTAssertEqual(row, "1,,x\r\n")
    }

    func testFieldContainingTerminatorAndQuoteGetsQuotedAndDoubled() {
        let field = CSVExporter.escapeField("a,\"b\"", options: CSVExportOptions())
        XCTAssertEqual(field, "\"a,\"\"b\"\"\"")
    }

    func testFieldWithoutSpecialCharactersIsNotQuoted() {
        let field = CSVExporter.escapeField("plain", options: CSVExportOptions())
        XCTAssertEqual(field, "plain")
    }

    func testBlobRendersAsBase64() {
        let data = Data([0x00, 0xFF, 0x10])
        let row = CSVExporter.formatRow([.blob(data)], options: CSVExportOptions())
        XCTAssertEqual(row, "\(data.base64EncodedString())\r\n")
    }

    func testDateFormattingMatchesRowValueConvention() {
        let date = RowValue.dateFormatter.date(from: "2024-01-15 10:30:00")!
        let row = CSVExporter.formatRow([.date(date)], options: CSVExportOptions())
        XCTAssertEqual(row, "2024-01-15 10:30:00\r\n")
    }

    /// Proves the options are actually threaded through, not hardcoded.
    func testCustomTerminatorAndEscapeCharacterAreHonored() {
        var options = CSVExportOptions()
        options.fieldTerminator = "\t"
        options.fieldEscape = "\\"
        let header = CSVExporter.formatHeader(["a", "b"], options: options)
        XCTAssertEqual(header, "a\tb\r\n")

        let field = CSVExporter.escapeField("has\"quote", options: options)
        XCTAssertEqual(field, "\"has\\\"quote\"")
    }

    func testWriteStreamsHeaderAndRowsToFileHandle() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)

        try CSVExporter.write(
            columns: columns,
            rows: [[.int(1), .string("Bolt"), .null]],
            options: CSVExportOptions(),
            to: handle
        )
        try handle.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, "id,name,notes\r\n1,Bolt,\r\n")
    }
}
