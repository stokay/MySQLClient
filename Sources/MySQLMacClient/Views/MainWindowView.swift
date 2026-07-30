import SwiftUI

/// One "Oluştur ▸ <kind>..." request that only needs a name — drives the
/// shared `CreateNamedSchemaObjectView` sheet. Add a case here (plus one
/// arm in `MainWindowView`'s sheet closure) for each new kind instead of a
/// new `@State` pair.
private struct NamedObjectCreationRequest: Identifiable {
    enum Kind {
        case view, storedProcedure, function, trigger, event

        var title: String {
            switch self {
            case .view: return "Yeni View"
            case .storedProcedure: return "Yeni Stored Procedure"
            case .function: return "Yeni Function"
            case .trigger: return "Yeni Trigger"
            case .event: return "Yeni Event"
            }
        }

        var nameFieldLabel: String {
            switch self {
            case .view: return "View Adı"
            case .storedProcedure: return "Stored Procedure Adı"
            case .function: return "Function Adı"
            case .trigger: return "Trigger Adı"
            case .event: return "Event Adı"
            }
        }

        func sql(database: String, name: String) -> String {
            switch self {
            case .view: return SQLTemplate.createView(database: database, name: name)
            case .storedProcedure: return SQLTemplate.createStoredProcedure(database: database, name: name)
            case .function: return SQLTemplate.createFunction(database: database, name: name)
            case .trigger: return SQLTemplate.createTrigger(database: database, name: name)
            case .event: return SQLTemplate.createEvent(database: database, name: name)
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let database: String
}

struct MainWindowView: View {
    let session: AppSession
    let onDisconnect: () -> Void

    @StateObject private var schemaTreeViewModel: SchemaTreeViewModel
    @StateObject private var insertionBridge = SQLInsertionBridge()
    /// One SQL console for the whole session — shared by every table's
    /// grid and by the no-table-selected placeholder, so the editor is
    /// always reachable even in a brand-new, still-empty database (see the
    /// split-view/`onQueryResultCleared` wiring below for why this had to
    /// move up from being per-table state).
    @StateObject private var console: SQLConsoleViewModel
    @State private var selectedTable: TableInfo?
    @State private var isShowingCreateTable = false
    /// Set when the create-table sheet is opened from a table's context
    /// menu, so the form pre-selects that table's database instead of the
    /// currently selected one.
    @State private var createTableDefaultDatabase: String?
    /// Drives the single generic "ask for a name" sheet shared by every
    /// "Oluştur ▸ <kind>..." menu item that's just a name prompt (View,
    /// Stored Procedure, Function so far) — one `@State` instead of a
    /// growing set of `isShowingCreateX`/`createXDatabase` pairs.
    @State private var namedObjectCreationRequest: NamedObjectCreationRequest?
    @State private var tablePendingTruncate: TableInfo?
    @State private var tablePendingDrop: TableInfo?
    @State private var tableToAlter: TableInfo?
    @State private var procedurePendingDrop: ProcedureInfo?
    @State private var contextActionError: String?
    /// Surfaced from the selected table's grid up to `StatusBarView` — see
    /// `TableDataGridView`'s `onRowCountChange`. `nil` with nothing selected
    /// (or before its first load completes).
    @State private var selectedTableRowCount: Int?

    private static let minPanelHeight: CGFloat = 180
    private static let minGridHeight: CGFloat = 150
    @State private var queryPanelHeight: CGFloat = Self.minPanelHeight
    @State private var dragStartHeight: CGFloat?

    init(session: AppSession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self.onDisconnect = onDisconnect
        _schemaTreeViewModel = StateObject(
            wrappedValue: SchemaTreeViewModel(introspection: session.introspectionService)
        )
        _console = StateObject(
            wrappedValue: SQLConsoleViewModel(service: session.mysqlService, introspection: session.introspectionService)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                TableListView(
                    viewModel: schemaTreeViewModel,
                    selectedTable: $selectedTable,
                    insertionBridge: insertionBridge,
                    onCreateTable: { database in
                        createTableDefaultDatabase = database
                        isShowingCreateTable = true
                    },
                    onCreateView: { database in
                        namedObjectCreationRequest = NamedObjectCreationRequest(kind: .view, database: database)
                    },
                    onCreateStoredProcedure: { database in
                        namedObjectCreationRequest = NamedObjectCreationRequest(kind: .storedProcedure, database: database)
                    },
                    onCreateFunction: { database in
                        namedObjectCreationRequest = NamedObjectCreationRequest(kind: .function, database: database)
                    },
                    onCreateTrigger: { database in
                        namedObjectCreationRequest = NamedObjectCreationRequest(kind: .trigger, database: database)
                    },
                    onCreateEvent: { database in
                        namedObjectCreationRequest = NamedObjectCreationRequest(kind: .event, database: database)
                    },
                    onTruncateTable: { tablePendingTruncate = $0 },
                    onDropTable: { tablePendingDrop = $0 },
                    onInsertQueryTemplate: { table, kind in
                        Task { await insertQueryTemplate(for: table, kind: kind) }
                    },
                    onAlterTable: { tableToAlter = $0 },
                    onShowTableInfo: { table in
                        selectedTable = table
                        insertionBridge.pendingShowInfo = true
                    },
                    onAlterView: { view in
                        Task { await alterView(view) }
                    },
                    onDropView: { tablePendingDrop = $0 },
                    onAlterProcedure: { procedure in
                        Task { await alterProcedure(procedure) }
                    },
                    onDropProcedure: { procedurePendingDrop = $0 }
                )
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            } detail: {
                detailPane
            }

            StatusBarView(profile: session.profile, rowCount: selectedTableRowCount, onDisconnect: onDisconnect)
        }
        .task {
            await schemaTreeViewModel.loadDatabases()
        }
        .onChange(of: selectedTable) { _, newValue in
            // Keeps the console's "what schema does an unqualified table
            // name mean" guess in sync with the sidebar, and drops the
            // no-longer-relevant table-grid reload hookup once nothing is
            // selected (see `SQLConsoleViewModel.onQueryResultCleared`).
            console.currentDatabaseHint = newValue?.database
            if newValue == nil {
                console.onQueryResultCleared = nil
                selectedTableRowCount = nil
            }
        }
        .onChange(of: insertionBridge.pendingText) { _, newValue in
            guard let text = newValue else { return }
            console.isQueryPanelVisible = true
            console.pendingQueryInsertion = text
            insertionBridge.pendingText = nil
        }
        .onChange(of: insertionBridge.pendingAppend) { _, newValue in
            guard let text = newValue else { return }
            console.isQueryPanelVisible = true
            console.pendingQueryAppend = text
            insertionBridge.pendingAppend = nil
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    createTableDefaultDatabase = nil
                    isShowingCreateTable = true
                } label: {
                    Label {
                        Text("Yeni Tablo")
                    } icon: {
                        Image.bundled("create_table", fallbackSystemImage: "rectangle.badge.plus")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                    }
                }
                .help("Yeni Tablo Oluştur")
            }
            ToolbarItem(placement: .navigation) {
                SettingsLink {
                    Label {
                        Text("Ayarlar")
                    } icon: {
                        Image.bundled("settings", fallbackSystemImage: "gearshape")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                    }
                }
                .help("Ayarlar (⌘,)")
            }
            ToolbarItem(placement: .primaryAction) {
                AppearancePickerView()
            }
        }
        .sheet(isPresented: $isShowingCreateTable) {
            CreateTableView(
                service: session.mysqlService,
                schemaTree: schemaTreeViewModel,
                defaultDatabase: createTableDefaultDatabase
                    ?? selectedTable?.database
                    ?? schemaTreeViewModel.databaseNodes.first?.info.name
                    ?? ""
            ) { createdTable in
                Task {
                    if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == createdTable.database }) {
                        await node.reload()
                    }
                    selectedTable = createdTable
                }
            }
        }
        .sheet(item: $namedObjectCreationRequest) { request in
            CreateNamedSchemaObjectView(
                title: request.kind.title,
                nameFieldLabel: request.kind.nameFieldLabel,
                database: request.database
            ) { name in
                console.isQueryPanelVisible = true
                console.pendingQueryAppend = request.kind.sql(database: request.database, name: name)
            }
        }
        .sheet(item: $tableToAlter) { table in
            AlterTableView(service: session.mysqlService, table: table) { alteredTable in
                Task {
                    if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == alteredTable.database }) {
                        await node.reload()
                    }
                    // Bounce the selection so the grid rebuilds with the new
                    // schema even when the table kept its name (same
                    // reasoning as the truncate refresh below).
                    selectedTable = nil
                    try? await Task.sleep(for: .milliseconds(50))
                    selectedTable = alteredTable
                }
            }
        }
        .confirmationDialog(
            "'\(tablePendingTruncate?.name ?? "")' tablosundaki TÜM satırlar silinsin mi?",
            isPresented: Binding(
                get: { tablePendingTruncate != nil },
                set: { if !$0 { tablePendingTruncate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Truncate", role: .destructive) {
                if let table = tablePendingTruncate {
                    Task { await truncateTable(table) }
                }
                tablePendingTruncate = nil
            }
            Button("İptal", role: .cancel) { tablePendingTruncate = nil }
        } message: {
            Text("TRUNCATE TABLE geri alınamaz.")
        }
        .confirmationDialog(
            tablePendingDrop?.isView == true
                ? "'\(tablePendingDrop?.name ?? "")' view'ı tamamen silinsin mi?"
                : "'\(tablePendingDrop?.name ?? "")' tablosu tamamen silinsin mi?",
            isPresented: Binding(
                get: { tablePendingDrop != nil },
                set: { if !$0 { tablePendingDrop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Drop", role: .destructive) {
                if let table = tablePendingDrop {
                    Task { await dropTable(table) }
                }
                tablePendingDrop = nil
            }
            Button("İptal", role: .cancel) { tablePendingDrop = nil }
        } message: {
            Text(
                tablePendingDrop?.isView == true
                    ? "DROP VIEW view'ı kalıcı olarak siler, geri alınamaz."
                    : "DROP TABLE tabloyu yapısıyla birlikte kalıcı olarak siler, geri alınamaz."
            )
        }
        .confirmationDialog(
            "'\(procedurePendingDrop?.name ?? "")' procedure'ü tamamen silinsin mi?",
            isPresented: Binding(
                get: { procedurePendingDrop != nil },
                set: { if !$0 { procedurePendingDrop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Drop", role: .destructive) {
                if let procedure = procedurePendingDrop {
                    Task { await dropProcedure(procedure) }
                }
                procedurePendingDrop = nil
            }
            Button("İptal", role: .cancel) { procedurePendingDrop = nil }
        } message: {
            Text("DROP PROCEDURE procedure'ü kalıcı olarak siler, geri alınamaz.")
        }
        .alert(
            "Hata",
            isPresented: Binding(
                get: { contextActionError != nil },
                set: { if !$0 { contextActionError = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) { contextActionError = nil }
        } message: {
            Text(contextActionError ?? "")
        }
    }

    /// The SQL console (when open) sits above whichever content follows —
    /// a selected table's grid, or the placeholder — with a draggable
    /// divider between them. Hoisted here (rather than living inside
    /// `TableDataGridView`) so it's reachable with *no* table selected at
    /// all, which is exactly the case a brand-new empty database needs:
    /// nothing in the sidebar to select yet, but the editor still has to
    /// be reachable to run a first `CREATE TABLE`.
    ///
    /// Deliberately not a `VSplitView`: `VSplitView` decides pane heights
    /// itself when a pane first appears, and it repeatedly opened the
    /// query panel squeezed below its content's real minimum no matter
    /// what min/ideal frames the pane declared. Owning the height in
    /// `@State` and applying it as an exact `.frame(height:)` makes a
    /// squeezed first layout impossible, at the cost of hand-rolling the
    /// divider drag.
    private var detailPane: some View {
        GeometryReader { geometry in
            // Explicit `.leading` + an explicit full-width frame on the
            // query panel: `VStack`'s default `.center` alignment let the
            // panel drift sideways at narrow widths, sized to whichever
            // child briefly reported the largest natural width instead of
            // staying pinned to the leading edge.
            VStack(alignment: .leading, spacing: 0) {
                if console.isQueryPanelVisible {
                    QueryPanelView(console: console)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: clampedPanelHeight(totalHeight: geometry.size.height))

                    splitDivider(totalHeight: geometry.size.height)
                }

                Group {
                    if let selectedTable {
                        TableDataGridView(
                            databaseName: selectedTable.database,
                            tableName: selectedTable.name,
                            service: session.mysqlService,
                            introspection: session.introspectionService,
                            console: console,
                            insertionBridge: insertionBridge,
                            onRowCountChange: { selectedTableRowCount = $0 }
                        )
                        .id(selectedTable.id)
                    } else {
                        emptyStatePlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Shown when nothing is selected in the sidebar. Still honors the
    /// console's query results — running a `SELECT` with no table open
    /// works exactly like it does with one open — so this isn't just a
    /// dead end while the sidebar is empty.
    private var emptyStatePlaceholder: some View {
        Group {
            if console.isShowingQueryResult {
                QueryResultTabbedView(console: console)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Bir tablo seçin")
                        .foregroundStyle(.secondary)

                    Button {
                        console.toggleQueryPanel()
                    } label: {
                        Label(console.isQueryPanelVisible ? "SQL Sorgusunu Gizle" : "SQL Sorgusu Çalıştır", systemImage: "terminal")
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The panel never renders below its content's real minimum, and
    /// whatever's below (grid or placeholder) always keeps at least
    /// `minGridHeight` — whichever way the user drags or the window
    /// resizes.
    private func clampedPanelHeight(totalHeight: CGFloat) -> CGFloat {
        let maxAllowed = max(Self.minPanelHeight, totalHeight - Self.minGridHeight)
        return min(max(queryPanelHeight, Self.minPanelHeight), maxAllowed)
    }

    private func splitDivider(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .gridLineColor))
            .frame(height: 5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = clampedPanelHeight(totalHeight: totalHeight)
                        }
                        queryPanelHeight = (dragStartHeight ?? Self.minPanelHeight) + value.translation.height
                    }
                    .onEnded { _ in
                        queryPanelHeight = clampedPanelHeight(totalHeight: totalHeight)
                        dragStartHeight = nil
                    }
            )
    }

    /// "SQL Sorgu Ekle" context-menu action: fetches the table's real
    /// column list, builds the statement skeleton, and routes it through
    /// the insertion bridge. The table is selected first so its grid (and
    /// the note in the header showing which table the columns came from)
    /// is visible alongside the appended statement.
    private func insertQueryTemplate(for table: TableInfo, kind: SQLTemplate.Kind) async {
        let columns: [ColumnInfo]
        do {
            columns = try await session.introspectionService.columns(forTable: table.name, inDatabase: table.database)
        } catch {
            contextActionError = "Kolonlar alınamadı: \(error.localizedDescription)"
            return
        }

        selectedTable = table
        insertionBridge.pendingAppend = SQLTemplate.generate(
            kind,
            database: table.database,
            table: table.name,
            columns: columns
        )
    }

    private func truncateTable(_ table: TableInfo) async {
        do {
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: table.database, name: table.name)
            try await session.mysqlService.execute("TRUNCATE TABLE \(qualified)")
        } catch {
            contextActionError = "Truncate başarısız: \(error.localizedDescription)"
            return
        }

        // The grid view's identity is keyed by `selectedTable.id`, which
        // doesn't change here — bouncing the selection through nil (across
        // two separate UI updates) is what forces a fresh grid that reloads
        // the now-empty table.
        if selectedTable?.id == table.id {
            selectedTable = nil
            try? await Task.sleep(for: .milliseconds(50))
            selectedTable = table
        }
    }

    private func dropTable(_ table: TableInfo) async {
        do {
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: table.database, name: table.name)
            let statement = table.isView ? "DROP VIEW \(qualified)" : "DROP TABLE \(qualified)"
            try await session.mysqlService.execute(statement)
        } catch {
            contextActionError = "Drop başarısız: \(error.localizedDescription)"
            return
        }

        if selectedTable?.id == table.id {
            selectedTable = nil
        }
        if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == table.database }) {
            await node.reload()
        }
    }

    /// "Alter View" context-menu action: reads the view's real definition
    /// back off the server (rather than reconstructing it from whatever's
    /// in the sidebar, which only ever holds the name) and appends it,
    /// reformatted, to the query console for editing.
    private func alterView(_ view: TableInfo) async {
        let createView: String
        do {
            createView = try await session.introspectionService.showCreateView(view.name, inDatabase: view.database)
        } catch {
            contextActionError = "View tanımı alınamadı: \(error.localizedDescription)"
            return
        }

        insertionBridge.pendingAppend = ViewAlterStatement.format(
            database: view.database,
            view: view.name,
            createView: createView
        )
    }

    /// "Alter Procedure" context-menu action — same shape as `alterView`.
    /// MySQL's own `ALTER PROCEDURE` can't change a procedure's body (only
    /// characteristics like `COMMENT`/`SQL SECURITY`), so "altering" one
    /// always means drop-and-recreate; see `ProcedureAlterStatement`.
    private func alterProcedure(_ procedure: ProcedureInfo) async {
        let createProcedure: String
        do {
            createProcedure = try await session.introspectionService.showCreateProcedure(procedure.name, inDatabase: procedure.database)
        } catch {
            contextActionError = "Procedure tanımı alınamadı: \(error.localizedDescription)"
            return
        }

        insertionBridge.pendingAppend = ProcedureAlterStatement.format(
            database: procedure.database,
            name: procedure.name,
            createProcedure: createProcedure
        )
    }

    private func dropProcedure(_ procedure: ProcedureInfo) async {
        do {
            let qualified = try SchemaIntrospectionService.qualifiedIdentifier(database: procedure.database, name: procedure.name)
            // `rawQuery`, not `execute` — `DROP PROCEDURE` is rejected by
            // the prepared-statement protocol (`ER_UNSUPPORTED_PS`), and
            // `rawQuery` is the one method that already retries through
            // the plain-text protocol when that happens.
            _ = try await session.mysqlService.rawQuery("DROP PROCEDURE \(qualified)")
        } catch {
            contextActionError = "Drop başarısız: \(error.localizedDescription)"
            return
        }

        if let node = schemaTreeViewModel.databaseNodes.first(where: { $0.info.name == procedure.database }) {
            await node.reloadProcedures()
        }
    }
}
