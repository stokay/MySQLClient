import SwiftUI
import AppKit

/// `NSTableView`-backed replacement for the SwiftUI `Table` we started
/// with. SwiftUI's `Table` bakes in enough internal cell/row padding
/// (likely AppKit's own `intercellSpacing` under the hood, inaccessible
/// from the SwiftUI API) that a custom overlay could never be reliably
/// aligned with the header separator or reach the true row edges — see the
/// git history on this file for the offset-chasing that didn't converge.
/// `NSTableView` gives direct control over `intercellSpacing` and
/// `gridStyleMask`, so the header separators and the grid lines are drawn
/// by the same AppKit geometry instead of two independently-guessed ones.
/// Shared header/selection styling lives in `GridStyling.swift` — the SQL
/// query results grid (`QueryResultGridView`) reuses the same look.
struct SpreadsheetGridView: NSViewRepresentable {
    @ObservedObject var viewModel: TableDataViewModel
    /// Observed so any settings change re-invokes `updateNSView`, which
    /// applies row height/fonts and reloads cells with the new styling.
    @EnvironmentObject private var settingsStore: SettingsStore

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = .gridLineColor
        tableView.intercellSpacing = NSSize(width: 1, height: 1)
        tableView.rowHeight = CGFloat(settingsStore.settings.grid.rowHeight)
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false

        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.viewModel = viewModel
        if let tableView = context.coordinator.tableView {
            tableView.rowHeight = CGFloat(settingsStore.settings.grid.rowHeight)
            tableView.headerView?.needsDisplay = true
        }
        context.coordinator.rebuildColumnsIfNeeded()
        context.coordinator.refreshHeaderTitles()
        context.coordinator.reloadPreservingActiveEdit()
        context.coordinator.focusPendingRowIfNeeded()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var viewModel: TableDataViewModel
        weak var tableView: NSTableView?
        private var lastColumnSignature: [String] = []
        /// The selected row tracked by ID rather than by index: AppKit's
        /// selection is index-based, and a `reloadData()` right after an
        /// insert (the flag-clearing update that follows "Satır Ekle")
        /// drops it. Re-resolving the ID after every reload keeps the
        /// highlight on the row the user is actually looking at.
        private var selectedRowID: TableRow.ID?
        /// The same selection keyed by its primary-key values, for the case
        /// the ID can't survive: `Yenile` (and sort/filter/page changes)
        /// refetches every row, so the selected row comes back as a
        /// different `TableRow` instance — same record, new ID.
        private var selectedRowKey: [String: String]?
        /// `TableDataViewModel.dataVersion` as of the last reload, to tell a
        /// refetch from an in-place redraw.
        private var lastDataVersion = 0
        // `deinit` is implicitly nonisolated even on a `@MainActor` class
        // (it can run from any thread), so cleaning this up there needs an
        // escape from actor-isolation checking — safe here since it's just
        // an opaque removal token, not something being concurrently mutated.
        nonisolated(unsafe) private var keyMonitor: Any?

        private static let deleteColumnID = NSUserInterfaceItemIdentifier("__delete__")

        init(viewModel: TableDataViewModel) {
            self.viewModel = viewModel
            super.init()
            // A plain `NSTextFieldDelegate`'s `control(_:textView:doCommandBy:)`
            // hook never actually fired here — SwiftUI installs its own
            // Tab-based focus navigation ahead of it in the responder chain
            // for a view embedded via `NSViewRepresentable`, a known SwiftUI/
            // AppKit interop gap. A local event monitor runs earlier still
            // (as part of `NSApplication`'s own event dispatch, before
            // routing to any window/view), so it's the one hook that
            // reliably wins the race.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // `NSEvent` isn't `Sendable`, so it can't be the return value
                // of `assumeIsolated`'s closure — only a plain `Bool` crosses
                // back out; the actual `NSEvent?` result is assembled here,
                // outside the isolated closure.
                let consumed = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
                return consumed ? nil : event
            }
        }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }

        /// Returns `true` when Tab/Shift-Tab was pressed while a cell
        /// belonging to *this* table is actually being edited (and the
        /// event should be swallowed) — anything else (typing elsewhere in
        /// the window, Tab in the SQL editor, etc.) passes through untouched.
        private func handleKeyDown(_ event: NSEvent) -> Bool {
            guard event.keyCode == 48 /* Tab */,
                  let (rowID, columnName) = currentEditingCell(),
                  let row = viewModel.rows.firstIndex(where: { $0.id == rowID })
            else { return false }
            moveEdit(fromRow: row, column: columnName, direction: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        }

        /// A cell's text field identifies itself by row **ID**, not row
        /// index: committing the draft row refetches `rows` while a field
        /// editor can still be open (the reload itself is deferred, see
        /// `reloadPreservingActiveEdit`), and an index captured before that
        /// would afterwards point at a different row — writing the user's
        /// text into the wrong record.
        private static func cellIdentifier(rowID: TableRow.ID, column: String) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("\(rowID.uuidString)|\(column)")
        }

        private static func parseCellIdentifier(_ identifier: String) -> (rowID: TableRow.ID, column: String)? {
            let parts = identifier.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let rowID = UUID(uuidString: String(parts[0])) else { return nil }
            return (rowID, String(parts[1]))
        }

        private func currentEditingCell() -> (rowID: TableRow.ID, column: String)? {
            guard let tableView, let window = tableView.window,
                  let fieldEditor = window.firstResponder as? NSTextView,
                  let editedField = fieldEditor.delegate as? NSTextField,
                  editedField.isDescendant(of: tableView),
                  let identifier = editedField.identifier?.rawValue
            else { return nil }
            return Self.parseCellIdentifier(identifier)
        }

        /// `reloadData()` tears down every cell view — including the one
        /// the user is typing in. That's exactly what killed Tab-to-next-
        /// cell: moving focus commits the previous cell, the commit
        /// publishes, SwiftUI calls `updateNSView`, and the reload
        /// destroyed the just-focused field, ending the edit. While any
        /// cell of this table is being edited the reload is skipped; the
        /// next update after editing ends (the commit itself publishes one)
        /// reloads as usual.
        func reloadPreservingActiveEdit() {
            guard currentEditingCell() == nil else { return }
            let wasRefetched = viewModel.dataVersion != lastDataVersion
            lastDataVersion = viewModel.dataVersion
            // The table's own selection has to be read *before* the reload:
            // `reloadData()` drops it (`selectedRow` becomes -1). After a
            // refetch it's meaningless anyway — those indexes belong to the
            // rows that were just replaced — so it's only adopted here for
            // an in-place redraw, where it may well be newer than what's
            // tracked (see `adoptSelection`).
            if !wasRefetched {
                adoptSelection()
            }
            tableView?.reloadData()
            restoreSelection()
        }

        /// Puts the highlight back on the selected row after a reload — by
        /// ID, or, when the rows were refetched and carry new IDs, by
        /// primary key. Only when the record itself is gone from the page
        /// (deleted, filtered out, moved to another page) is the selection
        /// dropped.
        private func restoreSelection() {
            guard selectedRowID != nil || selectedRowKey != nil else { return }
            let index = viewModel.rows.firstIndex { $0.id == selectedRowID }
                ?? selectedRowKey.flatMap { key in viewModel.rows.firstIndex { primaryKeyValues(of: $0) == key } }
            select(row: index)
        }

        /// The single funnel for every selection change this class makes
        /// itself, so what AppKit shows and what's tracked here can't
        /// diverge: `selectRowIndexes(_:byExtendingSelection:)` doesn't
        /// report back through `tableViewSelectionDidChange` the way a
        /// user's own click does. Leaving the tracked ID behind was what
        /// made the highlight snap back to the previously edited row — the
        /// click moved the selection, the edit's commit reloaded the grid,
        /// and `restoreSelection()` faithfully restored the *stale* row.
        private func select(row index: Int?) {
            guard let tableView else { return }
            let previousRowID = selectedRowID
            let row = index.flatMap { viewModel.rows.indices.contains($0) ? viewModel.rows[$0] : nil }
            selectedRowID = row?.id
            selectedRowKey = row.flatMap(primaryKeyValues(of:))

            if let index, row != nil {
                if tableView.selectedRow != index {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                }
            } else {
                tableView.deselectAll(nil)
            }
            commitDraftRowIfLeft(previousRowID: previousRowID)
        }

        /// Moving off the not-yet-inserted row is one of the three ways of
        /// leaving it (Enter and Tab are handled where those keys are).
        /// Deliberately keyed on the *previous* selection rather than "a
        /// draft exists and isn't selected": the draft is appended before
        /// the grid's own reload+reselect has caught up, and committing on
        /// that intermediate state would throw the empty row away the
        /// moment it appeared.
        private func commitDraftRowIfLeft(previousRowID: TableRow.ID?) {
            guard let draftRowID = viewModel.draftRowID,
                  previousRowID == draftRowID, selectedRowID != draftRowID else { return }
            // The insert refetches the page, and the grid postpones a reload
            // while a cell is being edited — so an edit the very same click
            // just started is ended first, leaving the grid free to show the
            // refreshed rows.
            tableView?.window?.makeFirstResponder(tableView)
            // No re-focusing here: the user picked another row with this
            // very click, and yanking the highlight onto the row that was
            // just inserted would undo their choice. Enter and Tab, which
            // *stay* on the new row, do ask for it.
            Task { await viewModel.commitDraftRow(focusingInsertedRow: false) }
        }

        /// A row's identity as far as the *database* is concerned, so a
        /// selection can be re-found after a refetch. `nil` for the draft
        /// row (not in the database yet) and for a table without a primary
        /// key (nothing stable to match on).
        private func primaryKeyValues(of row: TableRow) -> [String: String]? {
            guard !row.isDraft else { return nil }
            let keyColumns = viewModel.columns.filter(\.isPrimaryKey).map(\.name)
            guard !keyColumns.isEmpty else { return nil }
            var values: [String: String] = [:]
            for name in keyColumns {
                guard let value = row.originalValues[name]?.displayString else { return nil }
                values[name] = value
            }
            return values
        }

        /// The user's own clicks and keyboard selection — the one path that
        /// does come through AppKit.
        /// Posted while the table is still tracking the click. This — not
        /// `tableViewSelectionDidChange` — is what a click on another row
        /// reliably produces: with an edit ending in the same gesture, the
        /// "did change" often never arrives at all.
        func tableViewSelectionIsChanging(_ notification: Notification) {
            adoptSelection()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            adoptSelection()
        }

        /// Copies the table's own selection into the tracked row and, if
        /// that moved off the draft row, commits the draft.
        ///
        /// An empty selection is ignored on purpose: AppKit reports
        /// `selectedRow == -1` transiently mid-click, and `reloadData()`
        /// leaves the table in exactly that state — treating either as "the
        /// user deselected" would throw away the row being tracked, which
        /// is what puts the highlight back after the reload.
        private func adoptSelection() {
            guard let tableView, viewModel.rows.indices.contains(tableView.selectedRow) else { return }
            let row = viewModel.rows[tableView.selectedRow]
            guard row.id != selectedRowID else { return }
            let previousRowID = selectedRowID
            selectedRowID = row.id
            selectedRowKey = primaryKeyValues(of: row)
            commitDraftRowIfLeft(previousRowID: previousRowID)
        }

        /// Selects and scrolls to the row "Satır Ekle" just created, so the
        /// user lands on it — highlighted, with the grid focused so the
        /// arrow keys keep working from there — instead of hunting for it.
        ///
        /// Both the selection and the flag reset are deferred by one runloop
        /// turn: this runs inside SwiftUI's own view update, where the
        /// `reloadData()` just above hasn't been applied yet (selecting the
        /// brand-new last row is still out of range for AppKit's cached row
        /// count) and writing back into the view model is illegal. On the
        /// next turn the table knows about the new row, and clearing the
        /// flag schedules one more update that finds nothing to do.
        func focusPendingRowIfNeeded() {
            guard let tableView, let rowID = viewModel.rowIDToFocus else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                viewModel.rowIDToFocus = nil
                guard let index = viewModel.rows.firstIndex(where: { $0.id == rowID }),
                      index < tableView.numberOfRows else { return }
                select(row: index)
                tableView.scrollRowToVisible(index)
                tableView.window?.makeFirstResponder(tableView)
            }
        }

        func rebuildColumnsIfNeeded() {
            let signature = viewModel.columns.map(\.name)
            guard signature != lastColumnSignature else { return }
            lastColumnSignature = signature
            rebuildColumns()
        }

        func rebuildColumns() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }

            let deleteColumn = NSTableColumn(identifier: Self.deleteColumnID)
            deleteColumn.headerCell = ColoredHeaderCell()
            deleteColumn.width = 28
            deleteColumn.minWidth = 28
            deleteColumn.maxWidth = 28
            deleteColumn.resizingMask = []
            tableView.addTableColumn(deleteColumn)

            for column in viewModel.columns {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.name))
                let headerCell = ColoredHeaderCell()
                headerCell.attributedStringValue = headerTitle(for: column)
                tableColumn.headerCell = headerCell
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.name, ascending: true)
                tableColumn.width = 140
                tableColumn.minWidth = 60
                tableView.addTableColumn(tableColumn)
            }
        }

        /// Re-applies each data column's header title/sort-arrow without
        /// touching the column structure itself — cheap enough to run on
        /// every `updateNSView`, unlike `rebuildColumns()`.
        func refreshHeaderTitles() {
            guard let tableView else { return }
            for tableColumn in tableView.tableColumns where tableColumn.identifier != Self.deleteColumnID {
                guard let headerCell = tableColumn.headerCell as? ColoredHeaderCell,
                      let column = viewModel.columns.first(where: { $0.name == tableColumn.identifier.rawValue }) else { continue }
                headerCell.attributedStringValue = headerTitle(for: column)
            }
        }

        private func headerTitle(for column: ColumnInfo) -> NSAttributedString {
            var title = column.isPrimaryKey ? "🔑 \(column.name)" : column.name
            if viewModel.sortColumn == column.name {
                title += viewModel.sortAscending ? " ▲" : " ▼"
            }
            return ColoredHeaderCell.title(title)
        }

        /// Fires when a header is clicked — AppKit itself flips the
        /// descriptor's `ascending` for a re-click on the same column, and
        /// resets to ascending for a newly-clicked different column, so we
        /// just read off whatever it decided and hand it to the view model.
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            Task { await viewModel.applySort(column: key, ascending: descriptor.ascending) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            viewModel.rows.count
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            SelectedColorRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < viewModel.rows.count, let tableColumn else { return nil }
            let dataRow = viewModel.rows[row]

            if tableColumn.identifier == Self.deleteColumnID {
                let cell: GridButtonCellView
                if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? GridButtonCellView {
                    cell = reused
                } else {
                    cell = GridButtonCellView()
                    cell.identifier = tableColumn.identifier
                    cell.button.target = self
                    cell.button.action = #selector(deleteTapped(_:))
                }
                cell.button.tag = row
                cell.button.isEnabled = viewModel.hasPrimaryKey
                return cell
            }

            let columnName = tableColumn.identifier.rawValue
            let cell: GridTextCellView
            if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? GridTextCellView {
                cell = reused
            } else {
                cell = GridTextCellView()
                cell.identifier = tableColumn.identifier
                cell.textField.delegate = self
            }
            cell.textField.stringValue = dataRow.editedText[columnName] ?? ""
            // On the pending row an empty cell isn't "empty text", it's a
            // column that will be left out of the INSERT — so it says, in
            // placeholder gray, what the server will actually put there.
            // Placeholder text is never part of `stringValue`, so it can't
            // leak into the inserted values.
            cell.textField.placeholderString = dataRow.isDraft ? draftPlaceholder(forColumn: columnName) : nil
            cell.textField.isEditable = viewModel.hasPrimaryKey
            cell.textField.font = .systemFont(ofSize: CGFloat(SettingsStore.shared.settings.grid.cellFontSize))
            applyGridTextColor(to: cell.textField, isSelected: tableView.selectedRowIndexes.contains(row))
            cell.textField.identifier = Self.cellIdentifier(rowID: dataRow.id, column: columnName)
            return cell
        }

        /// What an untouched cell of the draft row will end up holding:
        /// the auto-increment counter, the column's DEFAULT, NULL, or —
        /// for a required column with neither — a note that it has to be
        /// filled in, since that's the one case where leaving it blank
        /// makes the INSERT fail.
        private func draftPlaceholder(forColumn columnName: String) -> String {
            guard let column = viewModel.columns.first(where: { $0.name == columnName }) else { return "" }
            if column.isAutoIncrement { return "AUTO_INCREMENT" }
            if let defaultValue = column.defaultValue { return defaultValue.isEmpty ? "''" : defaultValue }
            return column.isNullable ? "NULL" : String(localized: "(required)")
        }

        @objc private func deleteTapped(_ sender: NSButton) {
            let row = sender.tag
            guard row < viewModel.rows.count else { return }
            let dataRow = viewModel.rows[row]
            // Nothing was written for a draft row yet, so there's nothing to
            // confirm losing — it just disappears.
            guard !dataRow.isDraft else {
                Task { await viewModel.deleteRow(dataRow) }
                return
            }
            confirmRowDeletion(in: tableView?.window) { [weak self] in
                Task { await self?.viewModel.deleteRow(dataRow) }
            }
        }

        /// Clicking straight into a cell of another row starts editing it
        /// without moving the selection: the click is consumed by the text
        /// field, and AppKit's own "select the row first" handling only
        /// covers controls inside an `NSTableCellView`, which these
        /// deliberately aren't (see `GridTextCellView`). So the highlight is
        /// moved here instead, onto whichever row is actually being edited.
        /// Deferred by a turn so the field editor is fully installed first.
        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                  let identifier = textField.identifier?.rawValue,
                  let (rowID, _) = Self.parseCellIdentifier(identifier) else { return }
            Task { @MainActor [weak self] in
                guard let self, let tableView,
                      let row = viewModel.rows.firstIndex(where: { $0.id == rowID }),
                      row < tableView.numberOfRows, tableView.selectedRow != row
                else { return }
                select(row: row)
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                  let identifier = textField.identifier?.rawValue,
                  let (rowId, columnName) = Self.parseCellIdentifier(identifier),
                  viewModel.rows.contains(where: { $0.id == rowId }) else { return }
            let newValue = textField.stringValue
            // Enter on the draft row is "I'm done with this row" — the same
            // gesture that commits an edit to an existing one. Both run in
            // one task so the cell's own value is stored before the INSERT
            // that reads it.
            let movement = obj.userInfo?["NSTextMovement"] as? Int
            let leavesRow = movement == NSTextMovement.return.rawValue && rowId == viewModel.draftRowID
            Task {
                await viewModel.commitEdit(rowId: rowId, column: columnName, newText: newValue)
                if leavesRow {
                    await viewModel.commitDraftRow()
                }
            }
        }

        private func moveEdit(fromRow row: Int, column columnName: String, direction: Int) {
            guard let tableView, viewModel.hasPrimaryKey else { return }
            let dataColumnNames = viewModel.columns.map(\.name)
            guard let currentIndex = dataColumnNames.firstIndex(of: columnName) else { return }

            var targetRow = row
            var targetIndex = currentIndex + direction
            if targetIndex >= dataColumnNames.count {
                targetIndex = 0
                targetRow += 1
            } else if targetIndex < 0 {
                targetIndex = dataColumnNames.count - 1
                targetRow -= 1
            }
            guard targetRow >= 0, targetRow < viewModel.rows.count else { return }

            // Tabbing past the draft row's last column leaves the row, so it
            // commits here as Enter and clicking away do. Focus is handed to
            // the table first, which ends the current cell's edit (and stores
            // its text) before the INSERT reads it; the reload afterwards
            // re-focuses the row that was written, so there's no cell left
            // here to move into.
            if targetRow != row, viewModel.rows[row].isDraft {
                tableView.window?.makeFirstResponder(tableView)
                Task { await viewModel.commitDraftRow() }
                return
            }

            let targetColumnName = dataColumnNames[targetIndex]
            guard let tableColumnIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == targetColumnName }) else { return }

            tableView.scrollRowToVisible(targetRow)
            guard
                let cellView = tableView.view(atColumn: tableColumnIndex, row: targetRow, makeIfNecessary: true),
                let targetField = cellView.subviews.first(where: { $0 is NSTextField }) as? NSTextField
            else { return }

            tableView.window?.makeFirstResponder(targetField)
            targetField.currentEditor()?.selectAll(nil)
        }
    }
}
