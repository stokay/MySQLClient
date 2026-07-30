import Foundation

struct ProcedureInfo: Identifiable, Equatable, Hashable {
    var id: String { "\(database).\(name)" }
    let database: String
    let name: String
}
