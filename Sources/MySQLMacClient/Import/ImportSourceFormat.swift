import Foundation

/// Which parser handles a chosen import source file — CSV or Excel
/// `.xlsx`. An explicit, up-front choice (format tabs in the view,
/// mirroring `TableExportView`'s format tabs), not inferred from a file
/// extension after the fact: a file picker that silently also accepts
/// `.xlsx` doesn't tell anyone Excel import exists at all. Shared between
/// `TableImportViewModel` (importing table data) and `CreateTableViewModel`
/// (inferring column definitions from a file) — both offer the exact same
/// CSV/Excel choice.
enum ImportSourceFormat: Equatable, CaseIterable, Identifiable {
    case csv
    case xlsx

    var id: Self { self }

    var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .xlsx: return "Excel"
        }
    }
}
