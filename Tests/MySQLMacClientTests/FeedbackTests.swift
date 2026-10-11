import XCTest
@testable import MySQLMacClient

/// Pure logic — no network, no database. The transport and the sender are
/// both injected, so nothing here reaches the real feedback endpoint.
@MainActor
final class FeedbackTests: XCTestCase {
    private let systemInformation = FeedbackService.SystemInformation(
        appVersion: "1.8.0 (17)",
        osVersion: "macOS 26.5.1",
        deviceModel: "Mac16,5",
        language: "tr",
        serverInfo: "MySQL 8.0.36"
    )

    private func submission(name: String? = nil, email: String? = nil, withSystemInformation: Bool = true) -> FeedbackService.Submission {
        FeedbackService.Submission(
            category: .bug,
            message: "Run All stops on the second statement.",
            name: name,
            email: email,
            systemInformation: withSystemInformation ? systemInformation : nil
        )
    }

    private func response(_ status: Int, _ body: String = "{}") -> FeedbackService.Transport {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: - What goes over the wire

    func testPayloadUsesTheServersFieldNames() throws {
        let payload = FeedbackService.Payload(submission: submission(name: "Ayşe", email: "user@example.com"), senderID: "ABC", installProof: "proof")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: String])
        XCTAssertEqual(json, [
            "sender_id": "ABC",
            "category": "bug",
            "message": "Run All stops on the second statement.",
            "name": "Ayşe",
            "email": "user@example.com",
            "app_version": "1.8.0 (17)",
            "os_version": "macOS 26.5.1",
            "device_model": "Mac16,5",
            "language": "tr",
            "server_info": "MySQL 8.0.36",
            "install_proof": "proof",
        ])
    }

    /// Unticking "Include system information" must leave every one of its
    /// fields out — not send them empty.
    func testPayloadOmitsWhatTheSenderLeftOut() throws {
        let payload = FeedbackService.Payload(submission: submission(withSystemInformation: false), senderID: "ABC", installProof: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: String])
        XCTAssertEqual(Set(json.keys), ["sender_id", "category", "message"])
    }

    func testRequestIsAJSONPostToTheEndpoint() async {
        let captured = Captured()
        let outcome = await FeedbackService.send(submission(), senderID: "ABC", installProof: nil) { request in
            await captured.set(request)
            return (Data("{\"ok\":true}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(outcome, .sent)
        let request = await captured.request
        XCTAssertEqual(request?.url, FeedbackService.endpoint)
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(request?.httpBody)
    }

    // MARK: - What the server's answer means

    func testServerAnswersMapToOutcomes() async {
        let cases: [(FeedbackService.Transport, FeedbackService.Outcome)] = [
            (response(200, "{\"ok\":true}"), .sent),
            (response(429, "{\"error\":\"sender_limit\"}"), .senderLimitReached),
            (response(429, "{\"error\":\"busy\"}"), .busy),
            (response(429, "not json"), .busy),
            (response(503, "{\"error\":\"disabled\"}"), .unavailable),
            (response(400, "{\"error\":\"invalid_message\"}"), .rejected),
            (response(413), .rejected),
            (response(500), .failed),
            ({ _ in throw URLError(.notConnectedToInternet) }, .failed),
        ]
        for (transport, expected) in cases {
            let outcome = await FeedbackService.send(submission(), senderID: "ABC", installProof: nil, transport: transport)
            XCTAssertEqual(outcome, expected)
        }
    }

    // MARK: - Sender ID

    /// Stable across sends, and never the analytics device ID — a message
    /// can carry an email address, and one shared ID would attach that
    /// address to the device's anonymous usage history.
    func testSenderIDIsStableAndSeparateFromTheAnalyticsID() throws {
        let suiteName = "feedback-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ANALYTICS-ID", forKey: "analyticsDeviceID")

        let first = FeedbackService.senderID(in: defaults)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(FeedbackService.senderID(in: defaults), first)
        XCTAssertNotEqual(first, "ANALYTICS-ID")
        XCTAssertEqual(defaults.string(forKey: "analyticsDeviceID"), "ANALYTICS-ID")
    }

    // MARK: - The form

    private func makeViewModel(outcome: FeedbackService.Outcome = .sent, sent: Sent = Sent()) -> FeedbackViewModel {
        FeedbackViewModel(systemInformation: systemInformation) { submission in
            sent.submissions.append(submission)
            return outcome
        }
    }

    func testSendIsOnlyOfferedForAUsableMessage() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.canSend, "empty")

        viewModel.message = "   too short \n"
        XCTAssertFalse(viewModel.canSend, "under the minimum once trimmed")

        viewModel.message = "Long enough to be worth reading."
        XCTAssertTrue(viewModel.canSend)

        viewModel.message = String(repeating: "x", count: FeedbackService.maximumMessageLength + 1)
        XCTAssertTrue(viewModel.isMessageTooLong)
        XCTAssertFalse(viewModel.canSend)
    }

    func testEmailIsOptionalButMustLookLikeOneWhenGiven() {
        let viewModel = makeViewModel()
        viewModel.message = "Long enough to be worth reading."

        for valid in ["", "   ", "user@example.com", " user+tag@mail.example.co.uk "] {
            viewModel.email = valid
            XCTAssertTrue(viewModel.isEmailValid, valid)
            XCTAssertTrue(viewModel.canSend, valid)
        }
        for invalid in ["user", "user@", "@example.com", "user@example", "two words@example.com"] {
            viewModel.email = invalid
            XCTAssertFalse(viewModel.isEmailValid, invalid)
            XCTAssertFalse(viewModel.canSend, invalid)
        }
    }

    func testSubmissionCarriesExactlyWhatWasChosen() async {
        let sent = Sent()
        let viewModel = makeViewModel(sent: sent)
        viewModel.category = .problem
        viewModel.message = "\n  Cannot connect through the tunnel.  \n"
        viewModel.name = "  Ayşe Yılmaz "
        viewModel.email = " user@example.com "
        viewModel.includesSystemInformation = false

        await viewModel.send()

        XCTAssertEqual(sent.submissions, [
            FeedbackService.Submission(
                category: .problem,
                message: "Cannot connect through the tunnel.",
                name: "Ayşe Yılmaz",
                email: "user@example.com",
                systemInformation: nil
            ),
        ])
        XCTAssertTrue(viewModel.didSend)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSystemInformationIsSentOnlyWhileTicked() {
        let viewModel = makeViewModel()
        viewModel.message = "Long enough to be worth reading."
        XCTAssertEqual(viewModel.submission.systemInformation, systemInformation)
        XCTAssertNil(viewModel.submission.email, "an empty email field sends no email at all")
        XCTAssertNil(viewModel.submission.name, "an empty name field sends no name at all")

        viewModel.includesSystemInformation = false
        XCTAssertNil(viewModel.submission.systemInformation)
    }

    /// A failed send must leave everything typed in place to try again.
    func testAFailedSendKeepsTheDraftAndExplains() async {
        for outcome in [FeedbackService.Outcome.senderLimitReached, .busy, .unavailable, .rejected, .failed] {
            let viewModel = makeViewModel(outcome: outcome)
            viewModel.message = "Long enough to be worth reading."
            await viewModel.send()

            XCTAssertFalse(viewModel.didSend)
            XCTAssertFalse(viewModel.isSending)
            XCTAssertNotNil(viewModel.errorMessage)
            XCTAssertEqual(viewModel.message, "Long enough to be worth reading.")
            XCTAssertTrue(viewModel.canSend)
        }
    }

    func testNothingIsSentWhileTheFormIsInvalid() async {
        let sent = Sent()
        let viewModel = makeViewModel(sent: sent)
        viewModel.message = "short"
        await viewModel.send()
        XCTAssertTrue(sent.submissions.isEmpty)
        XCTAssertFalse(viewModel.didSend)
    }

    /// A name never blocks sending: blank means none, and an overlong one
    /// is cut to what the server keeps.
    func testNameIsOptionalAndCapped() {
        let viewModel = makeViewModel()
        viewModel.message = "Long enough to be worth reading."

        viewModel.name = "   "
        XCTAssertNil(viewModel.submission.name)
        XCTAssertTrue(viewModel.canSend)

        viewModel.name = String(repeating: "ş", count: 200)
        XCTAssertEqual(viewModel.submission.name?.count, FeedbackService.maximumNameLength)
        XCTAssertTrue(viewModel.canSend)
    }

    func testResetStartsANewMessageButKeepsNameAndEmail() async {
        let viewModel = makeViewModel()
        viewModel.category = .bug
        viewModel.message = "Long enough to be worth reading."
        viewModel.name = "Ayşe"
        viewModel.email = "user@example.com"
        await viewModel.send()
        XCTAssertTrue(viewModel.didSend)

        viewModel.reset()
        XCTAssertFalse(viewModel.didSend)
        XCTAssertEqual(viewModel.message, "")
        XCTAssertEqual(viewModel.category, .idea)
        XCTAssertEqual(viewModel.name, "Ayşe")
        XCTAssertEqual(viewModel.email, "user@example.com")
    }

    func testSystemInformationLinesAreWhatIsShownAndSent() {
        XCTAssertEqual(systemInformation.lines, ["MySQL Client 1.8.0 (17)", "macOS 26.5.1", "Mac16,5", "tr", "MySQL 8.0.36"])
        var disconnected = systemInformation
        disconnected.serverInfo = nil
        XCTAssertEqual(disconnected.lines.count, 4)
    }
}

@MainActor
private final class Sent {
    var submissions: [FeedbackService.Submission] = []
}

private actor Captured {
    var request: URLRequest?
    func set(_ request: URLRequest) { self.request = request }
}
