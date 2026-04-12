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
                    message: "This device does not support Apple Intelligence",
                    detail: reasonStr,
                    exitCode: 3
                ).fatal()
            } else if reasonStr.contains("appleIntelligenceNotEnabled") {
                AIIError(
                    error: AIIError.Codes.unavailableNotEnabled,
                    message: "Apple Intelligence is not enabled\nenable it in System Settings → Apple Intelligence & Siri",
                    detail: reasonStr,
                    exitCode: 3
                ).fatal()
            } else if reasonStr.contains("modelAssetsNotReady") {
                AIIError(
                    error: AIIError.Codes.unavailableDownloading,
                    message: "Apple Intelligence model assets are still downloading\ntry again shortly",
                    detail: reasonStr,
                    exitCode: 3
                ).fatal()
            } else {
                AIIError(
                    error: AIIError.Codes.internalError,
                    message: "Apple Intelligence is unavailable for an unknown reason",
                    detail: reasonStr,
                    exitCode: 1
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
        return "\(prompt)\n\n--- CONTENT ---\n\(content)\n--- END CONTENT ---"
    }

    static func writeBuffered(_ text: String, buffer: inout String, detector: RepetitionDetector? = nil) -> Bool {
        buffer += text
        let hasNewline = buffer.contains("\n")
        let shouldFlush = hasNewline || buffer.utf8.count >= 128
        
        var detectedRepetition = false
        if hasNewline, let detector {
            let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
            // We only check complete lines (those followed by a newline)
            // If the buffer ends with a newline, the last element of split is actually the last line.
            // If it doesn't, the last element is an incomplete line and should not be checked yet.
            let completeLines = buffer.hasSuffix("\n") ? lines : lines.dropLast()
            for line in completeLines {
                if detector.isRepeating(newLine: String(line)) {
                    detectedRepetition = true
                    break
                }
            }
        }

        if shouldFlush {
            FileHandle.standardOutput.write(Data(buffer.utf8))
            FileHandle.standardOutput.synchronizeFile()
            buffer = ""
        }
        return detectedRepetition
    }

    static func flushBuffer(_ buffer: inout String) {
        if !buffer.isEmpty {
            FileHandle.standardOutput.write(Data(buffer.utf8))
            FileHandle.standardOutput.synchronizeFile()
            buffer = ""
        }
    }

    static func getGenerationError(_ error: Error) -> AIIError {
        let errorStr = String(describing: error)
        if errorStr.contains("assetsUnavailable") {
            return AIIError(
                error: AIIError.Codes.assetsUnavailable,
                message: "Model assets became unavailable mid-session",
                detail: errorStr,
                exitCode: 4
            )
        } else if errorStr.contains("guardrailViolation") {
            return AIIError(
                error: AIIError.Codes.guardrailViolation,
                message: "Prompt blocked by safety filters",
                detail: errorStr,
                exitCode: 4
            )
        } else if errorStr.contains("unsupportedLanguageOrLocale") {
            return AIIError(
                error: AIIError.Codes.unsupportedLanguage,
                message: "Prompt language not supported",
                detail: errorStr,
                exitCode: 4
            )
        } else if errorStr.contains("exceedsContextWindowSize") {
            return AIIError(
                error: AIIError.Codes.contextExceeded,
                message: "Exceeds 4,096 token context window\ntry a shorter input or use /new to reset",
                detail: errorStr,
                exitCode: 4
            )
        } else if errorStr.contains("rateLimited") {
            return AIIError(
                error: AIIError.Codes.rateLimited,
                message: "Model busy, try again",
                detail: errorStr,
                exitCode: 4
            )
        }
        return AIIError(
            error: AIIError.Codes.internalError,
            message: error.localizedDescription,
            detail: errorStr,
            exitCode: 1
        )
    }

    static func getRepetitionError() -> AIIError {
        return AIIError(
            error: AIIError.Codes.contextExceeded,
            message: "Response appears to be repeating — context window likely exceeded\ntry a shorter input or use /new to reset",
            detail: "Detected repeating lines in output",
            exitCode: 4
        )
    }
}

class RepetitionDetector {
    private var recentLines: [String] = []
    private let maxLines = 20

    func isRepeating(newLine: String) -> Bool {
        let trimmed = newLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        if recentLines.contains(trimmed) {
            return true
        }
        
        recentLines.append(trimmed)
        if recentLines.count > maxLines {
            recentLines.removeFirst()
        }
        return false
    }
}
