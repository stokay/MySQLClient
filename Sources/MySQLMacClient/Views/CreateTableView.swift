import SwiftUI

/// A "New Table" form, presented as a sheet from the window toolbar's
/// "Yeni Tablo" button. Reads the live database list off `schemaTree`
/// (rather than a snapshot) so it stays correct even if the sidebar hadn't
/// finished loading databases yet when the sheet opened. The column grid is
/// the shared `DraftColumnsEditor`; both share `SchemaModalTheme`'s visual
/// language with `AlterTableView`.
struct CreateTableView: View {
    @StateObject private var viewModel: CreateTableViewModel
    @ObservedObject var schemaTree: SchemaTreeViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let onCreated: (TableInfo) -> Void

    private var theme: SchemaModalTheme { SchemaModalTheme(colorScheme: colorScheme) }

    init(
        service: MySQLService,
        schemaTree: SchemaTreeViewModel,
        defaultDatabase: String,
        historyRecorder: QueryHistoryRecorder? = nil,
        onCreated: @escaping (TableInfo) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: CreateTableViewModel(
            service: service,
            defaultDatabase: defaultDatabase,
            historyRecorder: historyRecorder
        ))
        self.schemaTree = schemaTree
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Table")
                .font(.title2.bold())
                .foregroundStyle(theme.textPrimary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    importColumnsSection
                    DraftColumnsEditor(columns: $viewModel.columns, dataTypes: CreateTableViewModel.dataTypes)
                    sqlPreviewSection
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button {
                    Task {
                        if let table = await viewModel.submit() {
                            onCreated(table)
                            dismiss()
                        }
                    }
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSubmit)
                .buttonStyle(SchemaPrimaryButtonStyle(theme: theme))
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 32)
        // Wide enough for `DraftColumnsEditor`'s row to fit *plus* this
        // horizontal padding. That row is built from fixed pixel widths
        // (~908pt including its own card padding) and cannot shrink, so a
        // frame narrower than 908 + 2×32 makes the grid overflow and
        // visually eat the padding — the padding then looks like it isn't
        // applied at all, however large a value is set. The row's widths
        // grew when the column headers were widened for the longer
        // Spanish/German labels, which is what left the old 960pt-wide
        // sheet with nothing to spare.
        .frame(minWidth: 1000, idealWidth: 1040, minHeight: 640, idealHeight: 700)
        .background(theme.windowBackground)
        .task {
            await viewModel.loadCharsetOptions()
        }
    }

    private var header: some View {
        Form {
            LabeledContent("Table Name") {
                TextField("", text: $viewModel.tableName)
                    .schemaFieldBorder(theme: theme)
            }
            Picker("Database", selection: $viewModel.database) {
                ForEach(schemaTree.databaseNodes) { node in
                    Text(node.info.name).tag(node.info.name)
                }
            }
            HStack(spacing: 20) {
                Picker("Engine", selection: $viewModel.engine) {
                    ForEach(CreateTableViewModel.engines, id: \.self) { Text($0).tag($0) }
                }
                Picker("Character Set", selection: $viewModel.charset) {
                    ForEach(viewModel.charsetOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Collation", selection: $viewModel.collation) {
                    ForEach(viewModel.collationOptions, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(12)
        .schemaCard(theme: theme)
    }

    // MARK: - Import columns from file

    /// A starting point for the column grid below, not a second way to
    /// create the table: this only ever fills in `viewModel.columns` —
    /// nothing here touches the database until "Create" is pressed, and
    /// the file's *data* is never read past the sample used to guess
    /// types. Mirrors `TableImportView`'s CSV/Excel format tabs so the
    /// same choice looks the same everywhere it appears.
    private var importColumnsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IMPORT COLUMNS FROM FILE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)

            HStack(spacing: 6) {
                ForEach(ImportSourceFormat.allCases) { format in
                    columnImportFormatTabButton(format)
                }
            }

            HStack(spacing: 8) {
                Text(viewModel.columnImportSourceURL?.path ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .schemaFieldBorder(theme: theme)
                Button("…") { viewModel.chooseColumnImportFile() }
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button {
                    Task { await viewModel.importColumns() }
                } label: {
                    if viewModel.isImportingColumns {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Import Columns")
                    }
                }
                .buttonStyle(SchemaPrimaryButtonStyle(theme: theme))
                .disabled(viewModel.columnImportSourceURL == nil || viewModel.isImportingColumns)
            }

            if viewModel.columnImportFormat == .xlsx, viewModel.columnImportSheetNames.count > 1 {
                Picker("", selection: $viewModel.columnImportSelectedSheetIndex) {
                    ForEach(Array(viewModel.columnImportSheetNames.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }

            if let columnImportErrorMessage = viewModel.columnImportErrorMessage {
                Text(columnImportErrorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Text("Only the table structure is created — no records are imported. Review the suggested types below before creating.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.amber)
        }
        .padding(12)
        .schemaCard(theme: theme)
    }

    private func columnImportFormatTabButton(_ format: ImportSourceFormat) -> some View {
        let isActive = viewModel.columnImportFormat == format
        return Button {
            viewModel.columnImportFormat = format
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

    private var sqlPreviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SQL PREVIEW")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
            ScrollView {
                Text(viewModel.previewSQL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 90, maxHeight: 140)
            .schemaCard(theme: theme, fill: theme.previewBackground)
        }
    }
}
