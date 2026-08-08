import XCTest
@testable import MySQLMacClient

/// Pure byte-level parsing — no database needed. Every test writes its
/// fixture to a real temp file and reads it back through a `FileHandle`,
/// the same way `TableImportViewModel` will, rather than constructing an
/// in-memory `Data` shortcut that could hide a chunk-boundary bug.
final class CSVImportParserTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rows(
        of contents: String,
        options: CSVImportParser.Options = CSVImportParser.Options(),
        rawBytes: Data? = nil
    ) async throws -> [[String]] {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try (rawBytes ?? Data(contents.utf8)).write(to: url)
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var collected: [[String]] = []
        try await CSVImportParser.parse(fileHandle: fileHandle, options: options) { _, fields in
            collected.append(fields)
        }
        return collected
    }

    func testBasicCommaSeparatedRows() async throws {
        let result = try await rows(of: "id,name\n1,Ali\n2,Veli\n")
        XCTAssertEqual(result, [["id", "name"], ["1", "Ali"], ["2", "Veli"]])
    }

    func testCustomTerminatorAndEnclosure() async throws {
        var options = CSVImportParser.Options()
        options.fieldTerminator = ";"
        options.fieldEnclosure = "'"
        let result = try await rows(of: "id;name\n1;'Ali'\n", options: options)
        XCTAssertEqual(result, [["id", "name"], ["1", "Ali"]])
    }

    func testQuotedFieldContainingTheTerminator() async throws {
        let result = try await rows(of: "id,name\n1,\"Ali,Veli\"\n")
        XCTAssertEqual(result, [["id", "name"], ["1", "Ali,Veli"]])
    }

    func testQuotedFieldContainingALiteralLFNewline() async throws {
        let result = try await rows(of: "id,note\n1,\"line one\nline two\"\n2,plain\n")
        XCTAssertEqual(result, [["id", "note"], ["1", "line one\nline two"], ["2", "plain"]])
    }

    func testQuotedFieldContainingALiteralCRLFNewline() async throws {
        let result = try await rows(of: "id,note\r\n1,\"line one\r\nline two\"\r\n2,plain\r\n")
        XCTAssertEqual(result, [["id", "note"], ["1", "line one\r\nline two"], ["2", "plain"]])
    }

    func testDoubledEnclosureInsideAQuotedFieldUnescapesToOneCharacter() async throws {
        let result = try await rows(of: "id,quote\n1,\"she said \"\"hi\"\"\"\n")
        XCTAssertEqual(result, [["id", "quote"], ["1", "she said \"hi\""]])
    }

    func testCustomEscapeCharacterUnescapesTheEnclosure() async throws {
        var options = CSVImportParser.Options()
        options.fieldEscape = "\\"
        let result = try await rows(of: "id,quote\n1,\"she said \\\"hi\\\"\"\n", options: options)
        XCTAssertEqual(result, [["id", "quote"], ["1", "she said \"hi\""]])
    }

    func testUTF8BOMAtStartOfFileIsSkipped() async throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("id,name\n1,Ali\n".utf8))
        let result = try await rows(of: "", rawBytes: data)
        XCTAssertEqual(result, [["id", "name"], ["1", "Ali"]])
    }

    func testLastLineWithoutATrailingNewlineIsStillARow() async throws {
        let result = try await rows(of: "id,name\n1,Ali")
        XCTAssertEqual(result, [["id", "name"], ["1", "Ali"]])
    }

    func testTrailingEmptyFieldWithoutANewlineIsPreserved() async throws {
        let result = try await rows(of: "a,b,c\n1,2,")
        XCTAssertEqual(result, [["a", "b", "c"], ["1", "2", ""]])
    }

    func testALoneEmptyQuotedFieldWithoutANewlineIsStillOneRow() async throws {
        let result = try await rows(of: "\"\"")
        XCTAssertEqual(result, [[""]])
    }

    func testEmptyFileProducesNoRows() async throws {
        let result = try await rows(of: "")
        XCTAssertEqual(result, [])
    }

    func testHeaderOnlyFileProducesExactlyOneRow() async throws {
        let result = try await rows(of: "id,name\n")
        XCTAssertEqual(result, [["id", "name"]])
    }

    func testEmptyFieldsArePreservedAsEmptyStringsNotConvertedToNull() async throws {
        let result = try await rows(of: "a,b,c\n1,,3\n")
        XCTAssertEqual(result, [["a", "b", "c"], ["1", "", "3"]])
    }

    func testParsingStopsAssoonAsOnRowThrows() async throws {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data("1\n2\n3\n".utf8).write(to: url)
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        struct Stop: Error {}
        var seen: [[String]] = []
        await XCTAssertThrowsErrorAsync(try await CSVImportParser.parse(fileHandle: fileHandle, options: CSVImportParser.Options()) { _, fields in
            seen.append(fields)
            if seen.count == 2 { throw Stop() }
        })
        XCTAssertEqual(seen, [["1"], ["2"]])
    }

    func testPreviewReturnsOnlyTheRequestedRowCountFromALargerFile() async throws {
        let url = directory.appendingPathComponent(UUID().uuidString)
        let contents = (1...100).map { "\($0),row\($0)" }.joined(separator: "\n")
        try Data(contents.utf8).write(to: url)
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let preview = try await CSVImportParser.preview(fileHandle: fileHandle, options: CSVImportParser.Options(), limit: 5)
        XCTAssertEqual(preview.count, 5)
        XCTAssertEqual(preview.first, ["1", "row1"])
        XCTAssertEqual(preview.last, ["5", "row5"])
    }

    /// Forces multiple internal chunk reads (`chunkSize: 8`) across a
    /// quoted field boundary, to catch any bug where the state machine
    /// only works when a whole field/row fits in a single chunk.
    func testParsingIsCorrectAcrossSmallChunkBoundaries() async throws {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data("id,note\n1,\"a longer quoted value\"\n2,plain\n".utf8).write(to: url)
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var collected: [[String]] = []
        try await CSVImportParser.parse(fileHandle: fileHandle, options: CSVImportParser.Options(), chunkSize: 8) { _, fields in
            collected.append(fields)
        }
        XCTAssertEqual(collected, [["id", "note"], ["1", "a longer quoted value"], ["2", "plain"]])
    }
}
