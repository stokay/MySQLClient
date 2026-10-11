import SwiftUI

/// The "Send Feedback" window — ideas, suggestions, problems and bugs,
/// straight to the developer (`FeedbackService`). Its own window rather
/// than a sheet so it's reachable from the connection screen too, where
/// someone who can't connect is most likely to want it.
struct FeedbackView: View {
    static let windowID = "feedback"

    @StateObject private var viewModel: FeedbackViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// `viewModel` is injectable for tests; production builds its own.
    /// Not a default argument: the view model's initializer is main-actor
    /// isolated, and a default value is evaluated outside that isolation
    /// under the Xcode project's Swift settings — `swift build` accepted
    /// it, the app target did not compile.
    @MainActor
    init(viewModel: FeedbackViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? FeedbackViewModel())
    }

    var body: some View {
        Group {
            if viewModel.didSend {
                thanks
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 500)
        // Which server is connected can change while this window is open.
        .task(id: appState.activeSession?.id) {
            viewModel.updateServerVersion(await appState.activeSession?.mysqlService.serverVersion)
        }
        // Reopening after a sent message should offer an empty form, not
        // the thank-you; an unsent draft is left as it was.
        .onDisappear {
            if viewModel.didSend {
                viewModel.reset()
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            // No heading of its own: unlike the app's sheets this is a
            // window, and its title bar already says "Send Feedback".
            Text("Ideas, suggestions, problems, bugs — your message goes straight to the developer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Picker("Type", selection: $viewModel.category) {
                    ForEach(FeedbackService.Category.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
                .fixedSize()

                messageEditor

                // A grid so both fields start at the same x whatever the
                // two labels' widths are in the current language.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Name")
                        TextField("Optional", text: $viewModel.name)
                            .visibleFieldBorder()
                            .textContentType(.name)
                    }
                    GridRow {
                        Text("Email")
                        TextField("Optional — only if you'd like a reply", text: $viewModel.email)
                            .visibleFieldBorder()
                            .textContentType(.emailAddress)
                    }
                }
                if !viewModel.isEmailValid {
                    Text("This doesn't look like an email address.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Divider()

                Toggle("Include system information", isOn: $viewModel.includesSystemInformation)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.systemInformation.lines.joined(separator: " · "))
                        .textSelection(.enabled)
                        .opacity(viewModel.includesSystemInformation ? 1 : 0.45)
                    Text("Connection details, queries and your data are never included. Please don't put passwords in your message.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .gridLineColor)))

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await viewModel.send() }
                } label: {
                    if viewModel.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSend)
            }
        }
    }

    /// `TextEditor` has no placeholder of its own; this one sits behind
    /// the text and must not take clicks meant for the editor.
    private var messageEditor: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: $viewModel.message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 150)
                .background(alignment: .topLeading) {
                    if viewModel.message.isEmpty {
                        Text("What would you like to tell us?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .gridLineColor)))

            Text(verbatim: "\(viewModel.trimmedMessage.count) / \(FeedbackService.maximumMessageLength)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(viewModel.isMessageTooLong ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
        }
    }

    private var thanks: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Thank you!")
                .font(.title2.bold())
            Text("Your message was sent.")
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// Opens the feedback window from the window toolbar. A view of its own
/// because `openWindow` is read from the environment.
///
/// Deliberately the loudest thing in the toolbar — title, filled icon and
/// a tint none of the other items use. As a plain gray icon it went
/// unnoticed, and the Help menu is not somewhere people look; a channel
/// nobody finds collects nothing.
struct FeedbackToolbarButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: FeedbackView.windowID)
        } label: {
            Label("Send Feedback", systemImage: "bubble.left.and.text.bubble.right.fill")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .help("Send Feedback")
    }
}

/// Help ▸ Send Feedback… — replaces the stock "MySQL Client Help" item,
/// which has no help book to open and only ever said so.
struct FeedbackCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") {
                openWindow(id: FeedbackView.windowID)
            }
        }
    }
}
