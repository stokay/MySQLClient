import SwiftUI

/// One table's toolbar + grid (or İnfo report, or text view). The SQL query
/// panel above it — and the split between the two — now lives one level up
/// in `MainWindowView`, shared with the no-table-selected placeholder; this
/// view only renders the *result* of that shared console's state
/// (`console.isShowingQueryResult`) for whichever table is currently
/// selected. Column set is built dynamically from the table's schema. The
/// grid itself is `SpreadsheetGridView`, an `NSTableView` wrapper — see that
/// file for why this isn't SwiftUI's native `Table`.
struct TableDataGridView: View {
    @StateObject private var viewModel: TableDataViewModel
    @ObservedObject var console: SQLConsoleViewModel
    @ObservedObject var insertionBridge: SQLInsertionBridge
    /// For the İnfo report's font size/color (live-updating).
    @EnvironmentObject private var settingsStore: SettingsStore
    /// Reports this table's total row count up to `MainWindowView`, which
    /// forwards it into the session-level `StatusBarView` — this view has
    /// no direct reference to that bar itself.
    let onRowCountChange: (Int) -> Void

    /// Grid (default) vs. mysql-CLI-style aligned text rendering of the
    /// same rows — toggled by the two leftmost toolbar buttons.
    @State private var isTextViewMode = false

    init(
        databaseName: String,
        tableName: String,
        service: MySQLService,
        introspection: SchemaIntrospectionService,
        console: SQLConsoleViewModel,
        insertionBridge: SQLInsertionBridge,
        historyRecorder: QueryHistoryRecorder? = nil,
        onRowCountChange: @escaping (Int) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: TableDataViewModel(
            databaseName: databaseName,
            tableName: tableName,
            service: service,
            introspection: introspection,
            historyRecorder: historyRecorder
        ))
        self.console = console
        self.insertionBridge = insertionBridge
        self.onRowCountChange = onRowCountChange
    }

    var body: some View {
        // Explicit `.leading`: `VStack`'s default `.center` alignment let
        // this whole column reposition sideways whenever a child's natural
        // width (esp. the toolbar's, before the fix above) briefly won or
        // lost the "widest child" comparison as the window resized.
        VStack(alignment: .leading, spacing: 0) {
            gridToolbar

            Divider()

            if !viewModel.hasPrimaryKey && !viewModel.isLoading && !console.isShowingQueryResult && viewModel.tableInfoText == nil {
                Label("This table has no primary key; editing is disabled.", systemImage: "exclamationmark.triangle.fill")
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.2))
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
            }

            if let infoText = viewModel.tableInfoText {
                ScrollView([.vertical, .horizontal]) {
                    Text(infoText)
                        .font(.system(size: CGFloat(settingsStore.settings.info.fontSize), design: .monospaced))
                        .foregroundStyle(Color(nsColor: .settingsColor({ $0.info.textColor }, fallback: .labelColor)))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else if viewModel.isLoading && viewModel.rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isTextViewMode {
                textualRowsView
            } else if console.isShowingQueryResult {
                QueryResultTabbedView(console: console)
            } else {
                SpreadsheetGridView(viewModel: viewModel)
            }
        }
        .task(id: viewModel.tableName) {
            await viewModel.load()
        }
        .navigationTitle(viewModel.tableName)
        .onAppear {
            // This table is now the one "Tablo Görünümüne Dön" should
            // refresh. Capturing `viewModel` strongly is fine, not a
            // leak: this view (and closure) is recreated on every table
            // selection change, and each `.onAppear` simply *replaces*
            // `console.onQueryResultCleared`, releasing the previous
            // table's reference at that point.
            let capturedViewModel = viewModel
            console.onQueryResultCleared = {
                await capturedViewModel.reload()
            }
            if insertionBridge.pendingShowInfo {
                insertionBridge.pendingShowInfo = false
                Task { await viewModel.showTableInfo() }
            }
        }
        .onChange(of: insertionBridge.pendingShowInfo) { _, newValue in
            guard newValue else { return }
            insertionBridge.pendingShowInfo = false
            Task { await viewModel.showTableInfo() }
        }
        .onChange(of: viewModel.totalRowCount, initial: true) { _, newValue in
            onRowCountChange(newValue)
        }
    }

    /// The current rows (main table or query result — whichever is on
    /// screen) rendered as the same aligned plain-text table the İnfo
    /// report uses. Font/size follow the SQL editor settings, per spec.
    private var textualRowsView: some View {
        let headers: [String]
        let rows: [[String]]
        if console.isShowingQueryResult {
            headers = console.queryResultColumns
            rows = console.queryResultRows.map { row in headers.map { row.editedText[$0] ?? "" } }
        } else {
            headers = viewModel.columns.map(\.name)
            rows = viewModel.rows.map { row in headers.map { row.editedText[$0] ?? "" } }
        }

        return ScrollView([.vertical, .horizontal]) {
            Text(TableInfoReport.textTable(headers: headers, rows: rows))
                .font(.system(size: CGFloat(settingsStore.settings.editor.fontSize), design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Horizontally scrollable rather than a plain `HStack`: at narrow
    /// window widths, an `HStack` this dense (view-mode toggle, SQL/Yenile/
    /// Satır Ekle buttons, the whole pagination+filter row) has nowhere to
    /// shrink to — SwiftUI compresses the `Text`/`Label` children instead,
    /// which wrap onto a second line and grow the toolbar's height, and
    /// the still-too-wide row then gets center-repositioned by the parent
    /// `VStack` instead of staying pinned left. Scrolling sidesteps both:
    /// content is proposed effectively unbounded width (nothing wraps) and
    /// stays anchored to the leading edge (nothing recenters).
    private var gridToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if viewModel.tableInfoText != nil {
                    // Info report mode: the whole toolbar reduces to the way
                    // back — the report is read-only, so the edit/refresh/query
                    // controls would all be dead weight next to it.
                    Button {
                        viewModel.tableInfoText = nil
                    } label: {
                        Label("Back to Table View", systemImage: "tablecells")
                            .lineLimit(1)
                    }

                    Text("Info — \(viewModel.tableName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    regularToolbarContent
                }
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func viewModeButton(icon: String, fallbackSystemImage: String, help: LocalizedStringKey, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.bundled(
                icon,
                fallbackSystemImage: fallbackSystemImage,
                pointSize: settingsStore.settings.general.gridToolbarIconSize
            )
        }
        .buttonStyle(.plain)
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Color.accentColor.opacity(0.22) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isActive ? Color.accentColor : Color.clear))
        // The inactive mode's icon reads as "disabled" (dimmed) but stays
        // clickable — that's the switch.
        .opacity(isActive ? 1 : 0.45)
        .help(help)
    }

    @ViewBuilder
    private var regularToolbarContent: some View {
        Group {
            viewModeButton(
                icon: "grid_view",
                fallbackSystemImage: "tablecells",
                help: "Grid View",
                isActive: !isTextViewMode
            ) {
                isTextViewMode = false
            }
            viewModeButton(
                icon: "text_view",
                fallbackSystemImage: "text.justify.left",
                help: "Text View",
                isActive: isTextViewMode
            ) {
                isTextViewMode = true
            }

            Divider().frame(height: 16)

            Button {
                console.toggleQueryPanel(defaultTable: (viewModel.databaseName, viewModel.tableName))
            } label: {
                Label("SQL Query", systemImage: "terminal")
                    .lineLimit(1)
            }

            if !console.isShowingQueryResult {
                Divider().frame(height: 16)

                Button {
                    Task { await viewModel.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .lineLimit(1)
                }
                Button {
                    viewModel.addDraftRow()
                } label: {
                    Label("Add Row", systemImage: "plus")
                        .lineLimit(1)
                }
                .disabled(!viewModel.hasPrimaryKey)

                Divider().frame(height: 16)

                PaginationControlView(viewModel: viewModel)
            }
        }
    }
}
