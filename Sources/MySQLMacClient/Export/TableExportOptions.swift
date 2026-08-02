import Foundation

/// The five formats "Export..." can write to. Defined with every case up
/// front — including `.xlsx`, before its writer exists — so the dialog's
/// format picker is complete from the start; a later phase only has to fill
/// in one more `switch` arm in `TableExportViewModel.runExport()`.
enum TableExportFormat: String, CaseIterable, Identifiable {
    case csv, html, json, sql, xlsx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .html: return "HTML"
        case .json: return "JSON"
        case .sql: return "SQL"
        case .xlsx: return "Excel"
        }
    }

    var defaultFileExtension: String {
        switch self {
        case .csv: return "csv"
        case .html: return "html"
        case .json: return "json"
        case .sql: return "sql"
        case .xlsx: return "xlsx"
        }
    }
}

/// CSV-specific knobs, matching the "Terminated by / Enclosed by / Escaped
/// by" fields plus the header checkbox in the export dialog. Defaults are
/// RFC 4180 (comma, double-quote, double-the-quote-to-escape) rather than
/// MySQL's own `SELECT ... INTO OUTFILE` backslash-escape convention, since
/// the exported file needs to open cleanly in ordinary spreadsheet/text
/// tools, not round-trip through MySQL's loader.
struct CSVExportOptions: Equatable {
    var fieldTerminator: String = ","
    var fieldEnclosure: String = "\""
    /// Empty by default, which makes `CSVExporter.escapeField` fall back to
    /// doubling an embedded enclosure character (RFC 4180) — what Excel/
    /// Numbers/every standard CSV reader expects. A non-empty value here
    /// switches to prefix-escaping instead (MySQL's own `LOAD DATA`/
    /// `SELECT ... INTO OUTFILE` convention), for a file meant to round-trip
    /// through MySQL's own loader rather than a spreadsheet app.
    var fieldEscape: String = ""
    var includeHeaderRow: Bool = true
}

/// Holds every format's options at once, not just the active one, so
/// switching tabs in the dialog never discards what the user already typed
/// into a different format's fields.
///
/// No per-format option structs exist yet for HTML/JSON/SQL/XLSX — none of
/// them have a configurable knob today (SQL is always schema+data; JSON/
/// HTML have one obvious shape). Add one the same way `csv` is added here
/// if a real need shows up; don't speculate ahead of that.
struct TableExportOptions {
    var format: TableExportFormat = .csv
    var csv = CSVExportOptions()
}
