import SwiftUI

/// The "Export..." sheet, opened from a table's (or view's) context menu in
/// the sidebar. Modeled on HeidiSQL's "Export data" dialog: format tabs,
/// CSV-specific delimiter fields, a column checklist, and a file-path row.
/// Shares `SchemaModalTheme`'s visual language with Create/Alter Table.
///
/// Read-only — nothing here mutates schema or data, so unlike Alter Table's
/// `onAltered` there's no completion closure for the caller to react to.
struct TableExportView: View {
    @StateObject private var viewModel: TableExportViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var theme: SchemaModalTheme { SchemaModalTheme(colorScheme: colorScheme) }

    init(service: MySQLService, table: TableInfo) {
        _viewModel = StateObject(wrappedValue: TableExportViewModel(service: service, table: table))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleRow

            if viewModel.isLoadingColumns {
                ProgressView("Loading columns…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        formatTabs
                        formatOptionsSection
                        fieldsToExportSection
                        saveToFileRow
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            statusFooter
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 620)
        .background(theme.windowBackground)
        .task { await viewModel.loadColumns() }
        .alert("Export Complete", isPresented: $viewModel.didFinishSuccessfully) {
            Button("OK") {}
        } message: {
            Text("\(viewModel.table.name) was exported successfully.")
        }
    }

    private var canExport: Bool {
        !viewModel.isExporting
            && !viewModel.isLoadingColumns
            && viewModel.outputFileURL != nil
            && !viewModel.selectedColumnNames.isEmpty
    }

    private var titleRow: some View {
        (
            Text("Export ")
                .font(.title2.bold())
                .foregroundColor(theme.textPrimary)
            + Text("— ")
                .font(.title2.bold())
                .foregroundColor(theme.textSecondary)
            + Text(viewModel.table.name)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.amber)
        )
    }

    // MARK: - Format tabs

    private var formatTabs: some View {
        HStack(spacing: 6) {
            ForEach(TableExportFormat.allCases) { format in
                formatTabButton(format)
            }
        }
    }

    private func formatTabButton(_ format: TableExportFormat) -> some View {
        let isActive = viewModel.options.format == format
        return Button {
            viewModel.options.format = format
        } label: {
            Text(format.displayName)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .white : theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? theme.accent : theme.fieldBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.fieldBorder, lineWidth: isActive ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Format-specific options

    @ViewBuilder
    private var formatOptionsSection: some View {
        switch viewModel.options.format {
        case .csv:
            csvOptions
        case .sql where viewModel.table.isView:
            formatNote("The view definition (CREATE OR REPLACE VIEW) is exported — a view has no rows of its own, so no data is written separately.")
        case .sql:
            formatNote("Schema (CREATE TABLE IF NOT EXISTS) and data (INSERT INTO) are exported together.")
        case .html, .json, .xlsx:
            EmptyView()
        }
    }

    private func formatNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(theme.textSecondary)
    }

    private var csvOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                labeledField("DELIMITER", text: Binding(
                    get: { viewModel.options.csv.fieldTerminator },
                    set: { viewModel.options.csv.fieldTerminator = $0 }
                ))
                labeledField("ENCLOSURE", text: Binding(
                    get: { viewModel.options.csv.fieldEnclosure },
                    set: { viewModel.options.csv.fieldEnclosure = $0 }
                ))
                labeledField("ESCAPE CHARACTER", text: Binding(
                    get: { viewModel.options.csv.fieldEscape },
                    set: { viewModel.options.csv.fieldEscape = $0 }
                ))
            }
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { viewModel.options.csv.includeHeaderRow },
                    set: { viewModel.options.csv.includeHeaderRow = $0 }
                ))
                .labelsHidden()
                .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
                Text("Column names on first row")
                    .foregroundStyle(theme.textPrimary)
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.options.csv.includeHeaderRow.toggle() }
        }
        .padding(12)
        .schemaCard(theme: theme)
    }

    private func labeledField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(theme.textSecondary)
            TextField("", text: text)
                .schemaFieldBorder(theme: theme, padding: 4, cornerRadius: 5)
                .frame(width: 100)
        }
    }

    // MARK: - Fields to export

    private var fieldsToExportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FIELDS TO EXPORT")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button("Select All") { viewModel.selectAllColumns() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button("Deselect All") { viewModel.deselectAllColumns() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.allColumns) { column in
                    // `SchemaCheckboxToggleStyle` only ever draws the
                    // checkbox square itself — it doesn't render
                    // `configuration.label` at all (see every other use of
                    // it: always an empty-string `Toggle("", ...)` plus a
                    // separately-drawn `Text` next to it, e.g.
                    // `DraftColumnsEditor`). A label passed straight into
                    // the `Toggle` here would silently never appear.
                    HStack(spacing: 8) {
                        Toggle("", isOn: binding(for: column.name))
                            .labelsHidden()
                            .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
                        Text(column.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let isSelected = viewModel.selectedColumnNames.contains(column.name)
                        binding(for: column.name).wrappedValue = !isSelected
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .schemaCard(theme: theme)
        }
    }

    private func binding(for columnName: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedColumnNames.contains(columnName) },
            set: { isOn in
                if isOn {
                    viewModel.selectedColumnNames.insert(columnName)
                } else {
                    viewModel.selectedColumnNames.remove(columnName)
                }
            }
        )
    }

    // MARK: - Save to file

    private var saveToFileRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SAVE TO FILE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: 8) {
                Text(viewModel.outputFileURL?.path ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .schemaFieldBorder(theme: theme)
                Button("…") { viewModel.chooseOutputFile() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
            }
        }
    }

    // MARK: - Status footer

    /// Mirrors `DatabaseBackupView.statusFooter` — same progress-bar shape,
    /// same "Kapat cancels a running operation before dismissing, Aktar/
    /// Dışa Aktar starts one" wiring. Deliberately does **not** auto-dismiss
    /// on success, matching `DatabaseBackupView`: the completed progress
    /// bar stays visible until the user closes it themselves, rather than
    /// the sheet vanishing the instant a (possibly minutes-long) export
    /// finishes.
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = viewModel.progress {
                ProgressView(value: progress.percentage)
                HStack {
                    Text("\(progress.completedRows)/\(progress.totalRows) rows")
                    Spacer()
                    Text("\(Int(progress.percentage * 100))%")
                }
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            }
            HStack {
                Spacer()
                Button("Close") {
                    if viewModel.isExporting { viewModel.cancelExport() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button {
                    viewModel.startExport()
                } label: {
                    if viewModel.isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Export")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canExport)
                .buttonStyle(SchemaPrimaryButtonStyle(theme: theme))
            }
        }
    }
}
