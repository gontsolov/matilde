import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// FEEDBACK (ROADMAP UI-29): "Send Feedback" in both apps. `POST /v1/feedback` on the sync server
// (server/PROTOCOL.md, "Feedback") turns each message into an issue in the owner's Linear.
// Privacy: only what the user typed, the optional reply email and, if the toggle is on, the
// diagnostics shown in the sheet. Never note content, account email or analytics.

public enum FeedbackKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case bug, idea, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bug: "Bug"
        case .idea: "Idea"
        case .other: "Something else"
        }
    }
}

/// App version and device, sent only while "Include app version and device" is on. The sheet
/// shows exactly these values (`lines`) before sending.
public struct FeedbackDiagnostics: Codable, Equatable, Sendable {
    public var app: String
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var deviceModel: String?
    public var locale: String?

    public init(app: String, appVersion: String, build: String, osVersion: String, deviceModel: String? = nil, locale: String? = nil) {
        self.app = app
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.locale = locale
    }

    /// `macos` or `ios`, as the server expects.
    public static var currentApp: String {
        #if os(iOS)
        return "ios"
        #else
        return "macos"
        #endif
    }

    public static func current(bundle: Bundle = .main, locale: Locale = .current) -> FeedbackDiagnostics {
        let info = bundle.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var os = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { os += ".\(version.patchVersion)" }
        #if os(iOS)
        let osName = "iOS"
        #else
        let osName = "macOS"
        #endif
        return FeedbackDiagnostics(
            app: currentApp,
            appVersion: Self.clean(info["CFBundleShortVersionString"] as? String, allowed: versionCharacters, max: 32) ?? "0",
            build: Self.clean(info["CFBundleVersion"] as? String, allowed: buildCharacters, max: 32) ?? "0",
            osVersion: "\(osName) \(os)",
            deviceModel: Self.clean(hardwareModel(), allowed: modelCharacters, max: 64),
            locale: Self.clean(locale.identifier, allowed: localeCharacters, max: 35)
        )
    }

    public struct Line: Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    /// What the disclosure under the toggle shows: exactly the values that are sent.
    public var lines: [Line] {
        var lines = [
            Line(label: "App", value: "Matilde \(appVersion) (\(build)) for \(app == "ios" ? "iPhone" : "Mac")"),
            Line(label: "System", value: osVersion)
        ]
        if let deviceModel { lines.append(Line(label: "Device", value: deviceModel)) }
        if let locale { lines.append(Line(label: "Language", value: locale)) }
        return lines
    }

    // The server's character sets (server/src/feedback/validate.ts).
    static let versionCharacters = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+-")
    static let buildCharacters = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.")
    static let modelCharacters = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ ,.()_-")
    static let localeCharacters = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-@=.")

    static func clean(_ value: String?, allowed: CharacterSet, max: Int) -> String? {
        guard let value else { return nil }
        let kept = String(String.UnicodeScalarView(value.unicodeScalars.filter { allowed.contains($0) }))
        let trimmed = String(kept.trimmingCharacters(in: .whitespaces).prefix(max)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "Mac14,2" or "iPhone17,1": the model identifier, never the user's device name.
    static func hardwareModel() -> String? {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
        #elseif os(iOS)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #else
        return nil
        #endif
    }
}

/// The body of `POST /v1/feedback`.
public struct FeedbackRequest: Encodable, Equatable, Sendable {
    public var kind: FeedbackKind
    public var message: String
    public var replyEmail: String?
    public var includeDiagnostics: Bool
    public var diagnostics: FeedbackDiagnostics?

    public init(kind: FeedbackKind, message: String, replyEmail: String?, includeDiagnostics: Bool, diagnostics: FeedbackDiagnostics?) {
        self.kind = kind
        self.message = message
        self.replyEmail = replyEmail
        self.includeDiagnostics = includeDiagnostics
        self.diagnostics = includeDiagnostics ? diagnostics : nil
    }
}

/// What the user has typed in the sheet.
public struct FeedbackDraft: Equatable, Sendable {
    public static let maxMessageLength = 5000

    public var kind: FeedbackKind
    public var message: String
    public var replyEmail: String
    public var includeDiagnostics: Bool

    public init(kind: FeedbackKind = .other, message: String = "", replyEmail: String = "", includeDiagnostics: Bool = true) {
        self.kind = kind
        self.message = message
        self.replyEmail = replyEmail
        self.includeDiagnostics = includeDiagnostics
    }

    public var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Counted as the server counts (Unicode scalars).
    public var messageLength: Int { trimmedMessage.unicodeScalars.count }
    public var isTooLong: Bool { messageLength > Self.maxMessageLength }
    public var trimmedEmail: String { replyEmail.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Empty is fine: the email is optional.
    public var replyEmailIsValid: Bool { trimmedEmail.isEmpty || (trimmedEmail.count <= 254 && EmailInput.isPlausible(trimmedEmail)) }
    public var canSend: Bool { messageLength > 0 && !isTooLong && replyEmailIsValid }

    public func request(diagnostics: FeedbackDiagnostics) -> FeedbackRequest {
        FeedbackRequest(kind: kind, message: trimmedMessage, replyEmail: trimmedEmail.isEmpty ? nil : trimmedEmail,
                        includeDiagnostics: includeDiagnostics, diagnostics: diagnostics)
    }

    /// The "Email instead" fallback: the same message in the user's mail app.
    public func mailtoURL(diagnostics: FeedbackDiagnostics) -> URL {
        var body = trimmedMessage
        if includeDiagnostics {
            body += "\n\n" + diagnostics.lines.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        }
        return FeedbackCopy.mailtoURL(subject: "Matilde feedback: \(kind.title)", body: body)
    }
}

public enum FeedbackOutcome: Equatable, Sendable {
    /// Delivered to the owner.
    case sent
    /// The server kept it and delivers it later (Linear was unavailable).
    case saved
}

/// Sends feedback to the sync server the app is set to (production or staging).
public struct FeedbackClient: Sendable {
    public let http: SyncHTTP

    public init(http: SyncHTTP) {
        self.http = http
    }

    public init(server: SyncServer) {
        self.init(http: SyncHTTP(server: server))
    }

    /// `accessToken`: only when the user is signed in to sync; the server then notes "signed in"
    /// and nothing else about the account.
    public func send(_ request: FeedbackRequest, accessToken: String? = nil) async throws -> FeedbackOutcome {
        var urlRequest = http.request("POST", "feedback", json: try SyncHTTP.encode(request), token: accessToken)
        urlRequest.timeoutInterval = 30
        do {
            _ = try await http.send(urlRequest)
            return .sent
        } catch let error as SyncServerError where error.code == "feedback_delivery_failed" || error.code == "feedback_not_configured" {
            return .saved
        }
    }
}

/// The sheet's words, shared by the Mac and the iPhone.
public enum FeedbackCopy {
    public static let address = "feedback@matilde.page"
    public static let menuTitle = "Send Feedback…"
    public static let title = "Send feedback"
    public static let promise = "This goes straight to Filip. Your notes are never included."
    public static let kindLabel = "Kind"
    public static let messagePlaceholder = "What’s on your mind?"
    public static let emailLabel = "Email for a reply"
    public static let emailPlaceholder = "Optional"
    public static let emailInvalid = "That email address doesn’t look right."
    public static let diagnosticsToggle = "Include app version and device"
    public static let diagnosticsDisclosure = "What gets sent"
    public static let diagnosticsOff = "Only your message and, if you add one, your email."
    public static let send = "Send"
    public static let sending = "Sending…"
    public static let sentTitle = "Thank you"
    public static let sentText = "Your feedback is on its way to Filip."
    public static let savedText = "Your feedback is saved and will reach Filip shortly."
    public static let failedTitle = "Couldn’t send"
    public static let emailInstead = "Email Instead"
    public static let tryAgain = "Try Again"

    public static func tooLong(_ length: Int) -> String {
        "\(length - FeedbackDraft.maxMessageLength) characters over the limit of \(FeedbackDraft.maxMessageLength)."
    }

    /// A short, user-facing reason. Never echoes the server's message.
    public static func failure(_ error: Error) -> String {
        if let server = error as? SyncServerError {
            switch server.code {
            case "rate_limited": return "You’ve sent a lot of feedback in a short while. Try again later, or email instead."
            case "invalid_email": return emailInvalid
            case "upgrade_required": return "Please update Matilde to send feedback, or email instead."
            default: return "Something went wrong on our side. Try again later, or email instead."
            }
        }
        return "Matilde couldn’t reach the server. Check your connection, or email instead."
    }

    public static func mailtoURL(subject: String, body: String) -> URL {
        // Strict encoding: '&', '=', '+' and '#' inside the text must not end the field.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return URL(string: "mailto:\(address)?subject=\(encode(subject))&body=\(encode(body))")!
    }
}
