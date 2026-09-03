import SwiftUI
import AppKit

/// Results grid for the SQL query panel. Read-only by default; becomes
/// editable (delete column, editable cells) when `isEditable` is true —
/// driven by the "Editable" toggle *and* `TableDataViewModel` having
/// recognized the query as a simple single-table SELECT with its primary
/// key in the result (see `QueryEditContext`). Shares header/selection
/// styling with the main grid via `GridStyling.swift`.
struct QueryResultGridView: NSViewRepresentable {
    let columnNames: [String]
    let rows: [TableRow]
    let primaryKeyColumns: Set<String>
    let isEditable: Bool
    let onCommitEdit: (TableRow.ID, String, String) -> Void
    let onDeleteRow: (TableRow) -> Void
    /// Opens the value editor for a `TEXT`/`BLOB` cell.
    let onOpenLargeValue: (TableRow.ID, String) -> Void

    /// Which columns hold `TEXT`/`BLOB` values. A query result carries no
    /// schema, so this is read off the values themselves — and taken
    /// column-wide as soon as *any* row has one, so that a `NULL` in the
    /// same column behaves like its neighbours rather than being the one
    /// inline-editable cell in the column.
    private var largeObjectColumns: Set<String> {
        var result: Set<String> = []
        for row in rows {
            for (name, value) in row.originalValues where value.isLargeObject {
                result.insert(name)
            }
        }
        return result
    }
    /// See `SpreadsheetGridView` — settings changes re-invoke `updateNSView`.
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

        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.tableViewClicked(_:))

        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns(columnNames: columnNames, isEditable: isEditable)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.rows = rows
        context.coordinator.primaryKeyColumns = primaryKeyColumns
        context.coordinator.isEditable = isEditable
        context.coordinator.onCommitEdit = onCommitEdit
        context.coordinator.onDeleteRow = onDeleteRow
        context.coordinator.onOpenLargeValue = onOpenLargeValue
        context.coordinator.largeObjectColumns = largeObjectColumns
        if let tableView = context.coordinator.tableView {
            tableView.rowHeight = CGFloat(settingsStore.settings.grid.rowHeight)
            tableView.headerView?.needsDisplay = true
        }
        context.coordinator.rebuildColumnsIfNeeded(columnNames: columnNames, isEditable: isEditable)
        context.coordinator.reloadPreservingActiveEdit()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: rows, primaryKeyColumns: primaryKeyColumns, isEditable: isEditable, onCommitEdit: onCommitEdit, onDeleteRow: onDeleteRow)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var rows: [TableRow]
        var primaryKeyColumns: Set<String>
        var isEditable: Bool
        var onCommitEdit: (TableRow.ID, String, String) -> Void
        var onDeleteRow: (TableRow) -> Void
        var onOpenLargeValue: (TableRow.ID, String) -> Void = { _, _ in }
        var largeObjectColumns: Set<String> = []
        weak var tableView: NSTableView?

        private var lastColumnNames: [String] = []
        private var lastIsEditable = false
        // See `SpreadsheetGridView.Coordinator` for why this needs
        // `nonisolated(unsafe)` — `deinit` runs nonisolated even here.
        nonisolated(unsafe) private var keyMonitor: Any?
        private static let deleteColumnID = NSUserInterfaceItemIdentifier("__delete__")

        init(
            rows: [TableRow],
            primaryKeyColumns: Set<String>,
            isEditable: Bool,
            onCommitEdit: @escaping (TableRow.ID, String, String) -> Void,
            onDeleteRow: @escaping (TableRow) -> Void
        ) {
            self.rows = rows
            self.primaryKeyColumns = primaryKeyColumns
            self.isEditable = isEditable
            self.onCommitEdit = onCommitEdit
            self.onDeleteRow = onDeleteRow
            super.init()
            // See the identical setup in `SpreadsheetGridView.Coordinator`:
            // a local event monitor is what actually wins the race against
            // SwiftUI's own Tab-focus handling for a table embedded via
            // `NSViewRepresentable`.
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

        /// See `SpreadsheetGridView.Coordinator.reloadPreservingActiveEdit`
        /// — same reload-kills-the-active-editor problem, same fix.
        func reloadPreservingActiveEdit() {
            guard currentEditingCell() == nil else { return }
            tableView?.reloadData()
        }

        func rebuildColumnsIfNeeded(columnNames: [String], isEditable: Bool) {
            guard columnNames != lastColumnNames || isEditable != lastIsEditable else { return }
            rebuildColumns(columnNames: columnNames, isEditable: isEditable)
        }

        func rebuildColumns(columnNames: [String], isEditable: Bool) {
            guard let tableView else { return }
            lastColumnNames = columnNames
            lastIsEditable = isEditable
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }

            if isEditable {
                let deleteColumn = NSTableColumn(identifier: Self.deleteColumnID)
                deleteColumn.headerCell = ColoredHeaderCell()
                deleteColumn.width = 28
                deleteColumn.minWidth = 28
                deleteColumn.maxWidth = 28
                deleteColumn.resizingMask = []
                tableView.addTableColumn(deleteColumn)
            }

            // Same one-shot autofit as `SpreadsheetGridView` — sized here,
            // not gated behind a loading flag, because `rows` (set just
            // before this is called, in `updateNSView`/`makeCoordinator`)
            // is always this result set's actual data by the time a new
            // query's columns show up; there's no async load in between to
            // wait out.
            let font = NSFont.systemFont(ofSize: CGFloat(SettingsStore.shared.settings.grid.cellFontSize))
            let minWidth: CGFloat = 60
            let maxWidth: CGFloat = 400
            let horizontalPadding: CGFloat = 24

            for name in columnNames {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
                let headerCell = ColoredHeaderCell()
                let title = primaryKeyColumns.contains(name) ? "🔑 \(name)" : name
                headerCell.attributedStringValue = ColoredHeaderCell.title(title)
                column.headerCell = headerCell
                var widest = headerCell.attributedStringValue.size().width
                for row in rows {
                    let text = row.editedText[name] ?? ""
                    widest = max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
                }
                column.width = min(max(widest + horizontalPadding, minWidth), maxWidth)
                column.minWidth = minWidth
                tableView.addTableColumn(column)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            SelectedColorRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count, let tableColumn else { return nil }

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
                return cell
            }

            let columnName = tableColumn.identifier.rawValue
            let dataRow = rows[row]
            // Same treatment as the table grid: a `TEXT`/`BLOB` column shows
            // its `<N bytes>` placeholder and opens the value editor rather
            // than editing in place. Reuse pools are per column, so the
            // click recognizer can only ever land on this kind of column.
            let isLargeObject = largeObjectColumns.contains(columnName)
            let cell: GridTextCellView
            if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? GridTextCellView {
                cell = reused
            } else {
                cell = GridTextCellView()
                cell.identifier = tableColumn.identifier
            }
            cell.textField.stringValue = dataRow.editedText[columnName] ?? ""
            cell.textField.isEditable = isEditable && !isLargeObject
            cell.textField.font = .systemFont(ofSize: CGFloat(SettingsStore.shared.settings.grid.cellFontSize))
            applyGridTextColor(to: cell.textField, isSelected: tableView.selectedRowIndexes.contains(row))
            cell.textField.delegate = (isEditable && !isLargeObject) ? self : nil
            cell.textField.identifier = NSUserInterfaceItemIdentifier("\(row)|\(columnName)")
            return cell
        }

        /// Opens the value editor when a `TEXT`/`BLOB` placeholder is
        /// clicked — see `SpreadsheetGridView.Coordinator.tableViewClicked`
        /// for why this hangs off the table view's `action` instead of a
        /// gesture recognizer on the cell.
        @objc func tableViewClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            let columnIndex = sender.clickedColumn
            guard row >= 0, row < rows.count,
                  columnIndex >= 0, columnIndex < sender.tableColumns.count else { return }
            let identifier = sender.tableColumns[columnIndex].identifier
            guard identifier != Self.deleteColumnID,
                  largeObjectColumns.contains(identifier.rawValue) else { return }
            onOpenLargeValue(rows[row].id, identifier.rawValue)
        }

        @objc private func deleteTapped(_ sender: NSButton) {
            let row = sender.tag
            guard row < rows.count else { return }
            let dataRow = rows[row]
            confirmRowDeletion(in: tableView?.window) { [weak self] in
                self?.onDeleteRow(dataRow)
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                  let identifier = textField.identifier?.rawValue else { return }
            let parts = identifier.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let row = Int(parts[0]), row < rows.count else { return }
            let columnName = String(parts[1])
            onCommitEdit(rows[row].id, columnName, textField.stringValue)
        }

        private func moveEdit(fromRow row: Int, column columnName: String, direction: Int) {
            guard let tableView, isEditable else { return }
            guard let currentIndex = lastColumnNames.firstIndex(of: columnName) else { return }

            var targetRow = row
            var targetIndex = currentIndex + direction
            if targetIndex >= lastColumnNames.count {
                targetIndex = 0
                targetRow += 1
            } else if targetIndex < 0 {
                targetIndex = lastColumnNames.count - 1
                targetRow -= 1
            }
            guard targetRow >= 0, targetRow < rows.count else { return }

            let targetColumnName = lastColumnNames[targetIndex]
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
