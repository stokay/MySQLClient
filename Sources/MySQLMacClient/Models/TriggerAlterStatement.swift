import Foundation

/// Wraps a `SHOW CREATE TRIGGER` definition into the `DELIMITER $$ ...
/// DELIMITER ;` statement the sidebar's "Alter Trigger" context-menu action
/// appends to the query console. MySQL has no `ALTER TRIGGER` at all — the
/// only way to change one is drop-and-recreate, same rationale as
/// `RoutineAlterStatement`.
enum TriggerAlterStatement {
    static func format(trigger: TriggerInfo, createStatement: String) -> String {
        [
            "DELIMITER $$",
            "",
            "USE `\(trigger.database)`$$",
            "",
            "DROP TRIGGER IF EXISTS `\(trigger.name)`$$",
            "",
            "\(createStatement)$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
    }
}
