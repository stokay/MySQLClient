import Foundation

/// One database node in the sidebar tree. Its tables/views are loaded lazily
/// — only when the node is first expanded — so connecting to a server with
/// many databases doesn't fire a `SHOW FULL TABLES` per database upfront.
@MainActor
final class DatabaseNode: ObservableObject, Identifiable {
    let info: DatabaseInfo
    nonisolated var id: String { info.id }

    @Published private(set) var tableNodes: [TableNode] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoaded = false
    @Published var errorMessage: String?

    /// Per-`RoutineKind` state for the Procedure'lar / Function'lar
    /// categories. They're separate from Tablolar/View'lar (which share one
    /// `SHOW FULL TABLES` call) and from each other — each loads only when
    /// its own category row is expanded, the same lazy-per-category pattern
    /// as a table's Kolonlar/İndeksler.
    struct RoutineCategoryState {
        var routines: [RoutineInfo] = []
        var isLoading = false
        var isLoaded = false
        var errorMessage: String?
    }

    @Published private(set) var routineStates: [RoutineKind: RoutineCategoryState] = [:]

    func routineState(_ kind: RoutineKind) -> RoutineCategoryState {
        routineStates[kind] ?? RoutineCategoryState()
    }

    private let introspection: SchemaIntrospectionService

    init(info: DatabaseInfo, introspection: SchemaIntrospectionService) {
        self.info = info
        self.introspection = introspection
    }

    var baseTableNodes: [TableNode] { tableNodes.filter { !$0.info.isView } }
    var viewNodes: [TableNode] { tableNodes.filter { $0.info.isView } }

    func loadIfNeeded() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let tables = try await introspection.listTablesAndViews(inDatabase: info.name)
            tableNodes = tables.map { TableNode(info: $0, introspection: introspection) }
            isLoaded = true
        } catch {
            errorMessage = String(localized: "Could not load table list: \(error.localizedDescription)")
        }
    }

    /// Forces a re-fetch even if already loaded — used after creating a
    /// table so the new entry shows up without the user manually toggling
    /// the row closed and open again.
    func reload() async {
        isLoaded = false
        await loadIfNeeded()
    }

    func loadRoutinesIfNeeded(_ kind: RoutineKind) async {
        var state = routineState(kind)
        guard !state.isLoaded, !state.isLoading else { return }
        state.isLoading = true
        state.errorMessage = nil
        routineStates[kind] = state
        do {
            state.routines = try await introspection.listRoutines(kind, inDatabase: info.name)
            state.isLoaded = true
        } catch {
            state.errorMessage = String(localized: "Could not load \(kind.displayName) list: \(error.localizedDescription)")
        }
        state.isLoading = false
        routineStates[kind] = state
    }

    /// See `reload()` — same "force a fresh fetch" need after Alter/Drop
    /// changes the list.
    func reloadRoutines(_ kind: RoutineKind) async {
        var state = routineState(kind)
        state.isLoaded = false
        routineStates[kind] = state
        await loadRoutinesIfNeeded(kind)
    }
}

/// One table/view node. Expanding it reveals two fixed child categories,
/// "Kolonlar" and "İndeksler", each loaded lazily and independently — only
/// when that specific category is expanded, not just the table row.
@MainActor
final class TableNode: ObservableObject, Identifiable {
    let info: TableInfo
    nonisolated var id: String { info.id }

    @Published private(set) var columns: [ColumnInfo] = []
    @Published private(set) var isLoadingColumns = false
    @Published private(set) var isColumnsLoaded = false
    @Published var columnsErrorMessage: String?

    @Published private(set) var indexes: [IndexInfo] = []
    @Published private(set) var isLoadingIndexes = false
    @Published private(set) var isIndexesLoaded = false
    @Published var indexesErrorMessage: String?

    private let introspection: SchemaIntrospectionService

    init(info: TableInfo, introspection: SchemaIntrospectionService) {
        self.info = info
        self.introspection = introspection
    }

    func loadColumnsIfNeeded() async {
        guard !isColumnsLoaded, !isLoadingColumns else { return }
        isLoadingColumns = true
        columnsErrorMessage = nil
        defer { isLoadingColumns = false }
        do {
            columns = try await introspection.columns(forTable: info.name, inDatabase: info.database)
            isColumnsLoaded = true
        } catch {
            columnsErrorMessage = String(localized: "Could not load columns: \(error.localizedDescription)")
        }
    }

    func loadIndexesIfNeeded() async {
        guard !isIndexesLoaded, !isLoadingIndexes else { return }
        isLoadingIndexes = true
        indexesErrorMessage = nil
        defer { isLoadingIndexes = false }
        do {
            indexes = try await introspection.indexes(forTable: info.name, inDatabase: info.database)
            isIndexesLoaded = true
        } catch {
            indexesErrorMessage = String(localized: "Could not load indexes: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class SchemaTreeViewModel: ObservableObject {
    @Published private(set) var databaseNodes: [DatabaseNode] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let introspection: SchemaIntrospectionService

    init(introspection: SchemaIntrospectionService) {
        self.introspection = introspection
    }

    func loadDatabases() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let databases = try await introspection.listDatabases()
            databaseNodes = databases.map { DatabaseNode(info: $0, introspection: introspection) }
        } catch {
            errorMessage = String(localized: "Could not load database list: \(error.localizedDescription)")
        }
    }
}
