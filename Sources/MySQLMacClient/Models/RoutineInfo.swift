import Foundation

/// A stored routine — MySQL's own umbrella term for procedures and
/// functions, which differ only by a keyword across every `SHOW`/`DROP`
/// statement. Keeping them one type (rather than a `ProcedureInfo` /
/// `FunctionInfo` pair) is what lets the sidebar rows, context menus and
/// Alter/Drop handling be written once instead of twice.
enum RoutineKind: String, CaseIterable {
    case procedure
    case function

    /// The word MySQL uses in `SHOW <kind> STATUS`, `SHOW CREATE <kind>`
    /// and `DROP <kind>`.
    var sqlKeyword: String {
        switch self {
        case .procedure: return "PROCEDURE"
        case .function: return "FUNCTION"
        }
    }

    /// The column `SHOW CREATE <kind>` returns the definition in.
    var createStatementColumn: String {
        switch self {
        case .procedure: return "Create Procedure"
        case .function: return "Create Function"
        }
    }

    /// Sidebar category title, its empty-state text, and the word used in
    /// the context menu / drop confirmation.
    var categoryTitle: String {
        switch self {
        case .procedure: return "Procedure'lar"
        case .function: return "Function'lar"
        }
    }

    var emptyCategoryText: String {
        switch self {
        case .procedure: return "Procedure yok"
        case .function: return "Function yok"
        }
    }

    var displayName: String {
        switch self {
        case .procedure: return "Procedure"
        case .function: return "Function"
        }
    }
}

struct RoutineInfo: Identifiable, Equatable, Hashable {
    /// `kind` is part of the identity: a procedure and a function may share
    /// a name within the same database.
    var id: String { "\(database).\(kind.rawValue).\(name)" }
    let database: String
    let name: String
    let kind: RoutineKind
}
