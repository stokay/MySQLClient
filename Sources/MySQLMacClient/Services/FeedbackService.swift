import Foundation
import StoreKit

/// Sends what the "Send Feedback" form collects to a first-party endpoint
/// (self-hosted on tokay.tr — see `server/analytics/feedback.php`).
///
/// Unlike `AnalyticsService` this is not anonymous telemetry and not
/// fire-and-forget: it carries what the person typed, only ever runs
/// because they pressed Send, and reports back whether it arrived. It is
/// therefore independent of the analytics opt-out, and deliberately shares
/// nothing with it — see `senderID(in:)`.
@MainActor
enum FeedbackService {
    /// `nonisolated`: it is the default value of `send`'s `endpoint`
    /// parameter, and default values are evaluated outside the main actor.
    nonisolated static let endpoint = URL(string: "https://tokay.tr/MySQLClient/analytics/feedback.php")!

    /// Mirrored by the server, which rejects anything outside this range.
    static let minimumMessageLength = 10
    static let maximumMessageLength = 4000
    static let maximumNameLength = 80

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case idea, problem, bug, other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .idea: String(localized: "Idea or suggestion")
            case .problem: String(localized: "Problem")
            case .bug: String(localized: "Bug report")
            case .other: String(localized: "Other")
            }
        }
    }

    /// The optional "system information" block. Describes the app and the
    /// Mac, plus which *kind* of server is connected — never a host name,
    /// a user name, or anything read from a database.
    struct SystemInformation: Equatable, Sendable {
        var appVersion: String
        var osVersion: String
        var deviceModel: String
        var language: String
        /// e.g. "MySQL 8.0.36"; `nil` when not connected.
        var serverInfo: String?

        /// One line per item, exactly what gets sent — shown in the form so
        /// ticking the box is never a leap of faith.
        var lines: [String] {
            ["MySQL Client \(appVersion)", osVersion, deviceModel, language] + (serverInfo.map { [$0] } ?? [])
        }
    }

    struct Submission: Equatable, Sendable {
        var category: Category
        var message: String
        /// How the sender would like to be addressed, if they said.
        var name: String?
        /// Only when the sender wants a reply.
        var email: String?
        var systemInformation: SystemInformation?
    }

    enum Outcome: Equatable, Sendable {
        case sent
        /// This installation has sent as many as one may in a day.
        case senderLimitReached
        /// The server is refusing everyone for the moment.
        case busy
        /// Turned off on the server.
        case unavailable
        /// The server didn't accept the content (should be unreachable —
        /// the form validates the same rules first).
        case rejected
        /// No answer: offline, timed out, or a server-side fault.
        case failed
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func send(
        _ submission: Submission,
        senderID: String,
        installProof: String?,
        endpoint: URL = endpoint,
        transport: Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> Outcome {
        let payload = Payload(submission: submission, senderID: senderID, installProof: installProof)
        guard let body = try? JSONEncoder().encode(payload) else { return .failed }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        guard let (data, response) = try? await transport(request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failed }

        switch status {
        case 200:
            return .sent
        case 429:
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            return code == "sender_limit" ? .senderLimitReached : .busy
        case 503:
            return .unavailable
        case 400, 413:
            return .rejected
        default:
            return .failed
        }
    }

    // MARK: - What accompanies a message

    static let senderIDDefaultsKey = "feedbackSenderID"

    /// A random ID kept for feedback alone, so the server can hold one
    /// installation to a few messages a day.
    ///
    /// Deliberately *not* `AnalyticsService`'s device ID: a message can
    /// carry an email address, and sharing the ID would tie that address
    /// to the device's whole anonymous usage history. It's also created
    /// only here, on first send — someone who never sends feedback never
    /// has one.
    static func senderID(in defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: senderIDDefaultsKey) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: senderIDDefaultsKey)
        return generated
    }

    static func systemInformation(serverVersion: String?) -> SystemInformation {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return SystemInformation(
            appVersion: AnalyticsService.appVersion + (build.map { " (\($0))" } ?? ""),
            osVersion: AnalyticsService.osVersion,
            deviceModel: AnalyticsService.deviceModel,
            language: Bundle.main.preferredLocalizations.first ?? "en",
            serverInfo: serverVersion.map(SQLConsoleViewModel.describeServer)
        )
    }

    /// Apple's signed record that this copy came from the App Store, or
    /// `nil` for any other build (Xcode, `swift run`, the DMG).
    ///
    /// The server ignores it today. It is sent so that, should the
    /// endpoint ever be abused, the server can start refusing requests
    /// without a valid one — a change on the server alone, with no app
    /// update needed to make it possible. It names the app and the
    /// purchase, not the person.
    static func installProof() async -> String? {
        // No receipt, no App Store install — and asking StoreKit anyway is
        // pointless outside one. Looked for by path: the API that names
        // this file (`appStoreReceiptURL`) is deprecated as of macOS 15.
        let receipt = Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        guard FileManager.default.fileExists(atPath: receipt.path) else { return nil }

        // Normally answered from a local cache at once; the timeout only
        // keeps a stuck StoreKit from holding the message back.
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await AppTransaction.shared.jwsRepresentation }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Wire format

    struct Payload: Encodable {
        let senderID: String
        let category: String
        let message: String
        let name: String?
        let email: String?
        let appVersion: String?
        let osVersion: String?
        let deviceModel: String?
        let language: String?
        let serverInfo: String?
        let installProof: String?

        init(submission: Submission, senderID: String, installProof: String?) {
            self.senderID = senderID
            category = submission.category.rawValue
            message = submission.message
            name = submission.name
            email = submission.email
            appVersion = submission.systemInformation?.appVersion
            osVersion = submission.systemInformation?.osVersion
            deviceModel = submission.systemInformation?.deviceModel
            language = submission.systemInformation?.language
            serverInfo = submission.systemInformation?.serverInfo
            self.installProof = installProof
        }

        enum CodingKeys: String, CodingKey {
            case senderID = "sender_id"
            case category
            case message
            case name
            case email
            case appVersion = "app_version"
            case osVersion = "os_version"
            case deviceModel = "device_model"
            case language
            case serverInfo = "server_info"
            case installProof = "install_proof"
        }
    }

    private struct ErrorBody: Decodable {
        let error: String
    }
}
