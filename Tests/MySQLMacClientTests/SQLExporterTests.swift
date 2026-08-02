import XCTest
@testable import MySQLMacClient

final class SQLExporterTests: XCTestCase {
    private let columns = [
        ColumnInfo(name: "id", mysqlType: "int(11)", isNullable: false, isPrimaryKey: true, isAutoIncrement: true, defaultValue: nil),
        ColumnInfo(name: "name", mysqlType: "varchar(100)", isNullable: false, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
        ColumnInfo(name: "notes", mysqlType: "varchar(255)", isNullable: true, isPrimaryKey: false, isAutoIncrement: false, defaultValue: nil),
    ]

    func testCreateTableStatementInsertsIfNotExistsAndTerminates() {
        let raw = "CREATE TABLE `widgets` (\n  `id` int NOT NULL\n) ENGINE=InnoDB"
        let result = SQLExporter.createTableStatement(rawShowCreateTable: raw)
        XCTAssertEqual(result, "CREATE TABLE IF NOT EXISTS `widgets` (\n  `id` int NOT NULL\n) ENGINE=InnoDB;")
    }

    func testCreateViewStatementInsertsOrReplaceAndTerminates() {
        let raw = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `widget_view` AS select `widgets`.`id` AS `id` from `widgets`"
        let result = SQLExporter.createViewStatement(rawShowCreateView: raw)
        XCTAssertEqual(
            result,
            "CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `widget_view` AS select `widgets`.`id` AS `id` from `widgets`;"
        )
    }

    func testInsertStatementWithMixedTypes() {
        let sql = SQLExporter.insertStatement(database: "testdb", table: "widgets", columns: columns, values: [.int(1), .string("Bolt"), .null])
        XCTAssertEqual(sql, "INSERT INTO `testdb`.`widgets` (`id`, `name`, `notes`) VALUES (1, 'Bolt', NULL);")
    }

    func testStringLiteralEscaping() {
        XCTAssertEqual(SQLExporter.escapeStringLiteral("O'Brien"), "O''Brien")
        XCTAssertEqual(SQLExporter.escapeStringLiteral("C:\\path"), "C:\\\\path")
    }

    func testBlobRendersAsHexLiteral() {
        let sql = SQLExporter.insertStatement(database: "db", table: "t", columns: [columns[0]], values: [.blob(Data([0x00, 0xFF]))])
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` (`id`) VALUES (X'00ff');")
    }

    func testEmptyBlobRendersAsEmptyHexLiteral() {
        XCTAssertEqual(SQLExporter.hexLiteral(Data()), "X''")
    }

    func testWriteEmitsCreateTableFollowedByOneInsertPerRow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sql")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)

        try SQLExporter.write(
            database: "testdb",
            table: "widgets",
            createTableSQL: "CREATE TABLE IF NOT EXISTS `widgets` (`id` int);",
            columns: [columns[0]],
            rows: [[.int(1)], [.int(2)]],
            to: handle
        )
        try handle.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("CREATE TABLE IF NOT EXISTS `widgets` (`id` int);"))
        XCTAssertTrue(contents.contains("INSERT INTO `testdb`.`widgets` (`id`) VALUES (1);"))
        XCTAssertTrue(contents.contains("INSERT INTO `testdb`.`widgets` (`id`) VALUES (2);"))
    }
}
