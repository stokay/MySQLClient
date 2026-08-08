import Foundation

/// A real `.xlsx` (OOXML/SpreadsheetML) writer — hand-rolled, no
/// third-party dependency (the app already carries one pinned fork
/// dependency for mysql-nio and no more were wanted). Ties
/// `XLSXWorkbookBuilder`'s XML parts together with `MinimalZipWriter`'s ZIP
/// container into one file.
///
/// Builds the sheet XML in memory rather than streaming row-by-row the way
/// the textual exporters do — it can't stream into the final file (it's a
/// zip), and this only restructures already-buffered row data, not a
/// second full copy at a larger memory order of magnitude, so it's fine
/// even for the largest tables this app already loads whole into memory
/// elsewhere (`TableDataViewModel.fetchPage()` with pagination off does the
/// same un-limited `SELECT *`).
enum XLSXExporter {
    /// Excel's hard per-worksheet row ceiling — `XFD1048576` is the last
    /// valid cell address in the `.xlsx` format itself, not a limitation of
    /// this writer. Row/cell references beyond it aren't spec-valid, and
    /// Excel doesn't just warn on open — it flags the whole file as
    /// damaged and offers to "recover" it (silently dropping the excess).
    /// A real 1.15M-row table exceeded this by ~100,000 rows and produced
    /// exactly that dialog before callers started checking against this
    /// constant first.
    static let maxRowsPerSheet = 1_048_576

    static func write(
        columns: [ColumnInfo],
        rows: [[RowValue]],
        includeHeaderRow: Bool,
        to fileURL: URL
    ) throws {
        var zip = MinimalZipWriter()
        zip.addEntry(name: "[Content_Types].xml", data: Data(XLSXWorkbookBuilder.contentTypesXML.utf8))
        zip.addEntry(name: "_rels/.rels", data: Data(XLSXWorkbookBuilder.rootRelsXML.utf8))
        zip.addEntry(name: "xl/workbook.xml", data: Data(XLSXWorkbookBuilder.workbookXML.utf8))
        zip.addEntry(name: "xl/_rels/workbook.xml.rels", data: Data(XLSXWorkbookBuilder.workbookRelsXML.utf8))

        let sheetXML = XLSXWorkbookBuilder.sheetXML(
            columnNames: columns.map(\.name),
            rows: rows,
            includeHeaderRow: includeHeaderRow
        )
        zip.addEntry(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8))

        try zip.finalize().write(to: fileURL, options: .atomic)
    }
}
