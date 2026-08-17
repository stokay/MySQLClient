import Foundation

/// Reads an `.xlsx` file — the inverse of `XLSXExporter`, but general
/// purpose: unlike this app's own writer (which only ever produces
/// uncompressed, inline-string, single-sheet output), a real-world
/// `.xlsx` from Excel, Numbers, Google Sheets or LibreOffice is
/// DEFLATE-compressed, resolves text through `xl/sharedStrings.xml`
/// rather than inline strings, and may contain several sheets — all of
/// which this has to handle to be useful for "import a spreadsheet
/// someone actually sends you," not just round-tripping this app's own
/// export. See `MinimalZipReader` for the archive/inflate side and
/// `XLSXWorkbookReader` for the supporting-parts XML.
///
/// Unlike `CSVImportParser`, this does **not** stream row-by-row from
/// disk: the target sheet's XML (after unzip + inflate) is parsed via
/// `XMLParser` into an in-memory `[[String]]` first, and `onRow` is only
/// called afterward, once per collected row. Excel itself caps a sheet at
/// `XLSXExporter.maxRowsPerSheet` (1,048,576) rows, so even a maximal
/// sheet is bounded — unlike CSV import/export, which this app
/// deliberately supports at multi-million-row, multi-gigabyte scale, a
/// full worksheet in memory is an acceptable trade for how much simpler
/// it keeps the XML handling.
enum XLSXImportParser {
    enum ParseError: Error {
        case sheetIndexOutOfRange
        case sheetPartNotFound
    }

    /// Sheet display names, in the order `workbook.xml` lists them — for a
    /// sheet picker in the UI. `sheetIndex` elsewhere in this API refers to
    /// this same order.
    static func sheetNames(fileHandle: FileHandle) throws -> [String] {
        let archive = try MinimalZipReader(fileHandle: fileHandle)
        let workbookXML = try archive.data(named: "xl/workbook.xml")
        return try XLSXWorkbookReader.sheets(from: workbookXML).map(\.name)
    }

    /// Reads the whole sheet, calling `onRow` once per row (the header row
    /// included, same convention as `CSVImportParser.parse` — callers that
    /// treat the first row as a header skip it themselves).
    static func parse(
        fileHandle: FileHandle,
        sheetIndex: Int,
        onRow: @MainActor (_ rowIndex: Int, _ fields: [String]) async throws -> Void
    ) async throws {
        let archive = try MinimalZipReader(fileHandle: fileHandle)

        let workbookXML = try archive.data(named: "xl/workbook.xml")
        let sheets = try XLSXWorkbookReader.sheets(from: workbookXML)
        guard sheets.indices.contains(sheetIndex) else { throw ParseError.sheetIndexOutOfRange }

        let relsXML = try archive.data(named: "xl/_rels/workbook.xml.rels")
        let targets = try XLSXWorkbookReader.relationshipTargets(from: relsXML)
        guard let target = targets[sheets[sheetIndex].relationshipID] else { throw ParseError.sheetPartNotFound }
        // Relationship targets are relative to `xl/`.
        let sheetPath = "xl/" + target

        let sharedStrings = (try? archive.data(named: "xl/sharedStrings.xml"))
            .flatMap { try? XLSXWorkbookReader.sharedStrings(from: $0) } ?? []
        let dateStyleIndices = (try? archive.data(named: "xl/styles.xml"))
            .flatMap { try? XLSXWorkbookReader.dateStyleIndices(from: $0) } ?? []

        let sheetXML = try archive.data(named: sheetPath)
        let rows = try SheetRowsParser.rows(from: sheetXML, sharedStrings: sharedStrings, dateStyleIndices: dateStyleIndices)
        for (index, fields) in rows.enumerated() {
            try await onRow(index, fields)
        }
    }

    private struct StopParsing: Error {}

    /// Reads only the first `limit` rows.
    static func preview(fileHandle: FileHandle, sheetIndex: Int, limit: Int) async throws -> [[String]] {
        var result: [[String]] = []
        do {
            try await parse(fileHandle: fileHandle, sheetIndex: sheetIndex) { _, fields in
                result.append(fields)
                if result.count >= limit {
                    throw StopParsing()
                }
            }
        } catch is StopParsing {
            // Expected early exit once `limit` rows are collected.
        }
        return result
    }
}

/// SAX parse of one worksheet's `<sheetData>` into `[[String]]`, one entry
/// per `<row>`, each sized to the widest row seen (or the sheet's
/// `<dimension>` hint, if present) and left-padded with `""` for any
/// column a given row didn't have a cell for.
private enum SheetRowsParser {
    static func rows(from xml: Data, sharedStrings: [String], dateStyleIndices: Set<Int>) throws -> [[String]] {
        let delegate = Delegate(sharedStrings: sharedStrings, dateStyleIndices: dateStyleIndices)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else {
            throw MinimalZipReader.ReaderError.corruptEntry("worksheet")
        }
        // Every row is padded to the final, widest column count — earlier,
        // narrower rows were built before later rows could widen it.
        let columnCount = delegate.rowsByColumnIndex.map { $0.keys.max().map { $0 + 1 } ?? 0 }.max() ?? delegate.dimensionColumnCount
        let finalColumnCount = max(columnCount, delegate.dimensionColumnCount)
        return delegate.rowsByColumnIndex.map { cells in
            (0..<finalColumnCount).map { cells[$0] ?? "" }
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let sharedStrings: [String]
        let dateStyleIndices: Set<Int>
        var dimensionColumnCount = 0
        var rowsByColumnIndex: [[Int: String]] = []

        private var currentRowCells: [Int: String] = [:]
        private var currentCellColumn = 0
        private var currentRowNextColumn = 0
        private var currentCellType: String?
        private var currentCellStyleIndex: Int?
        private var currentCellText = ""
        private var isInsideValue = false
        private var isInsideInlineString = false

        init(sharedStrings: [String], dateStyleIndices: Set<Int>) {
            self.sharedStrings = sharedStrings
            self.dateStyleIndices = dateStyleIndices
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "dimension":
                if let ref = attributeDict["ref"] {
                    dimensionColumnCount = Self.columnCount(fromDimensionRef: ref)
                }
            case "row":
                currentRowCells = [:]
                currentRowNextColumn = 0
            case "c":
                currentCellType = attributeDict["t"]
                currentCellStyleIndex = attributeDict["s"].flatMap(Int.init)
                currentCellText = ""
                currentCellColumn = attributeDict["r"].map(Self.columnIndex(fromCellRef:)) ?? currentRowNextColumn
            case "v":
                isInsideValue = true
            case "is":
                isInsideInlineString = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isInsideValue || isInsideInlineString {
                currentCellText += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "v":
                isInsideValue = false
            case "is":
                isInsideInlineString = false
            case "c":
                currentRowCells[currentCellColumn] = resolveCellText()
                currentRowNextColumn = currentCellColumn + 1
            case "row":
                rowsByColumnIndex.append(currentRowCells)
            default:
                break
            }
        }

        private func resolveCellText() -> String {
            switch currentCellType {
            case "s":
                guard let index = Int(currentCellText), sharedStrings.indices.contains(index) else { return "" }
                return sharedStrings[index]
            case "inlineStr", "str":
                return currentCellText
            case "b":
                return currentCellText == "1" ? "TRUE" : "FALSE"
            case "e":
                return currentCellText
            default:
                // No `t` (or `t="n"`): a plain number, or — if its style
                // says so — a date/time serial that needs converting.
                if let styleIndex = currentCellStyleIndex, dateStyleIndices.contains(styleIndex),
                   let serial = Double(currentCellText) {
                    return Self.dateString(fromExcelSerial: serial)
                }
                return currentCellText
            }
        }

        /// Column letters → 0-based index ("A"→0, "Z"→25, "AA"→26) — the
        /// inverse of `XLSXWorkbookBuilder.columnReference`.
        static func columnIndex(fromCellRef ref: String) -> Int {
            var index = 0
            for char in ref {
                guard let ascii = char.asciiValue, ascii >= 65, ascii <= 90 else { break }
                index = index * 26 + Int(ascii - 65 + 1)
            }
            return max(0, index - 1)
        }

        /// The widest column referenced by a `dimension` ref like
        /// `"A1:D10"` — just an upfront hint; actual row widths still win
        /// if a row somehow has more cells than this claims.
        static func columnCount(fromDimensionRef ref: String) -> Int {
            guard let colonIndex = ref.firstIndex(of: ":") else { return 0 }
            let endRef = ref[ref.index(after: colonIndex)...]
            let letters = endRef.prefix { $0.isLetter }
            guard !letters.isEmpty else { return 0 }
            return columnIndex(fromCellRef: String(letters)) + 1
        }

        /// Excel's day-1-is-1900-01-01 serial date system, including the
        /// intentionally preserved 1900 leap-year bug — irrelevant here,
        /// since no real spreadsheet has data dated January/February 1900.
        /// `25569` is the day count between the Excel epoch and the Unix
        /// epoch.
        static func dateString(fromExcelSerial serial: Double) -> String {
            let unixSeconds = (serial - 25569) * 86400
            let date = Date(timeIntervalSince1970: unixSeconds)
            let hasTimeComponent = serial.truncatingRemainder(dividingBy: 1) != 0
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = hasTimeComponent ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }
}
