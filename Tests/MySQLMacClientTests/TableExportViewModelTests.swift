import XCTest
@testable import MySQLMacClient

/// Runs against a real local MariaDB/MySQL (XAMPP) — same convention as
/// `TableDataViewModelTests`. Uses the `widgets` seed table (Bolt/Nut/
/// Washer), reset in `setUp`.
@MainActor
final class TableExportViewModelTests: XCTestCase {
    var service: MySQLService!
    var tempFileURL: URL!

    override func setUp() async throws {
        // Assigned before any throwing call below — if `connect()` fails
        // (server down), `setUp` aborts partway through but `tearDown`
        // still runs and unconditionally reads `tempFileURL`; leaving it
        // nil until after a throwing step crashed the whole test process
        // with a force-unwrap trap instead of just failing this test.
        tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).export")
        service = MySQLService()
        try await service.connect(
            host: "127.0.0.1",
            port: 3306,
            username: "root",
            password: nil,
            database: "mysqlmacclient_test"
        )
        try await service.execute("DELETE FROM widgets")
        try await service.execute("ALTER TABLE widgets AUTO_INCREMENT = 1")
        try await service.execute("""
            INSERT INTO widgets (name, quantity, created_at, notes) VALUES
            ('Bolt', 100, '2024-01-15 10:30:00', 'Standard bolt'),
            ('Nut', 250, '2024-02-20 14:00:00', NULL),
            ('Washer', NULL, NULL, 'Out of stock')
            """)
        tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).export")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempFileURL)
        try await service.disconnect()
    }

    private func makeViewModel() -> TableExportViewModel {
        TableExportViewModel(service: service, table: TableInfo(database: "mysqlmacclient_test", name: "widgets", isView: false))
    }

    /// Switching the format tab must keep the suggested filename's
    /// extension in sync — otherwise the file written ends up with the
    /// previous format's extension even though its contents are correct
    /// for the newly selected one.
    func testChangingFormatUpdatesOutputFileExtensionButKeepsDirectoryAndStem() async throws {
        let viewModel = makeViewModel()
        let base = URL(fileURLWithPath: "/Users/someone/Desktop/widgets.csv")
        viewModel.outputFileURL = base
        viewModel.options.format = .csv // no-op: same format, must not touch the URL

        XCTAssertEqual(viewModel.outputFileURL, base)

        viewModel.options.format = .sql
        XCTAssertEqual(viewModel.outputFileURL, URL(fileURLWithPath: "/Users/someone/Desktop/widgets.sql"))

        viewModel.options.format = .json
        XCTAssertEqual(viewModel.outputFileURL, URL(fileURLWithPath: "/Users/someone/Desktop/widgets.json"))
    }

    func testLoadColumnsPopulatesAllColumnsAllSelectedByDefault() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.allColumns.map(\.name).sorted(), ["created_at", "id", "name", "notes", "quantity"])
        XCTAssertEqual(viewModel.selectedColumnNames, Set(viewModel.allColumns.map(\.name)))
    }

    func testSelectAllAndDeselectAllToggleTheFullSet() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()

        viewModel.deselectAllColumns()
        XCTAssertTrue(viewModel.selectedColumnNames.isEmpty)

        viewModel.selectAllColumns()
        XCTAssertEqual(viewModel.selectedColumnNames, Set(viewModel.allColumns.map(\.name)))
    }

    /// Proves the "always the entire table" requirement: nothing here
    /// touches a `TableDataViewModel` filter/sort/page — every seed row
    /// still has to land in the file.
    func testRunExportWritesEveryRowForCSV() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        let success = await viewModel.runExport()
        XCTAssertTrue(success)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        let lines = contents.split(separator: "\r\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 4) // header + 3 seed rows
        XCTAssertTrue(contents.contains("Bolt"))
        XCTAssertTrue(contents.contains("Nut"))
        XCTAssertTrue(contents.contains("Washer"))
    }

    func testRunExportWritesCreateTableAndInsertsForSQL() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.options.format = .sql
        viewModel.outputFileURL = tempFileURL

        let success = await viewModel.runExport()
        XCTAssertTrue(success)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("CREATE TABLE IF NOT EXISTS `widgets`"))
        XCTAssertEqual(contents.components(separatedBy: "INSERT INTO").count - 1, 3)
        XCTAssertTrue(contents.contains("'Bolt'"))
    }

    /// `widget_view` is a real view over `widgets` (see the fixture schema).
    /// CSV/HTML/JSON already work on a view unmodified — this only pins the
    /// SQL format, since `SHOW CREATE TABLE` on a view silently redirects
    /// to a `Create View` column instead of `Create Table`, which used to
    /// make SQL export throw for every view.
    func testRunExportOnAViewWritesTheViewDefinitionNotInsertsForSQL() async throws {
        let viewModel = TableExportViewModel(service: service, table: TableInfo(database: "mysqlmacclient_test", name: "widget_view", isView: true))
        await viewModel.loadColumns()
        viewModel.options.format = .sql
        viewModel.outputFileURL = tempFileURL

        let success = await viewModel.runExport()
        XCTAssertTrue(success)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("CREATE OR REPLACE"))
        XCTAssertTrue(contents.contains("VIEW `widget_view`"))
        XCTAssertFalse(contents.contains("INSERT INTO"), "a view has no rows of its own to freeze as INSERT statements")
    }

    /// CSV export against a view — confirms the already-working data path
    /// (columns()/SELECT both work unmodified against a view) stays that way.
    func testRunExportOnAViewWritesRowsForCSV() async throws {
        let viewModel = TableExportViewModel(service: service, table: TableInfo(database: "mysqlmacclient_test", name: "widget_view", isView: true))
        await viewModel.loadColumns()
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        let success = await viewModel.runExport()
        XCTAssertTrue(success)
        XCTAssertNil(viewModel.errorMessage)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Bolt"))
        XCTAssertTrue(contents.contains("Nut"))
        XCTAssertTrue(contents.contains("Washer"))
    }

    /// A column-subset export must only emit the checked columns.
    func testRunExportOmitsDeselectedColumns() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.selectedColumnNames.remove("notes")
        viewModel.options.format = .csv
        viewModel.outputFileURL = tempFileURL

        let success = await viewModel.runExport()
        XCTAssertTrue(success)

        let contents = try String(contentsOf: tempFileURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("notes"))
        XCTAssertFalse(contents.contains("Standard bolt"))
    }

    func testRunExportToUnwritablePathSetsErrorMessageInsteadOfCrashing() async throws {
        let viewModel = makeViewModel()
        await viewModel.loadColumns()
        viewModel.options.format = .csv
        viewModel.outputFileURL = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.csv")

        let success = await viewModel.runExport()
        XCTAssertFalse(success)
        XCTAssertNotNil(viewModel.errorMessage)
    }
}
