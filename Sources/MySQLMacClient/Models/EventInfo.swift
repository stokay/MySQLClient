import Foundation

/// One row from `SHOW EVENTS`. `status` (`ENABLED`/`DISABLED`/
/// `SLAVESIDE_DISABLED`) comes along for free in the same call and is shown
/// as the row's trailing text.
struct EventInfo: Identifiable, Equatable, Hashable {
    var id: String { "\(database).\(name)" }
    let database: String
    let name: String
    let status: String
}
