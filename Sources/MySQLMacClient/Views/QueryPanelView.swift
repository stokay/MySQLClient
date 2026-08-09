import SwiftUI

/// The collapsible SQL editor panel — one shared instance per connected
/// window (`SQLConsoleViewModel`), shown above whichever grid is on screen
/// (or above the "Bir tablo seçin" placeholder when nothing is). Running a
/// query shows its results in place of the grid below; "Tablo Görünümüne
/// Dön" switches back.
struct QueryPanelView: View {
    @ObservedObject var console: SQLConsoleViewModel
    @StateObject private var undoProxy = SQLEditorUndoProxy()
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar

            Divider()

            SQLTextView(
                undoProxy: undoProxy,
                text: $console.queryText,
                pendingInsertion: $console.pendingQueryInsertion,
                pendingAppend: $console.pendingQueryAppend,
                selectedText: $console.querySelectedText
            )
            .frame(minHeight: 70, maxHeight: .infinity)

            statusRow
        }
    }

    /// A full-width row right under the editor, not a small trailing
    /// caption in the toolbar — a successful run (especially a write with
    /// no visible grid change) needs a result the user can't miss.
    ///
    /// Always renders (never an empty/absent view) — the version that only
    /// showed a row when there was something to say let the whole panel's
    /// natural height flip between "with status row" and "without" as
    /// queries ran, which `VSplitView` didn't reflow cleanly for, leaving
    /// the pane visibly short with the toolbar/status clipped until the
    /// user manually dragged it. Using `.opacity` instead of removing the
    /// view keeps the reserved height constant either way.
    private var statusRow: some View {
        // Error color and font size come from the Ayarlar window; the
        // dynamic NSColor resolves the light/dark hex per current theme.
        let errorColor = Color(nsColor: .settingsColor({ $0.editor.errorColor }, fallback: .systemRed))
        let (message, icon, color): (String, String, Color) = {
            if let errorMessage = console.queryErrorMessage {
                return (errorMessage, "xmark.octagon.fill", errorColor)
            } else if let note = console.queryResultEditabilityNote {
                return (note, "exclamationmark.triangle.fill", .orange)
            } else if let message = console.queryMessage {
                return (message, "checkmark.circle.fill", .green)
            } else {
                return (" ", "checkmark.circle.fill", .clear)
            }
        }()

        return Label(message, systemImage: icon)
            .font(.system(size: CGFloat(settingsStore.settings.editor.statusFontSize)))
            .foregroundStyle(color)
            // Server error messages are long; without a line limit this row
            // wrapped to two or three lines as the window narrowed, which
            // both looked broken and ate into the panel's fixed height
            // budget (the editor above shrank to pay for it). Truncated to
            // one line, with the full text on hover.
            .lineLimit(1)
            .truncationMode(.tail)
            .help(message)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(color == .clear ? 0 : 1)
    }

    /// See the identical treatment (and the reasoning in its comment) on
    /// `TableDataGridView.gridToolbar` — same dense-row-in-a-narrow-window
    /// problem, same fix: scroll instead of wrap/recenter. `.lineLimit(1)`
    /// on every label is a second, independent guard against the wrap —
    /// it stops a `Text` from growing to a second line no matter what the
    /// surrounding `ScrollView`/`.fixedSize()` do or don't propagate.
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button {
                    Task { await console.runQuery() }
                } label: {
                    if console.isExecutingQuery {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                            .lineLimit(1)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(console.isExecutingQuery || console.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Runs the selected text if there is one, otherwise the whole query (⌘↩)")

                Button {
                    Task { await console.runAllStatements() }
                } label: {
                    if console.isExecutingQuery {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run All", systemImage: "forward.fill")
                            .lineLimit(1)
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(console.isExecutingQuery || console.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Runs each \";\"-separated statement in order without DELIMITER (⇧⌘↩). A CREATE PROCEDURE/FUNCTION/TRIGGER with a BEGIN…END body still needs DELIMITER.")

                // Placed right after the run buttons, not at the end of the
                // row: while a result is showing this is the only way back
                // to the table's own Yenile/Satır Ekle/Sayfa boyutu
                // controls, and this toolbar scrolls horizontally — pushed
                // to the end it can sit off-screen exactly when it's needed.
                if console.isShowingQueryResult {
                    Divider().frame(height: 16)

                    Button {
                        Task { await console.clearQueryResult() }
                    } label: {
                        Label("Back to Table View", systemImage: "tablecells")
                            .lineLimit(1)
                    }
                }

                Divider().frame(height: 16)

                Button {
                    undoProxy.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!undoProxy.canUndo)
                .help("Undo (⌘Z)")

                Button {
                    undoProxy.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!undoProxy.canRedo)
                .help("Redo (⇧⌘Z)")

                Divider().frame(height: 16)

                Toggle(isOn: $console.isQueryResultEditableRequested) {
                    Label(
                        console.isQueryResultEditableRequested ? "Editable" : "Read Only",
                        systemImage: console.isQueryResultEditableRequested ? "pencil" : "lock"
                    )
                    .lineLimit(1)
                }
                .toggleStyle(.button)
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
