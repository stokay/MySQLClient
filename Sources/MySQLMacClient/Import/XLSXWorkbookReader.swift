import Foundation

/// `XMLParser`-based (SAX) readers for the handful of `.xlsx` XML parts
/// `XLSXImportParser` needs — the read-side mirror of
/// `XLSXWorkbookBuilder`'s string building, except a real-world workbook
/// (unlike this app's own writer) always needs `sharedStrings.xml`
/// resolved and may reference several sheets via `workbook.xml.rels`.
enum XLSXWorkbookReader {
    struct Sheet {
        let name: String
        let relationshipID: String
    }

    static func sheets(from xml: Data) throws -> [Sheet] {
        let delegate = WorkbookParserDelegate()
        try runParser(xml, delegate: delegate, partName: "workbook.xml")
        return delegate.sheets
    }

    /// `Relationship Id` → `Target` (relative to `xl/`), from
    /// `xl/_rels/workbook.xml.rels`.
    static func relationshipTargets(from xml: Data) throws -> [String: String] {
        let delegate = RelsParserDelegate()
        try runParser(xml, delegate: delegate, partName: "workbook.xml.rels")
        return delegate.targets
    }

    /// One resolved string per `<si>`, in order — index `i` is exactly
    /// what a cell's `<v>` contains when `t="s"`.
    static func sharedStrings(from xml: Data) throws -> [String] {
        let delegate = SharedStringsParserDelegate()
        try runParser(xml, delegate: delegate, partName: "sharedStrings.xml")
        return delegate.strings
    }

    /// The `cellXfs` style indices (what a cell's `s="N"` refers to) that
    /// represent a date or date-time format — built-in numFmt IDs per
    /// ECMA-376 §18.8.30, plus any custom `numFmt` whose format code looks
    /// date-like. A cell using one of these styles stores its value as an
    /// Excel serial number that needs converting, not a plain number.
    static func dateStyleIndices(from xml: Data) throws -> Set<Int> {
        let delegate = StylesParserDelegate()
        try runParser(xml, delegate: delegate, partName: "styles.xml")

        let builtInDateFormatIDs: Set<Int> = [
            14, 15, 16, 17, 18, 19, 20, 21, 22,
            27, 28, 29, 30, 31, 32, 33, 34, 35, 36,
            45, 46, 47, 50, 51, 52, 53, 54, 55, 56, 57, 58,
        ]
        var dateStyleIndices = Set<Int>()
        for (index, numFmtId) in delegate.cellXfNumFmtIds.enumerated() {
            if builtInDateFormatIDs.contains(numFmtId) {
                dateStyleIndices.insert(index)
            } else if let code = delegate.customFormatCodes[numFmtId], looksLikeDateFormat(code) {
                dateStyleIndices.insert(index)
            }
        }
        return dateStyleIndices
    }

    /// Strips quoted literal text (`"..."`) and bracketed tags (`[Red]`,
    /// `[$-409]`) — the format-code syntax's only ways to embed characters
    /// that don't mean what they'd mean elsewhere — then checks for any of
    /// the letters that only ever appear in a date/time format code
    /// (y/m/d/h/s); a plain numeric format never contains them unescaped.
    private static func looksLikeDateFormat(_ formatCode: String) -> Bool {
        var stripped = ""
        var insideLiteral = false
        var insideBracket = false
        for char in formatCode {
            if char == "\"" { insideLiteral.toggle(); continue }
            if char == "[" { insideBracket = true; continue }
            if char == "]" { insideBracket = false; continue }
            if insideLiteral || insideBracket { continue }
            stripped.append(char)
        }
        let lowered = stripped.lowercased()
        return lowered.contains("y") || lowered.contains("d") || lowered.contains("h")
            || lowered.contains("m") || lowered.contains("s")
    }

    private static func runParser(_ xml: Data, delegate: XMLParserDelegate, partName: String) throws {
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else {
            throw MinimalZipReader.ReaderError.corruptEntry(partName)
        }
    }

    private final class WorkbookParserDelegate: NSObject, XMLParserDelegate {
        var sheets: [Sheet] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "sheet", let name = attributeDict["name"] else { return }
            let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] ?? ""
            sheets.append(Sheet(name: name, relationshipID: relationshipID))
        }
    }

    private final class RelsParserDelegate: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName == "Relationship",
                  let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
            targets[id] = target
        }
    }

    private final class SharedStringsParserDelegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var isInsideText = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "si": current = ""
            case "t": isInsideText = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isInsideText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "t": isInsideText = false
            case "si": strings.append(current)
            default: break
            }
        }
    }

    private final class StylesParserDelegate: NSObject, XMLParserDelegate {
        var customFormatCodes: [Int: String] = [:]
        var cellXfNumFmtIds: [Int] = []
        private var isInsideCellXfs = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "numFmt":
                if let idString = attributeDict["numFmtId"], let id = Int(idString),
                   let code = attributeDict["formatCode"] {
                    customFormatCodes[id] = code
                }
            case "cellXfs":
                // Distinct from `cellStyleXfs`, which also contains `<xf>`
                // elements but isn't what a cell's `s="N"` indexes into.
                isInsideCellXfs = true
            case "xf":
                if isInsideCellXfs {
                    cellXfNumFmtIds.append(attributeDict["numFmtId"].flatMap(Int.init) ?? 0)
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "cellXfs" { isInsideCellXfs = false }
        }
    }
}
