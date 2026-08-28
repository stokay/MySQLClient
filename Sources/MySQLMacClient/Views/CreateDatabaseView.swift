import SwiftUI

/// "Create Database..." form, presented from the sidebar's root
/// (`username@host`) row — the one sidebar action with no existing
/// database to scope it to. Same plain-`Form` weight as
/// `CreateNamedSchemaObjectView` (a small utility sheet); charset/collation
/// pickers are populated from the live server, same as `CreateTableView`.
struct CreateDatabaseView: View {
    @StateObject private var viewModel: CreateDatabaseViewModel
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    init(service: MySQLService, historyRecorder: QueryHistoryRecorder? = nil, onCreated: @escaping (String) -> Void) {
        _viewModel = StateObject(wrappedValue: CreateDatabaseViewModel(service: service, historyRecorder: historyRecorder))
        self.onCreated = onCreated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Database")
                .font(.title2.bold())

            Form {
                LabeledContent("Database Name") {
                    TextField("", text: $viewModel.databaseName)
                        .visibleFieldBorder()
                        .onSubmit { Task { await submit() } }
                }
                Picker("Character Set", selection: $viewModel.charset) {
                    ForEach(viewModel.charsetOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Collation", selection: $viewModel.collation) {
                    ForEach(viewModel.collationOptions, id: \.self) { Text($0).tag($0) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .gridLineColor)))

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if viewModel.isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSubmit)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 480)
        .task {
            await viewModel.loadCharsetOptions()
        }
    }

    private func submit() async {
        if let created = await viewModel.submit() {
            onCreated(created)
            dismiss()
        }
    }
}
