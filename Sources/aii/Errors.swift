import Foundation

struct AIIError: Codable {
    let error: String
    let message: String
    let detail: String?

    enum Codes {
        static let unavailableNotSupported = "unavailable_not_supported"
        static let unavailableNotEnabled = "unavailable_not_enabled"
        static let unavailableDownloading = "unavailable_downloading"
        static let assetsUnavailable = "assets_unavailable"
        static let guardrailViolation = "guardrail_violation"
        static let unsupportedLanguage = "unsupported_language"
        static let contextExceeded = "context_exceeded"
        static let rateLimited = "rate_limited"
        static let fileNotFound = "file_not_found"
        static let conflictingInput = "conflicting_input"
        static let internalError = "internal_error"
    }

    func fatal() -> Never {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(self),
            let json = String(data: data, encoding: .utf8)
        {
            fputs(json + "\n", stderr)
        }
        exit(1)
    }
}
