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
            guard event.keyCode == 48 /* Tab */, let (row, columnName) = currentEditingCell() else { return false }
            moveEdit(fromRow: row, column: columnName, direction: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        }

        private func currentEditingCell() -> (row: Int, column: String)? {
            guard let tableView, let window = tableView.window,
                  let fieldEditor = window.firstResponder as? NSTextView,
                  let editedField = fieldEditor.delegate as? NSTextField,
                  editedField.isDescendant(of: tableView),
                  let identifier = editedField.identifier?.rawValue
            else { return nil }
            let parts = identifier.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let row = Int(parts[0]) else { return nil }
            return (row, String(parts[1]))
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
            tableView?.reloadData()
        }

        /// Selects and scrolls to the row "Satır Ekle" just created, so the
        /// user lands on it ready to type instead of hunting for it. The
        /// flag is cleared as it's consumed — writing back into the view
        /// model from `updateNSView` schedules one more update, which then
        /// finds nothing to do and settles.
        func focusPendingRowIfNeeded() {
            guard let tableView, let rowID = viewModel.rowIDToFocus else { return }
            viewModel.rowIDToFocus = nil
            guard let index = viewModel.rows.firstIndex(where: { $0.id == rowID }) else { return }
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
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
            cell.textField.isEditable = viewModel.hasPrimaryKey
            cell.textField.font = .systemFont(ofSize: CGFloat(SettingsStore.shared.settings.grid.cellFontSize))
            applyGridTextColor(to: cell.textField, isSelected: tableView.selectedRowIndexes.contains(row))
            cell.textField.identifier = NSUserInterfaceItemIdentifier("\(row)|\(columnName)")
            return cell
        }

        @objc private func deleteTapped(_ sender: NSButton) {
            let row = sender.tag
            guard row < viewModel.rows.count else { return }
            let dataRow = viewModel.rows[row]
            confirmRowDeletion(in: tableView?.window) { [weak self] in
                Task { await self?.viewModel.deleteRow(dataRow) }
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                  let identifier = textField.identifier?.rawValue else { return }
            let parts = identifier.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let row = Int(parts[0]), row < viewModel.rows.count else { return }
            let columnName = String(parts[1])
            let rowId = viewModel.rows[row].id
            let newValue = textField.stringValue
            Task { await viewModel.commitEdit(rowId: rowId, column: columnName, newText: newValue) }
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
