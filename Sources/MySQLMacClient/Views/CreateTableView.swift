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
        .padding(24)
        .frame(minWidth: 920, idealWidth: 960, minHeight: 640, idealHeight: 700)
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
