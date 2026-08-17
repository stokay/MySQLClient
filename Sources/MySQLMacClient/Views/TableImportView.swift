import SwiftUI

/// The "Import..." sheet, opened from a table's context menu in the
/// sidebar. Mirrors `TableExportView`'s shape (title row, options card,
/// a scrollable content area, `statusFooter` with progress/cancel), just
/// running in reverse: choose a CSV file instead of a destination, map its
/// columns onto the table's instead of picking which ones to write.
struct TableImportView: View {
    @StateObject private var viewModel: TableImportViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var theme: SchemaModalTheme { SchemaModalTheme(colorScheme: colorScheme) }

    init(service: MySQLService, table: TableInfo) {
        _viewModel = StateObject(wrappedValue: TableImportViewModel(service: service, table: table))
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
                        chooseFileRow
                        sourceOptionsSection
                        columnMappingSection
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
        .frame(minWidth: 560, idealWidth: 700, minHeight: 560, idealHeight: 660)
        .background(theme.windowBackground)
        .task { await viewModel.loadColumns() }
        .onChange(of: viewModel.csvOptions) { _, _ in Task { await viewModel.refreshColumnMappings() } }
        .onChange(of: viewModel.hasHeaderRow) { _, _ in Task { await viewModel.refreshColumnMappings() } }
        .onChange(of: viewModel.selectedSheetIndex) { _, _ in Task { await viewModel.refreshColumnMappings() } }
        .alert("Import Complete", isPresented: $viewModel.didFinishSuccessfully) {
            Button("OK") {}
        } message: {
            Text("Data was imported into \(viewModel.table.name) successfully.")
        }
    }

    private var canImport: Bool {
        !viewModel.isImporting
            && !viewModel.isLoadingColumns
            && viewModel.sourceFileURL != nil
            && viewModel.columnMappings.contains { $0.targetColumnName != nil }
    }

    private var titleRow: some View {
        (
            Text("Import ")
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

    /// Same shape/styling as `TableExportView.formatTabs` — an explicit
    /// choice made before browsing for a file, not inferred from whatever
    /// extension the user happens to pick. See `TableImportViewModel
    /// .SourceFormat`'s doc comment for why this matters: a file picker
    /// that silently also accepts `.xlsx` doesn't tell anyone Excel import
    /// exists.
    private var formatTabs: some View {
        HStack(spacing: 6) {
            ForEach(TableImportViewModel.SourceFormat.allCases) { format in
                formatTabButton(format)
            }
        }
    }

    private func formatTabButton(_ format: TableImportViewModel.SourceFormat) -> some View {
        let isActive = viewModel.selectedFormat == format
        return Button {
            viewModel.selectedFormat = format
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

    // MARK: - Choose file

    private var chooseFileRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("READ FROM FILE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: 8) {
                Text(viewModel.sourceFileURL?.path ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .schemaFieldBorder(theme: theme)
                Button("…") { viewModel.chooseSourceFile() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
            }
        }
    }

    // MARK: - Source options

    @ViewBuilder
    private var sourceOptionsSection: some View {
        switch viewModel.selectedFormat {
        case .csv:
            csvOptionsSection
        case .xlsx:
            xlsxOptionsSection
        }
    }

    private var xlsxOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.xlsxSheetNames.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHEET")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(theme.textSecondary)
                    Picker("", selection: $viewModel.selectedSheetIndex) {
                        ForEach(Array(viewModel.xlsxSheetNames.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index)
                        }
                    }
                    .labelsHidden()
                }
            }
            headerRowToggle
        }
        .padding(12)
        .schemaCard(theme: theme)
    }

    private var headerRowToggle: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $viewModel.hasHeaderRow)
                .labelsHidden()
                .toggleStyle(SchemaCheckboxToggleStyle(theme: theme))
            Text("First row is a header")
                .foregroundStyle(theme.textPrimary)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.hasHeaderRow.toggle() }
    }

    private var csvOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                labeledField("DELIMITER", text: Binding(
                    get: { viewModel.csvOptions.fieldTerminator },
                    set: { viewModel.csvOptions.fieldTerminator = $0 }
                ))
                labeledField("ENCLOSURE", text: Binding(
                    get: { viewModel.csvOptions.fieldEnclosure },
                    set: { viewModel.csvOptions.fieldEnclosure = $0 }
                ))
                labeledField("ESCAPE CHARACTER", text: Binding(
                    get: { viewModel.csvOptions.fieldEscape },
                    set: { viewModel.csvOptions.fieldEscape = $0 }
                ))
            }
            headerRowToggle
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

    // MARK: - Column mapping

    /// One row per **table** column (fixed, left) with a dropdown (right)
    /// choosing which CSV header feeds it — the mirror image of choosing,
    /// per CSV column, which table column it lands in; this direction
    /// reads more naturally top-to-bottom since the table's own columns
    /// are the fixed, known list. At most one table column can claim a
    /// given CSV header at a time; picking one clears it from wherever it
    /// was previously assigned.
    @ViewBuilder
    private var columnMappingSection: some View {
        if viewModel.sourceFileURL != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("COLUMN MAPPING")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.textSecondary)

                if viewModel.columnMappings.isEmpty {
                    Text("No data found in the file.")
                        .font(.callout)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Text("TABLE COLUMNS")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(sourceColumnsLabel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)

                        ForEach(viewModel.allColumns) { column in
                            columnMappingRow(column)
                        }
                    }
                    .schemaCard(theme: theme)
                }
            }
        }
    }

    private var sourceColumnsLabel: LocalizedStringKey {
        viewModel.selectedFormat == .xlsx ? "EXCEL COLUMNS" : "CSV COLUMNS"
    }

    private func columnMappingRow(_ tableColumn: ColumnInfo) -> some View {
        HStack(spacing: 12) {
            Text(tableColumn.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: sourceHeaderBinding(for: tableColumn)) {
                Text("None").tag(Int?.none)
                ForEach(viewModel.columnMappings) { mapping in
                    Text(mapping.sourceHeaderName).tag(Int?.some(mapping.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func sourceHeaderBinding(for tableColumn: ColumnInfo) -> Binding<Int?> {
        Binding(
            get: { viewModel.columnMappings.first { $0.targetColumnName == tableColumn.name }?.id },
            set: { newSourceID in
                // A CSV column can only feed one table column at a time —
                // clear whichever mapping currently claims this table
                // column before assigning the newly picked one (or none).
                for index in viewModel.columnMappings.indices
                where viewModel.columnMappings[index].targetColumnName == tableColumn.name {
                    viewModel.columnMappings[index].targetColumnName = nil
                }
                guard let newSourceID,
                      let index = viewModel.columnMappings.firstIndex(where: { $0.id == newSourceID }) else { return }
                viewModel.columnMappings[index].targetColumnName = tableColumn.name
            }
        )
    }

    // MARK: - Status footer

    /// Same shape as `TableExportView.statusFooter`: progress bar + row
    /// counter/percentage while running, "Kapat" cancels a running import
    /// before dismissing, "İçe Aktar" starts one. Doesn't auto-dismiss on
    /// success — the completed progress bar and the alert stay up until
    /// the user closes the sheet themselves.
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
                    if viewModel.isImporting { viewModel.cancelImport() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button {
                    viewModel.startImport()
                } label: {
                    if viewModel.isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Import")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
                .buttonStyle(SchemaPrimaryButtonStyle(theme: theme))
            }
        }
    }
}
