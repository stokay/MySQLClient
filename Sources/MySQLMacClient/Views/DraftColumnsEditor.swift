import SwiftUI

/// The column grid shared by the Create Table and Alter Table forms:
/// header row, editable rows, add/remove, and (for Create) row reordering.
/// Operates directly on the bound `DraftColumn` array; the owning view
/// model only sees the resulting values. Styled by `SchemaModalTheme`.
struct DraftColumnsEditor: View {
    @Binding var columns: [DraftColumn]
    let dataTypes: [String]

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedColumnID: UUID?

    private var theme: SchemaModalTheme { SchemaModalTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("COLUMNS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        moveSelected(-1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(!canMoveSelected(-1))

                    Button {
                        moveSelected(1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(!canMoveSelected(1))
                }
                .buttonStyle(SchemaIconButtonStyle(theme: theme))

                Button {
                    columns.append(DraftColumn())
                } label: {
                    Label("Add Column", systemImage: "plus")
                }
                .buttonStyle(SchemaPrimaryButtonStyle(theme: theme))
            }

            VStack(alignment: .leading, spacing: 4) {
                headerRow

                ScrollView {
                    VStack(spacing: 3) {
                        ForEach($columns) { $column in
                            DraftColumnRow(
                                column: $column,
                                dataTypes: dataTypes,
                                theme: theme,
                                isSelected: column.id == selectedColumnID,
                                onSelect: { selectedColumnID = column.id },
                                onDelete: { columns.removeAll { $0.id == column.id } }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 180, maxHeight: 280)
            }
            .padding(10)
            .schemaCard(theme: theme)
        }
    }

    private func canMoveSelected(_ direction: Int) -> Bool {
        guard let id = selectedColumnID, let index = columns.firstIndex(where: { $0.id == id }) else { return false }
        return columns.indices.contains(index + direction)
    }

    private func moveSelected(_ direction: Int) {
        guard let id = selectedColumnID, let index = columns.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + direction
        guard columns.indices.contains(newIndex) else { return }
        columns.swapAt(index, newIndex)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 16)
            Text("COLUMN NAME").frame(width: 150, alignment: .leading)
            Text("TYPE").frame(width: 110, alignment: .leading)
            Text("LENGTH").frame(width: 64, alignment: .leading)
            Text("DEFAULT").frame(width: 90, alignment: .leading)
            Text("PK").frame(width: 24, alignment: .center)
            Text("NOT\nNULL").multilineTextAlignment(.center).frame(width: 58, alignment: .center)
            Text("UNSIGNED").frame(width: 58, alignment: .center)
            Text("AUTO\nINC").frame(width: 58, alignment: .center)
            Text("COMMENT").frame(minWidth: 100, alignment: .leading)
            Spacer(minLength: 20)
        }
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 6)
    }
}

private struct DraftColumnRow: View {
    @Binding var column: DraftColumn
    let dataTypes: [String]
    let theme: SchemaModalTheme
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 16)
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }

            TextField("", text: $column.name)
                .schemaFieldBorder(theme: theme, padding: 4, cornerRadius: 5)
                .frame(width: 150)
            Picker("", selection: $column.dataType) {
                ForEach(dataTypes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            TextField("", text: $column.length)
                .schemaFieldBorder(theme: theme, padding: 4, cornerRadius: 5)
                .frame(width: 64)
            TextField("", text: $column.defaultValue)
                .schemaFieldBorder(theme: theme, padding: 4, cornerRadius: 5)
                .frame(width: 90)
            Toggle("", isOn: $column.isPrimaryKey)
                .labelsHidden()
                .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
                .frame(width: 24)
            Toggle("", isOn: $column.isNotNull)
                .labelsHidden()
                .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
                .frame(width: 58)
                .disabled(column.isPrimaryKey)
            Toggle("", isOn: $column.isUnsigned)
                .labelsHidden()
                .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
                .frame(width: 58)
            Toggle("", isOn: $column.isAutoIncrement)
                .labelsHidden()
                .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
                .frame(width: 58)
            TextField("", text: $column.comment)
                .schemaFieldBorder(theme: theme, padding: 4, cornerRadius: 5)
                .frame(minWidth: 100)

            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(SchemaIconButtonStyle(theme: theme))
            .frame(width: 20)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? theme.accent.opacity(0.15) : Color.clear)
        )
    }
}
