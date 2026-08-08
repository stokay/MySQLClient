import XCTest
@testable import MySQLMacClient

/// `MinimalZipWriter`/`XLSXWorkbookBuilder` don't get their own test files —
/// exercised here instead, same as `AlterTableViewModelTests` doesn't split
/// out a separate file for its internal diff helpers.
///
/// The pure pieces (CRC-32, column references, per-cell XML, the sheet
/// builder) are asserted on directly with literal fixtures, no I/O. The one
/// thing a pure unit test *can't* prove is whether the bytes `MinimalZipWriter`
/// actually lays out are a valid, readable ZIP container — for that,
/// `/usr/bin/unzip` (an independent, trusted oracle; there's no in-process
/// zip reader in this project) extracts the written archive back out, and
/// the extracted bytes are compared byte-for-byte against what
/// `XLSXWorkbookBuilder.sheetXML` produces directly. An exact match proves
/// the full round trip — local file header, CRC-32, central directory
/// offsets, EOCD — all at once, without needing an XML parser at all.
final class XLSXExporterTests: XCTestCase {
    private let columns = [
        ColumnInfo(name: "id", mysqlType: "int(11)", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, defaultValue: nil),
        ColumnInfo(name: "name", mysqlType: "varchar(100)", isNullable: false, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
    ]
    private let rows: [[RowValue]] = [
        [.int(1), .string("Bolt")],
        [.int(2), .null],
    ]

    // MARK: - Row limit

    /// Locks the constant against silent drift — `TableExportViewModel`
    /// relies on this exact value to reject an over-the-limit export
    /// before wasting a fetch on it (see `XLSXExporter.maxRowsPerSheet`'s
    /// own doc comment for why: `XFD1048576` is Excel's actual last valid
    /// cell address).
    func testMaxRowsPerSheetMatchesExcelsDocumentedLimit() {
        XCTAssertEqual(XLSXExporter.maxRowsPerSheet, 1_048_576)
    }

    // MARK: - CRC-32

    func testCRC32MatchesKnownTestVector() {
        // The standard CRC-32/ISO-HDLC "check" value for ASCII "123456789"
        // — the same polynomial/init/xor-out ZIP and gzip both use.
        XCTAssertEqual(MinimalZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - Column references

    func testColumnReferenceBase26Conversion() {
        XCTAssertEqual(XLSXWorkbookBuilder.columnReference(0), "A")
        XCTAssertEqual(XLSXWorkbookBuilder.columnReference(25), "Z")
        XCTAssertEqual(XLSXWorkbookBuilder.columnReference(26), "AA")
        XCTAssertEqual(XLSXWorkbookBuilder.columnReference(27), "AB")
        XCTAssertEqual(XLSXWorkbookBuilder.columnReference(51), "AZ")
        XCTAssertEqual(XLSXWorkbookBuilder.columnReference(52), "BA")
    }

    // MARK: - Cell XML per RowValue case

    func testCellXMLForNullIsAnEmptySelfClosingCell() {
        XCTAssertEqual(XLSXWorkbookBuilder.cellXML(reference: "A1", value: .null), "<c r=\"A1\"/>")
    }

    func testCellXMLForIntIsNumericWithNoTypeAttribute() {
        XCTAssertEqual(XLSXWorkbookBuilder.cellXML(reference: "A1", value: .int(42)), "<c r=\"A1\"><v>42</v></c>")
    }

    func testCellXMLForStringIsInlineStringWithEscaping() {
        XCTAssertEqual(
            XLSXWorkbookBuilder.cellXML(reference: "B1", value: .string("A & B < C")),
            "<c r=\"B1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">A &amp; B &lt; C</t></is></c>"
        )
    }

    func testCellXMLForBlobIsBase64InlineString() {
        let data = Data([0x00, 0xFF])
        XCTAssertEqual(
            XLSXWorkbookBuilder.cellXML(reference: "C1", value: .blob(data)),
            "<c r=\"C1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(data.base64EncodedString())</t></is></c>"
        )
    }

    func testEscapeXMLStripsInvalidControlCharactersButKeepsTabAndNewline() {
        XCTAssertEqual(XLSXWorkbookBuilder.escapeXML("a\u{01}b\tc\nd"), "ab\tc\nd")
    }

    // MARK: - Sheet assembly

    func testSheetXMLIncludesHeaderRowWhenRequested() {
        let xml = XLSXWorkbookBuilder.sheetXML(columnNames: ["id", "name"], rows: rows, includeHeaderRow: true)
        XCTAssertTrue(xml.contains("<row r=\"1\">"))
        XCTAssertTrue(xml.contains("<t xml:space=\"preserve\">id</t>"))
        XCTAssertTrue(xml.contains("<row r=\"2\">"))
        XCTAssertTrue(xml.contains("<row r=\"3\">"))
        XCTAssertFalse(xml.contains("<row r=\"4\">"))
    }

    func testSheetXMLOmitsHeaderRowWhenNotRequested() {
        let xml = XLSXWorkbookBuilder.sheetXML(columnNames: ["id", "name"], rows: rows, includeHeaderRow: false)
        XCTAssertFalse(xml.contains("<t xml:space=\"preserve\">id</t>"))
        XCTAssertTrue(xml.contains("<row r=\"1\">"))
        XCTAssertTrue(xml.contains("<row r=\"2\">"))
        XCTAssertFalse(xml.contains("<row r=\"3\">"))
    }

    // MARK: - Real zip round-trip

    func testWriteProducesAValidZipArchiveContainingExpectedParts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        try XLSXExporter.write(columns: columns, rows: rows, includeHeaderRow: true, to: url)

        let listingText = String(data: try runProcess("/usr/bin/unzip", ["-l", url.path]), encoding: .utf8) ?? ""
        for expectedPart in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"] {
            XCTAssertTrue(listingText.contains(expectedPart), "zip listing missing \(expectedPart):\n\(listingText)")
        }
    }

    func testWriteEmbedsTheExactSheetXMLTheBuilderProduces() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }

        try XLSXExporter.write(columns: columns, rows: rows, includeHeaderRow: true, to: url)

        let extracted = try runProcess("/usr/bin/unzip", ["-p", url.path, "xl/worksheets/sheet1.xml"])
        let expected = XLSXWorkbookBuilder.sheetXML(columnNames: columns.map(\.name), rows: rows, includeHeaderRow: true)
        XCTAssertEqual(String(data: extracted, encoding: .utf8), expected)
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
