import XCTest
@testable import MySQLMacClient

/// `XLSXExporter` never produces the shapes a real-world `.xlsx` actually
/// has (shared strings, DEFLATE compression, multiple sheets, date-styled
/// cells) — so beyond one round-trip test against this app's own writer,
/// every other fixture here is hand-built and packaged with `/usr/bin/zip`
/// (an independent, trusted oracle — real DEFLATE compression, not
/// anything this project's own code produced) to prove those paths.
final class XLSXImportParserTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Round trip against this app's own writer

    func testRoundTripsAFileWrittenByXLSXExporter() async throws {
        let columns = [
            ColumnInfo(name: "id", mysqlType: "int(11)", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, defaultValue: nil),
            ColumnInfo(name: "name", mysqlType: "varchar(100)", isNullable: true, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
        ]
        let rows: [[RowValue]] = [[.int(1), .string("Ada")], [.int(2), .string("Grace")]]
        let url = directory.appendingPathComponent("export.xlsx")
        try XLSXExporter.write(columns: columns, rows: rows, includeHeaderRow: true, to: url)

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        var collected: [[String]] = []
        try await XLSXImportParser.parse(fileHandle: fileHandle, sheetIndex: 0) { _, fields in collected.append(fields) }

        XCTAssertEqual(collected, [["id", "name"], ["1", "Ada"], ["2", "Grace"]])
    }

    // MARK: - Real-world shapes (shared strings, DEFLATE, multiple sheets, dates)

    func testReadsSharedStringsFromADeflateCompressedArchive() async throws {
        let url = try makeFixture(sheets: [
            "xl/worksheets/sheet1.xml": Self.sheetXML(rows: [
                [cell("A1", type: "s", value: "0"), cell("B1", type: "s", value: "1")],
                [cell("A2", type: "s", value: "0"), cell("B2", type: "s", value: "2")],
            ]),
        ], sharedStrings: ["repeated", "first", "second"])

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        var collected: [[String]] = []
        try await XLSXImportParser.parse(fileHandle: fileHandle, sheetIndex: 0) { _, fields in collected.append(fields) }

        // Real `/usr/bin/zip` output — proves the DEFLATE path, not just "stored".
        XCTAssertEqual(collected, [["repeated", "first"], ["repeated", "second"]])
    }

    func testReadsMultipleSheetsBySheetIndex() async throws {
        let url = try makeFixture(
            sheets: [
                "xl/worksheets/sheet1.xml": Self.sheetXML(rows: [[cell("A1", type: "inlineStr", inline: "from sheet one")]]),
                "xl/worksheets/sheet2.xml": Self.sheetXML(rows: [[cell("A1", type: "inlineStr", inline: "from sheet two")]]),
            ],
            sheetNames: ["First", "Second"]
        )

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        XCTAssertEqual(try XLSXImportParser.sheetNames(fileHandle: fileHandle), ["First", "Second"])

        var fromFirst: [[String]] = []
        try await XLSXImportParser.parse(fileHandle: fileHandle, sheetIndex: 0) { _, fields in fromFirst.append(fields) }
        XCTAssertEqual(fromFirst, [["from sheet one"]])

        var fromSecond: [[String]] = []
        try await XLSXImportParser.parse(fileHandle: fileHandle, sheetIndex: 1) { _, fields in fromSecond.append(fields) }
        XCTAssertEqual(fromSecond, [["from sheet two"]])
    }

    func testConvertsADateStyledCellsSerialNumberToAnISODateString() async throws {
        let url = try makeFixture(
            sheets: [
                "xl/worksheets/sheet1.xml": Self.sheetXML(rows: [
                    [cell("A1", style: 1, value: "45292")], // 2024-01-01, built-in numFmtId 14
                ]),
            ],
            includeStyles: true
        )

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        var collected: [[String]] = []
        try await XLSXImportParser.parse(fileHandle: fileHandle, sheetIndex: 0) { _, fields in collected.append(fields) }

        XCTAssertEqual(collected, [["2024-01-01"]])
    }

    func testPlainNumericCellWithoutADateStyleStaysANumber() async throws {
        let url = try makeFixture(sheets: [
            "xl/worksheets/sheet1.xml": Self.sheetXML(rows: [[cell("A1", value: "45292")]]),
        ])

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        var collected: [[String]] = []
        try await XLSXImportParser.parse(fileHandle: fileHandle, sheetIndex: 0) { _, fields in collected.append(fields) }

        XCTAssertEqual(collected, [["45292"]])
    }

    func testRowWithAGapInColumnsIsPaddedWithEmptyStrings() async throws {
        // B1 is skipped entirely — a real, common shape (Excel omits cells
        // with no value rather than emitting an empty placeholder).
        let url = try makeFixture(sheets: [
            "xl/worksheets/sheet1.xml": Self.sheetXML(rows: [
                [cell("A1", type: "inlineStr", inline: "left"), cell("C1", type: "inlineStr", inline: "right")],
            ]),
        ])

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        var collected: [[String]] = []
        try await XLSXImportParser.parse(fileHandle: fileHandle, sheetIndex: 0) { _, fields in collected.append(fields) }

        XCTAssertEqual(collected, [["left", "", "right"]])
    }

    func testPreviewStopsAfterTheRequestedLimit() async throws {
        let url = try makeFixture(sheets: [
            "xl/worksheets/sheet1.xml": Self.sheetXML(rows: (1...5).map { row in
                [cell("A\(row)", type: "inlineStr", inline: "row \(row)")]
            }),
        ])

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        let preview = try await XLSXImportParser.preview(fileHandle: fileHandle, sheetIndex: 0, limit: 2)

        XCTAssertEqual(preview, [["row 1"], ["row 2"]])
    }

    // MARK: - Fixture building (real `/usr/bin/zip`, real DEFLATE)

    private struct Cell { let ref: String; let type: String?; let style: Int?; let value: String? }

    private func cell(_ ref: String, type: String? = nil, style: Int? = nil, value: String? = nil, inline: String? = nil) -> Cell {
        if let inline {
            return Cell(ref: ref, type: "inlineStr", style: style, value: inline)
        }
        return Cell(ref: ref, type: type, style: style, value: value)
    }

    private static func sheetXML(rows: [[Cell]]) -> String {
        let rowsXML = rows.enumerated().map { rowOffset, cells -> String in
            let cellsXML = cells.map { cell -> String in
                var attrs = "r=\"\(cell.ref)\""
                if let type = cell.type { attrs += " t=\"\(type)\"" }
                if let style = cell.style { attrs += " s=\"\(style)\"" }
                guard let value = cell.value else { return "<c \(attrs)/>" }
                if cell.type == "inlineStr" {
                    return "<c \(attrs)><is><t>\(value)</t></is></c>"
                }
                return "<c \(attrs)><v>\(value)</v></c>"
            }.joined()
            return "<row r=\"\(rowOffset + 1)\">\(cellsXML)</row>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rowsXML)</sheetData></worksheet>"
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static func workbookXML(sheetNames: [String]) -> String {
        let sheetsXML = sheetNames.enumerated().map { index, name in
            "<sheet name=\"\(name)\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>\(sheetsXML)</sheets>
        </workbook>
        """
    }

    private static func workbookRelsXML(sheetCount: Int) -> String {
        let relsXML = (1...sheetCount).map { index in
            "<Relationship Id=\"rId\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index).xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relsXML)</Relationships>
        """
    }

    private static func sharedStringsXML(_ strings: [String]) -> String {
        let entries = strings.map { "<si><t>\($0)</t></si>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(strings.count)" uniqueCount="\(strings.count)">\(entries)</sst>
        """
    }

    /// One custom date format (built-in `numFmtId="14"` would need no
    /// `<numFmts>` entry at all — `cellXfs` index 1 here uses it directly)
    /// plus a plain default style at index 0, matching how a real
    /// styles.xml always reserves index 0 for "no special formatting".
    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <cellXfs count="2">
        <xf numFmtId="0"/>
        <xf numFmtId="14"/>
      </cellXfs>
    </styleSheet>
    """

    private func makeFixture(
        sheets: [String: String],
        sheetNames: [String]? = nil,
        sharedStrings: [String]? = nil,
        includeStyles: Bool = false
    ) throws -> URL {
        let names = sheetNames ?? sheets.keys.sorted().map { _ in "Sheet" }.enumerated().map { "Sheet\($0.offset + 1)" }
        let stagingDir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        var parts: [String: String] = [
            "[Content_Types].xml": Self.contentTypesXML,
            "_rels/.rels": Self.rootRelsXML,
            "xl/workbook.xml": Self.workbookXML(sheetNames: names),
            "xl/_rels/workbook.xml.rels": Self.workbookRelsXML(sheetCount: sheets.count),
        ]
        for (path, xml) in sheets { parts[path] = xml }
        if let sharedStrings { parts["xl/sharedStrings.xml"] = Self.sharedStringsXML(sharedStrings) }
        if includeStyles { parts["xl/styles.xml"] = Self.stylesXML }

        for (relativePath, contents) in parts {
            let fileURL = stagingDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let xlsxURL = directory.appendingPathComponent("\(UUID().uuidString).xlsx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", xlsxURL.path, "."]
        process.currentDirectoryURL = stagingDir
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "/usr/bin/zip failed to build the test fixture")
        return xlsxURL
    }
}
