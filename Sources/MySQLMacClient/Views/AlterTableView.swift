import SwiftUI

/// The "Alter Table" sheet, opened from a table's context menu in the
/// sidebar. Same layout as `CreateTableView`, but the column grid arrives
/// pre-filled with the live schema and the SQL preview shows the *diff* as
/// a single `ALTER TABLE` statement (or a "no changes" note). Shares
/// `SchemaModalTheme`'s visual language with `CreateTableView`.
struct AlterTableView: View {
    @StateObject private var viewModel: AlterTableViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let onAltered: (TableInfo) -> Void

    private var theme: SchemaModalTheme { SchemaModalTheme(colorScheme: colorScheme) }

    init(
        service: MySQLService,
        table: TableInfo,
        historyRecorder: QueryHistoryRecorder? = nil,
        onAltered: @escaping (TableInfo) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: AlterTableViewModel(
            service: service,
            table: table,
            historyRecorder: historyRecorder
        ))
        self.onAltered = onAltered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            (
                Text("Alter Table ")
                    .font(.title2.bold())
                    .foregroundColor(theme.textPrimary)
                + Text("— ")
                    .font(.title2.bold())
                    .foregroundColor(theme.textSecondary)
                + Text(viewModel.originalTableName)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.amber)
            )

            if viewModel.isLoading {
                ProgressView("Tablo yapısı yükleniyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        DraftColumnsEditor(
                            columns: $viewModel.columns,
                            dataTypes: viewModel.availableDataTypes
                        )
                        sqlPreviewSection
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("İptal") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SchemaSecondaryButtonStyle(theme: theme))
                Button {
                    Task {
                        if let table = await viewModel.submit() {
                            onAltered(table)
                            dismiss()
                        }
                    }
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Uygula")
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
            await viewModel.load()
        }
    }

    private var header: some View {
        Form {
            LabeledContent("Tablo Adı") {
                TextField("", text: $viewModel.tableName)
                    .schemaFieldBorder(theme: theme)
            }
            LabeledContent("Veritabanı") {
                Text(viewModel.database)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(12)
        .schemaCard(theme: theme)
    }

    private var sqlPreviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SQL ÖNİZLEME")
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
