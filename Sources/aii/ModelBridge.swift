import Foundation
import FoundationModels

enum ModelBridge {
    static func checkAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            let reasonStr = String(describing: reason)
            if reasonStr.contains("deviceNotEligible") {
                AIIError(
                    error: AIIError.Codes.unavailableNotSupported,
                    message: "This device does not support Apple Intelligence.",
                    detail: reasonStr
                ).fatal()
            } else if reasonStr.contains("appleIntelligenceNotEnabled") {
                AIIError(
                    error: AIIError.Codes.unavailableNotEnabled,
                    message:
                        "Apple Intelligence is not enabled. Enable it in System Settings → Apple Intelligence & Siri.",
                    detail: reasonStr
                ).fatal()
            } else if reasonStr.contains("modelAssetsNotReady") {
                AIIError(
                    error: AIIError.Codes.unavailableDownloading,
                    message:
                        "Apple Intelligence model assets are still downloading. Try again shortly.",
                    detail: reasonStr
                ).fatal()
            } else {
                AIIError(
                    error: AIIError.Codes.internalError,
                    message: "Apple Intelligence is unavailable for an unknown reason.",
                    detail: reasonStr
                ).fatal()
            }
        }
    }

    static func makeSession(systemPrompt: String?) -> LanguageModelSession {
        if let prompt = systemPrompt, !prompt.isEmpty {
            return LanguageModelSession(
                instructions: Instructions(prompt)
            )
        }
        return LanguageModelSession()
    }

    static func composePrompt(prompt: String, content: String?) -> String {
        guard let content, !content.isEmpty else { return prompt }
        return "\(prompt)\n\n---\n\(content)"
    }

    static func writeBuffered(_ text: String, buffer: inout String) {
        buffer += text
        let shouldFlush = buffer.contains("\n") || buffer.utf8.count >= 128
        if shouldFlush {
            FileHandle.standardOutput.write(Data(buffer.utf8))
            FileHandle.standardOutput.synchronizeFile()
            buffer = ""
        }
    }

    static func flushBuffer(_ buffer: inout String) {
        if !buffer.isEmpty {
            FileHandle.standardOutput.write(Data(buffer.utf8))
            FileHandle.standardOutput.synchronizeFile()
            buffer = ""
        }
    }

    static func mapGenerationError(_ error: Error) -> Never {
        let errorStr = String(describing: error)
        if errorStr.contains("assetsUnavailable") {
            AIIError(
                error: AIIError.Codes.assetsUnavailable,
                message: "Model assets became unavailable mid-session.", detail: errorStr
            ).fatal()
        } else if errorStr.contains("guardrailViolation") {
            AIIError(
                error: AIIError.Codes.guardrailViolation,
                message: "Prompt blocked by safety filters.", detail: errorStr
            ).fatal()
        } else if errorStr.contains("unsupportedLanguageOrLocale") {
            AIIError(
                error: AIIError.Codes.unsupportedLanguage,
                message: "Prompt language not supported.", detail: errorStr
            ).fatal()
        } else if errorStr.contains("exceedsContextWindowSize") {
            AIIError(
                error: AIIError.Codes.contextExceeded,
                message: "Exceeds 4,096 token context window.", detail: errorStr
            ).fatal()
        } else if errorStr.contains("rateLimited") {
            AIIError(
                error: AIIError.Codes.rateLimited, message: "Model busy, try again.",
                detail: errorStr
            ).fatal()
        }
        AIIError(
            error: AIIError.Codes.internalError, message: error.localizedDescription,
            detail: errorStr
        ).fatal()
    }
}
