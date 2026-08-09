import SwiftUI

struct PaginationControlView: View {
    @ObservedObject var viewModel: TableDataViewModel

    @State private var filterColumnSelection: String = ""
    @State private var filterText: String = ""

    /// Bound straight to `viewModel.pageSize` (not a separate local draft
    /// string) so a value typed here is already current the moment
    /// "Yenile" — which lives in the sibling grid toolbar and has no way to
    /// see this view's own local state — is clicked, with no Enter/onSubmit
    /// required first.
    private var pageSizeBinding: Binding<String> {
        Binding(
            get: { String(viewModel.pageSize) },
            set: { newValue in
                if let value = Int(newValue), value > 0 {
                    viewModel.pageSize = value
                }
            }
        )
    }

    private var paginationEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isPaginationEnabled },
            set: { newValue in Task { await viewModel.setPaginationEnabled(newValue) } }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("Page size:")
                .lineLimit(1)
            TextField("", text: pageSizeBinding)
                .frame(width: 60)
                .disabled(!viewModel.isPaginationEnabled)
                .onSubmit {
                    Task { await viewModel.reload() }
                }

            Toggle("Limited", isOn: paginationEnabledBinding)
                .toggleStyle(.checkbox)
                .lineLimit(1)
                .help("When off, the page size is ignored and the whole table is loaded.")

            Spacer()

            Picker("Filter column", selection: $filterColumnSelection) {
                Text("Select column").tag("")
                ForEach(viewModel.columns) { column in
                    Text(column.name).tag(column.name)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            TextField("Filter value", text: $filterText)
                .frame(width: 160)
                .onSubmit {
                    Task {
                        await viewModel.applyFilter(
                            column: filterColumnSelection.isEmpty ? nil : filterColumnSelection,
                            value: filterText
                        )
                    }
                }

            if !filterText.isEmpty || !filterColumnSelection.isEmpty {
                Button {
                    filterColumnSelection = ""
                    filterText = ""
                    Task { await viewModel.applyFilter(column: nil, value: "") }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
        }
    }
}
