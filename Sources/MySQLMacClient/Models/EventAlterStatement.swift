import Foundation

/// Same shape as `TriggerAlterStatement` — MySQL's real `ALTER EVENT` can
/// only touch characteristics (schedule, status, comment), not the body, so
/// "altering" one here always means drop-and-recreate.
enum EventAlterStatement {
    static func format(event: EventInfo, createStatement: String) -> String {
        [
            "DELIMITER $$",
            "",
            "USE `\(event.database)`$$",
            "",
            "DROP EVENT IF EXISTS `\(event.name)`$$",
            "",
            "\(createStatement)$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")
    }
}
