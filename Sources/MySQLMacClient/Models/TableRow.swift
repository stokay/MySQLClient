import Foundation

/// One fetched row. `originalValues` is the snapshot from the moment of the
/// fetch (used to build PK-based WHERE clauses so edits never go stale), and
/// `editedText` is the live, per-cell text shown/edited in the grid.
struct TableRow: Identifiable {
    let id = UUID()
    /// A row "Satır Ekle" appended to the grid that hasn't been INSERTed
    /// yet. It has no `originalValues` — there's no database row behind it
    /// to build a primary-key WHERE clause from — so every write path has
    /// to treat it separately until the commit turns it into a real row.
    let isDraft: Bool
    private(set) var originalValues: [String: RowValue]
    var editedText: [String: String]

    init(values: [String: RowValue]) {
        self.isDraft = false
        self.originalValues = values
        self.editedText = values.mapValues { $0.displayString }
    }

    /// The empty row shown below the last one before it exists in the
    /// database. Every column starts blank, and `isDirty` therefore reports
    /// exactly the columns the user actually typed something into — which
    /// is what decides the INSERT's column list.
    init(draftColumns: [String]) {
        self.isDraft = true
        self.originalValues = [:]
        self.editedText = Dictionary(uniqueKeysWithValues: draftColumns.map { ($0, "") })
    }

    func isDirty(_ column: String) -> Bool {
        editedText[column] != (originalValues[column]?.displayString ?? "")
    }

    var isRowDirty: Bool {
        originalValues.keys.contains { isDirty($0) }
    }

    /// Call after a successful UPDATE so the edited columns stop being "dirty".
    ///
    /// A `TEXT` column keeps its `.text` case rather than collapsing to
    /// `.string`, and its `editedText` is re-normalised to the resulting
    /// `<N bytes>` placeholder — otherwise the cell would sit there showing
    /// the full multi-line value (and dragging the row's height over its
    /// neighbours) until the next reload.
    mutating func acceptEdits(for columnNames: [String]) {
        for column in columnNames {
            guard let text = editedText[column] else { continue }
            let wasText = originalValues[column]?.isLargeObject ?? false
            let accepted: RowValue
            if text.isEmpty {
                accepted = .null
            } else {
                accepted = wasText ? .text(text) : .string(text)
            }
            originalValues[column] = accepted
            editedText[column] = accepted.displayString
        }
    }
}
