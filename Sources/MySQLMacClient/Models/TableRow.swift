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
    mutating func acceptEdits(for columnNames: [String]) {
        for column in columnNames {
            guard let text = editedText[column] else { continue }
            originalValues[column] = text.isEmpty ? .null : .string(text)
        }
    }
}
