import Foundation

/// Assembles the XML parts of a minimal, single-sheet `.xlsx` workbook.
/// `MinimalZipWriter` packages whatever this produces into the actual
/// `.xlsx` file — this type only builds strings, no I/O.
///
/// Uses inline strings (`<c t="inlineStr"><is><t>…</t></is></c>`) rather
/// than `xl/sharedStrings.xml`. Shared strings exist purely as a size
/// optimization for repeated values across many cells; inline strings are
/// simpler (one fewer XML part, no string-interning bookkeeping) and fully
/// spec-valid — both Excel and Numbers read them without complaint.
enum XLSXWorkbookBuilder {
    static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
    """

    /// The one part with real per-export content — `xl/worksheets/sheet1.xml`.
    static func sheetXML(columnNames: [String], rows: [[RowValue]], includeHeaderRow: Bool) -> String {
        var rowsXML = ""
        var rowNumber = 1

        if includeHeaderRow {
            let cells = columnNames.enumerated()
                .map { index, name in inlineStringCellXML(reference: "\(columnReference(index))\(rowNumber)", text: name) }
                .joined()
            rowsXML += "<row r=\"\(rowNumber)\">\(cells)</row>"
            rowNumber += 1
        }

        for row in rows {
            let cells = row.enumerated()
                .map { index, value in cellXML(reference: "\(columnReference(index))\(rowNumber)", value: value) }
                .joined()
            rowsXML += "<row r=\"\(rowNumber)\">\(cells)</row>"
            rowNumber += 1
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rowsXML)</sheetData></worksheet>
        """
    }

    /// One `<c>` per `RowValue` case: `.int`/`.double` as a numeric value
    /// (XML's default cell type, no `t=` attribute needed); `.string`/
    /// `.date`/`.blob` (base64) as inline strings; `.null` as an empty
    /// `<c/>` with no value child at all — that's how Excel represents a
    /// genuinely blank cell, not an empty string.
    static func cellXML(reference: String, value: RowValue) -> String {
        switch value {
        case .null:
            return "<c r=\"\(reference)\"/>"
        case .int(let value):
            return "<c r=\"\(reference)\"><v>\(value)</v></c>"
        case .double(let value):
            return "<c r=\"\(reference)\"><v>\(value)</v></c>"
        case .string(let value):
            return inlineStringCellXML(reference: reference, text: value)
        case .date(let value):
            return inlineStringCellXML(reference: reference, text: RowValue.dateFormatter.string(from: value))
        case .blob(let value):
            return inlineStringCellXML(reference: reference, text: value.base64EncodedString())
        }
    }

    private static func inlineStringCellXML(reference: String, text: String) -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeXML(text))</t></is></c>"
    }

    /// `&`/`<`/`>` are XML's only text-content-unsafe characters (there's no
    /// surrounding quote to worry about, unlike an attribute value). XML 1.0
    /// also outright forbids most raw control characters in text content —
    /// not just as a style preference but a well-formedness rule — so
    /// anything below 0x20 other than tab/newline/carriage return is
    /// dropped rather than passed through or numeric-escaped (numeric
    /// character references to those same code points are just as invalid
    /// under XML 1.0).
    static func escapeXML(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default:
                if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" {
                    continue
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// 0-based column index -> spreadsheet column letters: 0 -> "A",
    /// 25 -> "Z", 26 -> "AA".
    static func columnReference(_ zeroBasedIndex: Int) -> String {
        var index = zeroBasedIndex
        var result = ""
        repeat {
            let remainder = index % 26
            result = String(UnicodeScalar(UInt8(65 + remainder))) + result
            index = index / 26 - 1
        } while index >= 0
        return result
    }
}
