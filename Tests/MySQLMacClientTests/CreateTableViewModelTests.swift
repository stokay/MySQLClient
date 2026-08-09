import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP), not a mock. Every test
/// drops its scratch table in tearDown so a failed run doesn't leave debris
/// for the next one.
@MainActor
final class CreateTableViewModelTests: XCTestCase {
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
        try await service.execute("DROP TABLE IF EXISTS create_table_scratch")
    }

    override func tearDown() async throws {
        try await service.execute("DROP TABLE IF EXISTS create_table_scratch")
        try await service.disconnect()
    }

    private func makeViewModel() -> CreateTableViewModel {
        CreateTableViewModel(service: service, defaultDatabase: "mysqlmacclient_test")
    }

    func testCreatesTableWithPrimaryKeyAutoIncrementAndTypedColumns() async throws {
        let viewModel = makeViewModel()
        viewModel.tableName = "create_table_scratch"
        viewModel.columns[0].name = "id"
        viewModel.columns[0].dataType = "INT"
        viewModel.columns[0].isPrimaryKey = true
        viewModel.columns[0].isAutoIncrement = true
        viewModel.columns[1].name = "label"
        viewModel.columns[1].dataType = "VARCHAR"
        viewModel.columns[1].length = "80"
        viewModel.columns[1].isNotNull = true
        viewModel.columns[2].name = "quantity"
        viewModel.columns[2].dataType = "INT"
        viewModel.columns[2].isUnsigned = true
        viewModel.columns[2].defaultValue = "0"

        let created = await viewModel.submit()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(created?.database, "mysqlmacclient_test")
        XCTAssertEqual(created?.name, "create_table_scratch")

        let columns = try await introspection.columns(forTable: "create_table_scratch", inDatabase: "mysqlmacclient_test")
        XCTAssertEqual(columns.map(\.name).sorted(), ["id", "label", "quantity"])

        let idColumn = columns.first { $0.name == "id" }
        XCTAssertEqual(idColumn?.isPrimaryKey, true)
        XCTAssertEqual(idColumn?.isAutoIncrement, true)

        let labelColumn = columns.first { $0.name == "label" }
        XCTAssertEqual(labelColumn?.mysqlType, "varchar(80)")
        XCTAssertEqual(labelColumn?.isNullable, false)

        let quantityColumn = columns.first { $0.name == "quantity" }
        XCTAssertTrue(quantityColumn?.mysqlType.contains("unsigned") ?? false)
    }

    func testEmptyTableNameFailsWithoutHittingTheDatabase() async throws {
        let viewModel = makeViewModel()
        viewModel.columns[0].name = "id"

        let created = await viewModel.submit()

        XCTAssertNil(created)
        XCTAssertEqual(viewModel.errorMessage, CreateTableError.emptyTableName.errorDescription)
    }

    func testNoNamedColumnsFails() async throws {
        let viewModel = makeViewModel()
        viewModel.tableName = "create_table_scratch"

        let created = await viewModel.submit()

        XCTAssertNil(created)
        XCTAssertEqual(viewModel.errorMessage, CreateTableError.noColumns.errorDescription)
    }

    func testMaliciousLengthValueIsRejectedInsteadOfBeingSplicedIntoTheSQL() async throws {
        let viewModel = makeViewModel()
        viewModel.tableName = "create_table_scratch"
        viewModel.columns[0].name = "id"
        viewModel.columns[0].dataType = "VARCHAR"
        viewModel.columns[0].length = "10); DROP TABLE widgets; --"

        let created = await viewModel.submit()

        XCTAssertNil(created)
        XCTAssertEqual(
            viewModel.errorMessage,
            CreateTableError.invalidLength(column: "id", value: "10); DROP TABLE widgets; --").errorDescription
        )

        // The widgets table (used by other tests) must still exist.
        let stillThere = try await introspection.listTablesAndViews(inDatabase: "mysqlmacclient_test")
        XCTAssertTrue(stillThere.contains { $0.name == "widgets" })
    }

    func testCheckingPrimaryKeyForcesNotNull() {
        let viewModel = makeViewModel()
        viewModel.columns[0].isNotNull = false
        viewModel.columns[0].isPrimaryKey = true

        XCTAssertTrue(viewModel.columns[0].isNotNull)
    }
}
