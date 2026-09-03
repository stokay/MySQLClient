import SwiftUI

/// What the grid hands to the value editor: which cell is being opened,
/// what it currently holds, and whether it can be written back as text.
struct LargeValueEdit: Identifiable {
    let id = UUID()
    let rowID: TableRow.ID
    let column: String
    let text: String
    /// The cell holds bytes that aren't text at all, so there is nothing to
    /// show and nothing that could be typed back without corrupting them.
    let isBinary: Bool
    /// Whether a change can be written back. Distinct from `isBinary`:
    /// a `TEXT` value in the result of a join or an aggregate is perfectly
    /// readable, there is just no single row to `UPDATE`.
    let isEditable: Bool
    /// Size of the stored value, for the binary case where `text` is empty.
    let byteCount: Int
}

/// Editor for a `TEXT`/`BLOB` cell, which the grid can only show as a
/// `<N bytes>` placeholder: a multi-line value would otherwise drag its
/// row's height over the neighbouring ones.
struct LargeValueEditorView: View {
    let edit: LargeValueEdit
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var draft: String

    init(edit: LargeValueEdit, onSave: @escaping (String) -> Void) {
        self.edit = edit
        self.onSave = onSave
        _draft = State(initialValue: edit.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if edit.isBinary {
                binaryPlaceholder
            } else if edit.isEditable {
                TextEditor(text: $draft)
                    .font(editorFont)
                    .padding(6)
            } else {
                // Selectable rather than a disabled `TextEditor`, so the
                // value can still be read and copied out.
                ScrollView {
                    Text(draft)
                        .font(editorFont)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
            }

            Divider()

            footer
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 480)
    }

    private var editorFont: Font {
        .system(size: CGFloat(settingsStore.settings.editor.fontSize), design: .monospaced)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(edit.column)
                .font(.headline)
            Text(byteLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            if !edit.isBinary && !edit.isEditable {
                Text("Read Only")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Counts the *edited* bytes while typing, so the number matches what
    /// the cell will show once saved.
    private var byteLabel: String {
        edit.isBinary ? "\(edit.byteCount) bytes" : "\(draft.utf8.count) bytes"
    }

    private var binaryPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("This column holds binary data, which can't be edited as text.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(edit.isEditable && !edit.isBinary ? "Cancel" : "Close", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if edit.isEditable && !edit.isBinary {
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == edit.text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
