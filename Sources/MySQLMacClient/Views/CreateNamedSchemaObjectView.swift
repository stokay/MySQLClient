import SwiftUI

/// Prompts for a single name (view/procedure/function/... — whichever
/// schema object the sidebar's "Oluştur" menu is creating), then hands the
/// caller that name to build a SQL skeleton from. Unlike `CreateTableView`'s
/// full column editor, these object types' actual bodies are hand-written
/// SQL the user still has to fill in, so a name is the only thing worth a
/// form for.
struct CreateNamedSchemaObjectView: View {
    let title: String
    let nameFieldLabel: String
    let database: String
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())

            Form {
                LabeledContent("Database") {
                    Text(database)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(nameFieldLabel) {
                    TextField("", text: $name)
                        .visibleFieldBorder()
                        .onSubmit(submit)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .gridLineColor)))

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 460)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (try? SchemaIntrospectionService.quotedIdentifier(trimmed)) != nil else {
            errorMessage = String(localized: "Invalid \(nameFieldLabel.lowercased()).")
            return
        }
        onCreate(trimmed)
        dismiss()
    }
}
