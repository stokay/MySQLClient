import Foundation

/// State behind the "Send Feedback" window: what's been typed, whether it
/// may be sent, and what came of sending it.
@MainActor
final class FeedbackViewModel: ObservableObject {
    @Published var category: FeedbackService.Category = .idea
    @Published var message = ""
    @Published var name = ""
    @Published var email = ""
    @Published var includesSystemInformation = true

    @Published private(set) var systemInformation: FeedbackService.SystemInformation
    @Published private(set) var isSending = false
    /// Once true the form is replaced by a thank-you; `reset()` starts over.
    @Published private(set) var didSend = false
    @Published private(set) var errorMessage: String?

    typealias Sender = @MainActor (FeedbackService.Submission) async -> FeedbackService.Outcome
    private let sender: Sender

    /// `sender` is injectable for tests; production posts to the real
    /// endpoint with this installation's feedback ID and install proof.
    init(
        systemInformation: FeedbackService.SystemInformation? = nil,
        sender: Sender? = nil
    ) {
        self.systemInformation = systemInformation ?? FeedbackService.systemInformation(serverVersion: nil)
        self.sender = sender ?? { submission in
            await FeedbackService.send(
                submission,
                senderID: FeedbackService.senderID(),
                installProof: await FeedbackService.installProof()
            )
        }
    }

    // MARK: - Validation

    var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Optional, and cut to what the server keeps rather than refused — a
    /// name is a courtesy, not something worth failing a message over.
    var trimmedName: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FeedbackService.maximumNameLength))
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isMessageTooLong: Bool {
        trimmedMessage.count > FeedbackService.maximumMessageLength
    }

    /// Empty is fine — the address is optional. Otherwise it only has to
    /// look like one; the server makes the final call.
    var isEmailValid: Bool {
        let email = trimmedEmail
        return email.isEmpty || (email.utf8.count <= 254 && email.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil)
    }

    var canSend: Bool {
        !isSending
            && trimmedMessage.count >= FeedbackService.minimumMessageLength
            && !isMessageTooLong
            && isEmailValid
    }

    /// What pressing Send would transmit, exactly.
    var submission: FeedbackService.Submission {
        FeedbackService.Submission(
            category: category,
            message: trimmedMessage,
            name: trimmedName.isEmpty ? nil : trimmedName,
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            systemInformation: includesSystemInformation ? systemInformation : nil
        )
    }

    // MARK: - Actions

    /// Refreshes the "which server" line for whatever is connected right
    /// now (`nil` when nothing is) — only its product and version.
    func updateServerVersion(_ serverVersion: String?) {
        systemInformation = FeedbackService.systemInformation(serverVersion: serverVersion)
    }

    func send() async {
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        let outcome = await sender(submission)
        isSending = false

        switch outcome {
        case .sent:
            // No analytics event for this, on purpose: one arriving in the
            // same second as the message would tie the anonymous device ID
            // to whatever email address the message carries.
            didSend = true
        case .senderLimitReached:
            errorMessage = String(localized: "You've sent several messages today. Please try again tomorrow.")
        case .busy:
            errorMessage = String(localized: "Too many messages are arriving right now. Please try again later.")
        case .unavailable:
            errorMessage = String(localized: "Feedback is temporarily unavailable. Please try again later.")
        case .rejected:
            errorMessage = String(localized: "The message could not be accepted. Please check it and try again.")
        case .failed:
            errorMessage = String(localized: "Could not send the message. Check your internet connection and try again.")
        }
    }

    /// Back to an empty form. The name, the email address and the
    /// system-information choice are kept — the same person is likely to
    /// want them again.
    func reset() {
        category = .idea
        message = ""
        errorMessage = nil
        didSend = false
    }
}
