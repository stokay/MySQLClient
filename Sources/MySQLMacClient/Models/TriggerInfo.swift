import Foundation

/// One row from `SHOW TRIGGERS` — unlike `RoutineInfo`, there's no shared
/// "kind" with events (their `SHOW`/`SHOW CREATE` column shapes don't line
/// up), so this stays its own type rather than a case of some broader enum.
/// `table`/`timing`/`event` come along for free in the same `SHOW TRIGGERS`
/// call and are shown as the row's trailing text (e.g. "BEFORE INSERT").
struct TriggerInfo: Identifiable, Equatable, Hashable {
    var id: String { "\(database).\(name)" }
    let database: String
    let name: String
    let table: String
    let timing: String
    let event: String
}
