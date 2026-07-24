import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP), not a mock — see
/// MySQLClient.md's validation plan. Requires the `mysqlmacclient_test`
/// schema (widgets + widget_logs_nopk + widget_view) to exist on
/// 127.0.0.1:3306.
final class SchemaIntrospectionServiceTests: XCTestCase {
    var service: MySQLService!
    var introspection: SchemaIntrospectionService!

    override func setUp() async throws {
        service = MySQLService()
        try await service.connect(
            host: "127.0.0.1",
            port: 3306,
            username: "root",
            password: nil,
            database: "mysqlmacclient_test"
        )
        introspection = SchemaIntrospectionService(service: service)
    }

    override func tearDown() async throws {
        try await service.disconnect()
    }

    func testListDatabasesIncludesTestSchema() async throws {
        let databases = try await introspection.listDatabases()
        XCTAssertTrue(databases.map(\.name).contains("mysqlmacclient_test"))
    }

    func testListTablesAndViewsDistinguishesViewsFromBaseTables() async throws {
        let entries = try await introspection.listTablesAndViews(inDatabase: "mysqlmacclient_test")
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        XCTAssertEqual(byName["widgets"]?.isView, false)
        XCTAssertEqual(byName["widget_logs_nopk"]?.isView, false)
        XCTAssertEqual(byName["widget_view"]?.isView, true)
    }

    func testColumnsDetectsPrimaryKeyAutoIncrementAndNullability() async throws {
        let columns = try await introspection.columns(forTable: "widgets", inDatabase: "mysqlmacclient_test")
        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

        XCTAssertEqual(byName["id"]?.isPrimaryKey, true)
        XCTAssertEqual(byName["id"]?.isAutoIncrement, true)
        XCTAssertEqual(byName["name"]?.isNullable, false)
        XCTAssertEqual(byName["quantity"]?.isNullable, true)
        XCTAssertEqual(byName["notes"]?.isPrimaryKey, false)
    }

    func testColumnsOnTableWithoutPrimaryKey() async throws {
        let columns = try await introspection.columns(forTable: "widget_logs_nopk", inDatabase: "mysqlmacclient_test")
        XCTAssertFalse(columns.isEmpty)
        XCTAssertTrue(columns.allSatisfy { !$0.isPrimaryKey })
    }

    func testPrimaryKeyColumnNames() async throws {
        let pk = try await introspection.primaryKeyColumnNames(forTable: "widgets", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(pk, ["id"])

        let noPK = try await introspection.primaryKeyColumnNames(forTable: "widget_logs_nopk", inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(noPK.isEmpty)
    }

    func testIndexesGroupsColumnsByKeyNameInSequenceOrder() async throws {
        let indexes = try await introspection.indexes(forTable: "widgets", inDatabase: "mysqlmacclient_test")
        let byName = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) })

        XCTAssertEqual(byName["PRIMARY"]?.columns, ["id"])
        XCTAssertEqual(byName["PRIMARY"]?.isUnique, true)
        XCTAssertEqual(byName["idx_name_quantity"]?.columns, ["name", "quantity"])
        XCTAssertEqual(byName["idx_name_quantity"]?.isUnique, false)
    }

    /// The qualified query (`` SHOW CREATE VIEW `db`.`view` ``) is what
    /// actually runs — MySQL then fully qualifies every reference in the
    /// response with that same `` `db`. `` prefix, which `showCreateView`
    /// must strip back out so "Alter View" produces the same unqualified
    /// style a plain `USE db; SHOW CREATE VIEW view` would have.
    func testShowCreateViewStripsSchemaQualifiers() async throws {
        let createView = try await introspection.showCreateView("widget_view", inDatabase: "mysqlmacclient_test")

        XCTAssertFalse(createView.contains("`mysqlmacclient_test`."))
        XCTAssertTrue(createView.contains("VIEW `widget_view` AS"))
        XCTAssertTrue(createView.contains("from `widgets`"))
    }

    func testQuotedIdentifierRejectsBacktick() {
        XCTAssertThrowsError(try SchemaIntrospectionService.quotedIdentifier("evil`table"))
    }
}
