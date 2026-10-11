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
    @State private var copiedStatusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar

            Divider()

            SQLTextView(
                undoProxy: undoProxy,
                text: $console.queryText,
                pendingInsertion: $console.pendingQueryInsertion,
                pendingAppend: $console.pendingQueryAppend,
                selectedText: $console.querySelectedText,
                selectionStart: $console.querySelectionStart
            )
            .frame(minHeight: 70, maxHeight: .infinity)

            statusRow
        }
    }

    private static let maxStatusLines = 5

    /// A full-width row right under the editor, not a small trailing
    /// caption in the toolbar — a successful run (especially a write with
    /// no visible grid change) needs a result the user can't miss.
    ///
    /// Always renders (never an empty/absent view): with nothing to say it
    /// holds a blank line at `.opacity(0)`, so the editor doesn't jump by a
    /// row's height every time a query starts and finishes. A long message
    /// does grow the row — up to `maxStatusLines`, taken out of the editor
    /// above, since the panel's own height is fixed by the split — and
    /// scrolls inside it past that.
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

        let hasMessage = color != .clear
        let fontSize = CGFloat(settingsStore.settings.editor.statusFontSize)
        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let verticalPadding: CGFloat = 5
        let copyMessage = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
        }

        // Server errors are long and quote the offending SQL with its own
        // line breaks. On a single line the message stopped at the first
        // of those breaks — without even an ellipsis, so it read as
        // complete while the "at line N" part was missing. Shown whole
        // instead, wrapped.
        let label = Label(message, systemImage: icon)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .help(message)
            // A server error worth reading is usually one worth pasting
            // somewhere: selectable for a part of it, and the context menu
            // (like the button beside it) copies the whole message.
            .textSelection(.enabled)
            .contextMenu {
                if hasMessage {
                    Button("Copy", action: copyMessage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, verticalPadding)

        return HStack(alignment: .top, spacing: 8) {
            // As tall as the message needs, until that's more than the
            // cap (or than the panel can spare) — from there on the same
            // text scrolls in place rather than being cut off.
            HuggingHeightLayout(
                minHeight: lineHeight + verticalPadding * 2,
                maxHeight: lineHeight * CGFloat(Self.maxStatusLines) + verticalPadding * 2
            ) {
                ViewThatFits(in: .vertical) {
                    label
                    ScrollView(.vertical) { label }
                }
            }

            // The selection and the context menu both have to be
            // discovered; this is the same whole-message copy as a visible
            // one-click target. Outside the scrolling area, so it stays on
            // the first line however far the message is scrolled.
            Button {
                copyMessage()
                copiedStatusMessage = message
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedStatusMessage == message {
                        copiedStatusMessage = nil
                    }
                }
            } label: {
                // Compared against the message rather than a plain flag so
                // the checkmark never carries over to the next query's
                // message. The frame is one text line by a fixed slot: the
                // two symbols differ in width, and both are taller than the
                // line — left to size itself, the button grew this row by
                // 1–3pt, height the panel's fixed budget takes straight out
                // of the editor.
                Label("Copy", systemImage: copiedStatusMessage == message ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: fontSize + 4, height: lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy")
            .disabled(!hasMessage)
            .padding(.top, verticalPadding)
        }
        .font(.system(size: fontSize))
        .padding(.horizontal, 8)
        .opacity(hasMessage ? 1 : 0)
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
                // Nothing for this to control before a query has actually
                // run — `isQueryResultEditable` also requires a live
                // `queryEditContext`, which only exists once results are on
                // screen. Left enabled, toggling it here looked like it did
                // nothing (because it didn't), which read as broken rather
                // than as "not applicable yet".
                .disabled(!console.isShowingQueryResult)
            }
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Sizes its one child to the height its content wants, within
/// `minHeight...maxHeight` and never more than the parent offers.
/// `.frame(maxHeight:)` can't do this: it caps the height but otherwise
/// takes whatever is offered, so a one-line message got a five-line row.
/// `.fixedSize()` hugs the content but ignores the offer, pushing the
/// editor above below its own minimum in a short panel.
private struct HuggingHeightLayout: Layout {
    let minHeight: CGFloat
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        var height = min(ideal.height, maxHeight)
        if let offered = proposal.height {
            height = min(height, max(offered, minHeight))
        }
        return CGSize(width: ideal.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
