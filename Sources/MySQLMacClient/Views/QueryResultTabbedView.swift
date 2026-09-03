import SwiftUI

/// The query console's result area: a tab bar (only when the last query
/// returned more than one result set — i.e. a `CALL` to a procedure whose
/// body runs several `SELECT`s) above the shared `QueryResultGridView`.
///
/// Owns the wiring that both result-showing places need (`TableDataGridView`
/// with a table selected, `MainWindowView`'s placeholder without one), so
/// that binding lives in one file instead of being duplicated in each.
struct QueryResultTabbedView: View {
    @ObservedObject var console: SQLConsoleViewModel

    var body: some View {
        VStack(spacing: 0) {
            if console.queryResultSets.count > 1 {
                tabBar
                Divider()
            }

            QueryResultGridView(
                columnNames: console.queryResultColumns,
                rows: console.queryResultRows,
                primaryKeyColumns: Set(console.queryEditContext?.primaryKeyColumns ?? []),
                isEditable: console.isQueryResultEditable,
                onCommitEdit: { rowId, column, newText in
                    Task { await console.commitQueryResultEdit(rowId: rowId, column: column, newText: newText) }
                },
                onDeleteRow: { row in
                    Task { await console.deleteQueryResultRow(row) }
                },
                onOpenLargeValue: { rowID, column in
                    console.beginEditingLargeValue(rowID: rowID, column: column)
                }
            )
            // Switching tabs is a different result set, not an update to the
            // current one: rebuilding the `NSTableView` outright avoids
            // carrying over selection/scroll state, and is the only way two
            // result sets that happen to share column names still reset
            // cleanly (the grid's own column diffing sees no change there).
            .id(console.selectedResultSetIndex)
        }
        .sheet(item: $console.largeValueEdit) { edit in
            LargeValueEditorView(edit: edit) { newText in
                Task { await console.commitQueryResultEdit(rowId: edit.rowID, column: edit.column, newText: newText) }
            }
        }
    }

    /// Horizontally scrollable for the same reason as the grid/query
    /// toolbars — see `TableDataGridView.gridToolbar`: a procedure can
    /// return more tabs than fit, and scrolling beats wrapping into a
    /// taller row that eats the grid's height.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(console.queryResultSets.enumerated()), id: \.element.id) { index, resultSet in
                    let isSelected = index == console.selectedResultSetIndex
                    Button {
                        console.selectedResultSetIndex = index
                    } label: {
                        Text("Result \(index + 1) (\(resultSet.rows.count))")
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(isSelected ? Color.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(resultSet.columns.joined(separator: ", "))")
                }
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
