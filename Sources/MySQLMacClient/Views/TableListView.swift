import SwiftUI

/// Sidebar schema tree: Server > Databases > Tablolar/View'lar/Procedure'lar/Function'lar
/// > table > Kolonlar/İndeksler. Every level below "Databases" loads lazily,
/// only when that specific row is first expanded. Triggers/events are still a
/// later phase.
///
/// Built on a plain `ScrollView`/`LazyVStack`, not `List`/`DisclosureGroup`:
/// SwiftUI's native `DisclosureGroup` bakes in enough row padding that
/// `.listRowInsets`/`defaultMinListRowHeight` can't shrink it below a fairly
/// tall row, which read as "still too spaced out" — this gives pixel-level
/// control over row height/indent instead.
struct TableListView: View {
    @ObservedObject var viewModel: SchemaTreeViewModel
    @Binding var selectedTable: TableInfo?
    let insertionBridge: SQLInsertionBridge
    /// Context-menu actions on a table row — owned by `MainWindowView`,
    /// which has the session/sheet/confirmation state they need.
    let onCreateTable: (String) -> Void
    let onCreateView: (String) -> Void
    let onCreateStoredProcedure: (String) -> Void
    let onCreateFunction: (String) -> Void
    let onCreateTrigger: (String) -> Void
    let onCreateEvent: (String) -> Void
    let onBackupDatabase: (DatabaseInfo) -> Void
    let onTruncateTable: (TableInfo) -> Void
    let onDropTable: (TableInfo) -> Void
    let onInsertQueryTemplate: (TableInfo, SQLTemplate.Kind) -> Void
    let onAlterTable: (TableInfo) -> Void
    let onExportTable: (TableInfo) -> Void
    let onShowTableInfo: (TableInfo) -> Void
    let onAlterView: (TableInfo) -> Void
    let onDropView: (TableInfo) -> Void
    let onAlterRoutine: (RoutineInfo) -> Void
    let onDropRoutine: (RoutineInfo) -> Void

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.databaseNodes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
            } else if viewModel.databaseNodes.isEmpty {
                Text("Veritabanı bulunamadı.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.databaseNodes) { node in
                            DatabaseRow(
                                node: node,
                                selectedTable: $selectedTable,
                                insertionBridge: insertionBridge,
                                onCreateTable: onCreateTable,
                                onCreateView: onCreateView,
                                onCreateStoredProcedure: onCreateStoredProcedure,
                                onCreateFunction: onCreateFunction,
                                onCreateTrigger: onCreateTrigger,
                                onCreateEvent: onCreateEvent,
                                onBackupDatabase: onBackupDatabase,
                                onTruncateTable: onTruncateTable,
                                onDropTable: onDropTable,
                                onInsertQueryTemplate: onInsertQueryTemplate,
                                onAlterTable: onAlterTable,
                                onExportTable: onExportTable,
                                onShowTableInfo: onShowTableInfo,
                                onAlterView: onAlterView,
                                onDropView: onDropView,
                                onAlterRoutine: onAlterRoutine,
                                onDropRoutine: onDropRoutine
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await viewModel.loadDatabases() }
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

/// Shared row chrome: an optional chevron (tap toggles expansion), an icon,
/// a title, and optional trailing text — all at a fixed, compact height.
/// The chevron and the rest of the row have independent tap targets, so
/// clicking a table's label selects it without also having to expand it.
private struct RowHeader: View {
    let title: String
    let systemImage: String
    let iconColor: Color
    let indent: CGFloat
    let isExpandable: Bool
    let isExpanded: Bool
    var trailing: String? = nil
    var isSelected: Bool = false
    var onToggle: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    /// All row typography derives from the sidebar settings' single font
    /// size (secondary text one point smaller, chevron three smaller), so
    /// one slider scales the whole tree coherently.
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        let fontSize = CGFloat(settingsStore.settings.sidebar.fontSize)
        let verticalPadding = CGFloat(settingsStore.settings.sidebar.rowVerticalPadding)
        // Recomputed on every render (mirrors `QueryPanelView.statusRow`'s
        // pattern): `settingsColor` returns a fresh appearance-aware
        // `NSColor` each call, so wrapping it in `Color` here always
        // reflects the *current* theme rather than one captured at first
        // draw.
        let textColor = Color(nsColor: .settingsColor({ $0.sidebar.textColor }, fallback: .labelColor))

        HStack(spacing: 5) {
            Group {
                if isExpandable {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .contentShape(Rectangle())
                        .onTapGesture { onToggle?() }
                } else {
                    Color.clear
                }
            }
            .font(.system(size: max(8, fontSize - 3), weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 16)

            Image(systemName: systemImage)
                .font(.system(size: fontSize))
                .foregroundStyle(iconColor)
                .frame(width: fontSize + 3)

            Text(title)
                .font(.system(size: fontSize))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let trailing {
                Text(trailing)
                    .font(.system(size: max(9, fontSize - 1)))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, indent)
        .padding(.trailing, 8)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
        .foregroundStyle(isSelected ? Color.white : textColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleClick?() }
        .onTapGesture { onSelect?() }
    }
}

/// Schema-tree icon colors are settings-driven. Resolved fresh on every
/// render for the same reason as `RowHeader`'s `textColor`: `settingsColor`
/// hands back an appearance-aware `NSColor` per call, so wrapping it here
/// reflects both the current theme *and* the latest value picked in the
/// Ayarlar window without anything having to be recreated.
@MainActor
private func sidebarIconColor(
    _ select: @escaping @Sendable (AppSettings) -> AdaptiveColorSetting
) -> Color {
    Color(nsColor: .settingsColor(select, fallback: .secondaryLabelColor))
}

/// A fixed schema category (Tablolar, View'lar, Kolonlar, İndeksler) whose
/// items load lazily on first expansion.
private struct CategoryRow<Item: Identifiable, RowContent: View>: View {
    let title: String
    let systemImage: String
    let iconColor: Color
    let indent: CGFloat
    let items: [Item]
    let isLoading: Bool
    let isLoaded: Bool
    let errorMessage: String?
    let emptyText: String
    let onExpand: () -> Void
    @ViewBuilder let rowContent: (Item) -> RowContent

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowHeader(
                title: title,
                systemImage: systemImage,
                iconColor: iconColor,
                indent: indent,
                isExpandable: true,
                isExpanded: isExpanded,
                onToggle: toggle,
                onSelect: toggle
            )

            if isExpanded {
                if isLoading {
                    placeholder("Yükleniyor…")
                } else if let errorMessage {
                    placeholder(errorMessage, color: .red)
                } else if isLoaded && items.isEmpty {
                    placeholder(emptyText)
                } else {
                    ForEach(items) { item in
                        rowContent(item)
                    }
                }
            }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
        if isExpanded { onExpand() }
    }

    private func placeholder(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: max(9, CGFloat(SettingsStore.shared.settings.sidebar.fontSize) - 1)))
            .foregroundStyle(color)
            .padding(.leading, indent + 26)
            .padding(.vertical, 2)
    }
}

private struct DatabaseRow: View {
    @ObservedObject var node: DatabaseNode
    @Binding var selectedTable: TableInfo?
    let insertionBridge: SQLInsertionBridge
    let onCreateTable: (String) -> Void
    let onCreateView: (String) -> Void
    let onCreateStoredProcedure: (String) -> Void
    let onCreateFunction: (String) -> Void
    let onCreateTrigger: (String) -> Void
    let onCreateEvent: (String) -> Void
    let onBackupDatabase: (DatabaseInfo) -> Void
    let onTruncateTable: (TableInfo) -> Void
    let onDropTable: (TableInfo) -> Void
    let onInsertQueryTemplate: (TableInfo, SQLTemplate.Kind) -> Void
    let onAlterTable: (TableInfo) -> Void
    let onExportTable: (TableInfo) -> Void
    let onShowTableInfo: (TableInfo) -> Void
    let onAlterView: (TableInfo) -> Void
    let onDropView: (TableInfo) -> Void
    let onAlterRoutine: (RoutineInfo) -> Void
    let onDropRoutine: (RoutineInfo) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowHeader(
                title: node.info.name,
                systemImage: "cylinder.split.1x2",
                iconColor: sidebarIconColor { $0.sidebar.databaseIcon },
                indent: 0,
                isExpandable: true,
                isExpanded: isExpanded,
                onToggle: toggle,
                onSelect: toggle
            )
            .contextMenu {
                databaseContextMenu
            }

            if isExpanded {
                CategoryRow(
                    title: "Tablolar",
                    systemImage: "tablecells",
                    iconColor: sidebarIconColor { $0.sidebar.tablesGroupIcon },
                    indent: 14,
                    items: node.baseTableNodes,
                    isLoading: node.isLoading,
                    isLoaded: node.isLoaded,
                    errorMessage: node.errorMessage,
                    emptyText: "Tablo yok",
                    onExpand: { Task { await node.loadIfNeeded() } }
                ) { tableNode in
                    TableTreeRow(
                        node: tableNode,
                        selectedTable: $selectedTable,
                        indent: 28,
                        insertionBridge: insertionBridge,
                        onTruncateTable: onTruncateTable,
                        onDropTable: onDropTable,
                        onInsertQueryTemplate: onInsertQueryTemplate,
                        onAlterTable: onAlterTable,
                        onExportTable: onExportTable,
                        onShowTableInfo: onShowTableInfo,
                        onAlterView: onAlterView,
                        onDropView: onDropView
                    )
                }

                CategoryRow(
                    title: "View'lar",
                    systemImage: "eye",
                    iconColor: sidebarIconColor { $0.sidebar.viewsGroupIcon },
                    indent: 14,
                    items: node.viewNodes,
                    isLoading: node.isLoading,
                    isLoaded: node.isLoaded,
                    errorMessage: node.errorMessage,
                    emptyText: "View yok",
                    onExpand: { Task { await node.loadIfNeeded() } }
                ) { tableNode in
                    TableTreeRow(
                        node: tableNode,
                        selectedTable: $selectedTable,
                        indent: 28,
                        insertionBridge: insertionBridge,
                        onTruncateTable: onTruncateTable,
                        onDropTable: onDropTable,
                        onInsertQueryTemplate: onInsertQueryTemplate,
                        onAlterTable: onAlterTable,
                        onExportTable: onExportTable,
                        onShowTableInfo: onShowTableInfo,
                        onAlterView: onAlterView,
                        onDropView: onDropView
                    )
                }

                ForEach(RoutineKind.allCases, id: \.self) { kind in
                    let state = node.routineState(kind)
                    CategoryRow(
                        title: kind.categoryTitle,
                        systemImage: routineIcon(kind),
                        iconColor: sidebarIconColor { settings in
                            kind == .procedure ? settings.sidebar.proceduresGroupIcon : settings.sidebar.functionsGroupIcon
                        },
                        indent: 14,
                        items: state.routines,
                        isLoading: state.isLoading,
                        isLoaded: state.isLoaded,
                        errorMessage: state.errorMessage,
                        emptyText: kind.emptyCategoryText,
                        onExpand: { Task { await node.loadRoutinesIfNeeded(kind) } }
                    ) { routine in
                        RoutineRow(
                            routine: routine,
                            indent: 28,
                            onAlterRoutine: onAlterRoutine,
                            onDropRoutine: onDropRoutine
                        )
                    }
                }
            }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
    }

    @ViewBuilder
    private var databaseContextMenu: some View {
        Menu("Oluştur") {
            Button("Tablo...") {
                onCreateTable(node.info.name)
            }
            Button("View...") {
                onCreateView(node.info.name)
            }
            Button("Stored Procedure...") {
                onCreateStoredProcedure(node.info.name)
            }
            Button("Function...") {
                onCreateFunction(node.info.name)
            }
            Button("Trigger...") {
                onCreateTrigger(node.info.name)
            }
            Button("Event...") {
                onCreateEvent(node.info.name)
            }
        }

        Divider()

        Button("Backup...") {
            onBackupDatabase(node.info)
        }
    }
}

private struct TableTreeRow: View {
    @ObservedObject var node: TableNode
    @Binding var selectedTable: TableInfo?
    let indent: CGFloat
    let insertionBridge: SQLInsertionBridge
    let onTruncateTable: (TableInfo) -> Void
    let onDropTable: (TableInfo) -> Void
    let onInsertQueryTemplate: (TableInfo, SQLTemplate.Kind) -> Void
    let onAlterTable: (TableInfo) -> Void
    let onExportTable: (TableInfo) -> Void
    let onShowTableInfo: (TableInfo) -> Void
    let onAlterView: (TableInfo) -> Void
    let onDropView: (TableInfo) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowHeader(
                title: node.info.name,
                systemImage: node.info.isView ? "eye" : "tablecells",
                iconColor: node.info.isView
                    ? sidebarIconColor { $0.sidebar.viewIcon }
                    : sidebarIconColor { $0.sidebar.tableIcon },
                indent: indent,
                isExpandable: true,
                isExpanded: isExpanded,
                isSelected: selectedTable?.id == node.info.id,
                onToggle: { withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() } },
                onSelect: { selectedTable = node.info },
                onDoubleClick: {
                    insertionBridge.pendingText = "`\(node.info.database)`.`\(node.info.name)`"
                }
            )
            .contextMenu {
                // TRUNCATE TABLE and the "SQL Sorgu Ekle" templates assume a
                // real table, so views get their own, much shorter menu
                // instead of the table one.
                if node.info.isView {
                    viewContextMenu
                } else {
                    tableContextMenu
                }
            }

            if isExpanded {
                CategoryRow(
                    title: "Kolonlar",
                    systemImage: "list.bullet",
                    iconColor: sidebarIconColor { $0.sidebar.columnsIcon },
                    indent: indent + 14,
                    items: node.columns,
                    isLoading: node.isLoadingColumns,
                    isLoaded: node.isColumnsLoaded,
                    errorMessage: node.columnsErrorMessage,
                    emptyText: "Kolon yok",
                    onExpand: { Task { await node.loadColumnsIfNeeded() } }
                ) { column in
                    ColumnRow(column: column, indent: indent + 28, tableInfo: node.info, selectedTable: $selectedTable, insertionBridge: insertionBridge)
                }

                CategoryRow(
                    title: "İndeksler",
                    systemImage: "arrow.up.arrow.down",
                    iconColor: sidebarIconColor { $0.sidebar.indexesIcon },
                    indent: indent + 14,
                    items: node.indexes,
                    isLoading: node.isLoadingIndexes,
                    isLoaded: node.isIndexesLoaded,
                    errorMessage: node.indexesErrorMessage,
                    emptyText: "İndeks yok",
                    onExpand: { Task { await node.loadIndexesIfNeeded() } }
                ) { index in
                    IndexRow(index: index, indent: indent + 28)
                }
            }
        }
    }

    @ViewBuilder
    private var tableContextMenu: some View {
        Button("İnfo") {
            onShowTableInfo(node.info)
        }

        Divider()

        Menu("SQL Sorgu Ekle") {
            Button("INSERT INTO") {
                onInsertQueryTemplate(node.info, .insert)
            }
            Button("UPDATE") {
                onInsertQueryTemplate(node.info, .update)
            }
            Button("DELETE FROM") {
                onInsertQueryTemplate(node.info, .delete)
            }
            Button("SELECT") {
                onInsertQueryTemplate(node.info, .select)
            }
        }

        Button("Alter Table") {
            onAlterTable(node.info)
        }

        Button("Export...") {
            onExportTable(node.info)
        }

        Divider()

        Button("Truncate Table") {
            onTruncateTable(node.info)
        }

        Button("Drop Table", role: .destructive) {
            onDropTable(node.info)
        }
    }

    @ViewBuilder
    private var viewContextMenu: some View {
        Button("Export...") {
            onExportTable(node.info)
        }

        Button("Alter View") {
            onAlterView(node.info)
        }

        Button("Drop View", role: .destructive) {
            onDropView(node.info)
        }
    }
}

private struct ColumnRow: View {
    let column: ColumnInfo
    let indent: CGFloat
    let tableInfo: TableInfo
    @Binding var selectedTable: TableInfo?
    let insertionBridge: SQLInsertionBridge

    var body: some View {
        RowHeader(
            title: column.name,
            systemImage: column.isPrimaryKey ? "key.fill" : "minus",
            // The primary key keeps its orange key deliberately: that's a
            // semantic highlight, not theming. `columnsIcon` colors the
            // ordinary columns around it.
            iconColor: column.isPrimaryKey ? .orange : sidebarIconColor { $0.sidebar.columnsIcon },
            indent: indent,
            isExpandable: false,
            isExpanded: false,
            trailing: column.mysqlType,
            onDoubleClick: {
                // Guarantees the query panel's `TableDataGridView` actually
                // exists to receive `insertionBridge.pendingText` — without
                // this, double-clicking a column under a table that was
                // never selected (only expanded) set the bridge and nothing
                // was there to consume it.
                selectedTable = tableInfo
                insertionBridge.pendingText = "`\(column.name)`"
            }
        )
    }
}

/// The SF Symbol for a routine category/row — shared so the category and
/// its children can't drift apart.
private func routineIcon(_ kind: RoutineKind) -> String {
    switch kind {
    case .procedure: return "gearshape.2"
    case .function: return "function"
    }
}

/// A leaf row — a stored routine has no Kolonlar/İndeksler-style children,
/// just the Alter/Drop actions, same shape as `viewContextMenu` above. One
/// type covers procedures and functions alike; see `RoutineKind`.
private struct RoutineRow: View {
    let routine: RoutineInfo
    let indent: CGFloat
    let onAlterRoutine: (RoutineInfo) -> Void
    let onDropRoutine: (RoutineInfo) -> Void

    var body: some View {
        RowHeader(
            title: routine.name,
            systemImage: routineIcon(routine.kind),
            iconColor: sidebarIconColor { settings in
                routine.kind == .procedure ? settings.sidebar.procedureIcon : settings.sidebar.functionIcon
            },
            indent: indent,
            isExpandable: false,
            isExpanded: false
        )
        .contextMenu {
            Button("Alter \(routine.kind.displayName)") {
                onAlterRoutine(routine)
            }

            Button("Drop \(routine.kind.displayName)", role: .destructive) {
                onDropRoutine(routine)
            }
        }
    }
}

private struct IndexRow: View {
    let index: IndexInfo
    let indent: CGFloat

    var body: some View {
        RowHeader(
            title: index.name,
            systemImage: index.isUnique ? "checkmark.seal" : "number",
            iconColor: sidebarIconColor { $0.sidebar.indexesIcon },
            indent: indent,
            isExpandable: false,
            isExpanded: false,
            trailing: index.columns.joined(separator: ", ")
        )
    }
}
