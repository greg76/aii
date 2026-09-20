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
                    message:
                        "Apple Intelligence is not enabled\nenable it in System Settings → Apple Intelligence & Siri",
                    detail: reasonStr,
                    exitCode: 3
                ).fatal()
            } else if reasonStr.contains("modelAssetsNotReady") {
                AIIError(
                    error: AIIError.Codes.unavailableDownloading,
                    message:
                        "Apple Intelligence model assets are still downloading\ntry again shortly",
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

    /// The on-device model's context window, in tokens (input + output combined).
    /// `SystemLanguageModel.contextSize` was added in the 26.4 SDK and reports the
    /// real figure for the current device — 4096 on most 26.x devices, 8192 on
    /// newer 27.x hardware. On older SDKs/OS versions where the property doesn't
    /// exist yet, fall back to the original fixed constant.
    static var contextWindowSize: Int {
        if #available(macOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        return 4096
    }

    /// The on-device model variant/version backing this instance. Added in
    /// the macOS 27 SDK (`SystemLanguageModel.variant`) — Apple ships
    /// distinct model versions tied to OS ranges (26.0–26.3, 26.4, 27.0+),
    /// so this lets callers detect a change without guessing at a
    /// fingerprint. On older SDKs/OS versions there's no queryable variant,
    /// so this falls back to a plain OS-range label instead.
    static var modelVariant: String {
        if #available(macOS 27.0, *) {
            return SystemLanguageModel.default.variant.displayName
        }
        // No `variant` API pre-27.0 — approximate using the OS version range
        // Apple's docs tie to each model generation.
        if #available(macOS 26.4, *) {
            return "AFM macOS 26.4"
        }
        return "AFM macOS 26.0–26.3"
    }

    /// The locales the on-device model supports, as sorted identifier
    /// strings (e.g. "en-US", "ja-JP").
    static var supportedLanguages: [String] {
        SystemLanguageModel.default.supportedLanguages
            .map { $0.maximalIdentifier }
            .sorted()
    }

    static func modelInfoDescription() -> String {
        let languages = supportedLanguages
            .map { $0.replacingOccurrences(of: #"-\w+-"#, with: "-", options: .regularExpression) }
        return [
            "Context window: \(contextWindowSize) tokens",
            "Model variant: \(modelVariant)",
            "Supported languages (\(languages.count)): \(languages.joined(separator: ", "))",
        ].joined(separator: "\n")
    }


    /// With `exec` set, the session gets the `run_command` tool and the exec
    /// instructions (SPEC-EXEC Section 8): the user's system prompt first, a
    /// blank line, then the exec text. Without `exec` behaviour is unchanged.
    static func makeSession(systemPrompt: String?, exec: RunCommandTool? = nil)
        -> LanguageModelSession
    {
        if let exec {
            var text = Exec.instructions + " " + Exec.environmentNote()
            if let prompt = systemPrompt, !prompt.isEmpty {
                text = prompt + "\n\n" + text
            }
            return LanguageModelSession(tools: [exec], instructions: Instructions(text))
        }
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

    static func writeBuffered(
        _ text: String, buffer: inout String, detector: RepetitionDetector? = nil
    ) -> Bool {
        buffer += text

        let detected = detector?.detectRepetition(in: text) ?? false

        let shouldFlush = detected || buffer.contains("\n") || buffer.utf8.count >= 128
        if shouldFlush {
            FileHandle.standardOutput.write(Data(buffer.utf8))
            FileHandle.standardOutput.synchronizeFile()
            buffer = ""
        }

        if detected {
            FileHandle.standardOutput.write(Data("...\n".utf8))
            FileHandle.standardOutput.synchronizeFile()
        }

        return detected
    }

    /// Exec mode: no buffering; every delta goes through `StdoutState` so a tool
    /// running in another task knows whether output ends at a line start.
    static func writeImmediate(_ text: String, detector: RepetitionDetector? = nil) -> Bool {
        let detected = detector?.detectRepetition(in: text) ?? false
        StdoutState.shared.write(text)
        if detected { StdoutState.shared.write("...\n") }
        return detected
    }

    /// Dispatches to buffered or immediate output. Returns true on repetition.
    static func emit(
        _ text: String, buffer: inout String, detector: RepetitionDetector, immediate: Bool
    ) -> Bool {
        immediate
            ? writeImmediate(text, detector: detector)
            : writeBuffered(text, buffer: &buffer, detector: detector)
    }

    /// The newline that ends a response.
    static func endResponse(immediate: Bool) {
        if immediate { StdoutState.shared.write("\n") } else { print() }
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
                message:
                    "Exceeds \(contextWindowSize)-token context window\ntry a shorter input or use /new to reset context in interactive mode",
                detail: errorStr,
                exitCode: 4
            )
        }
 else if errorStr.contains("rateLimited") {
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
            message:
                "Response appears to be repeating — likely exceeded the \(contextWindowSize)-token context window\ntry a shorter input, limit expected response length or use /new to reset in interactive mode",
            detail: "Detected repeating lines in output",
            exitCode: 4
        )
    }

    /// Pre-flight check for one-shot mode: the composed prompt alone (before any
    /// response is generated) already meets or exceeds the context window. This
    /// only catches the "guaranteed to fail" case — it doesn't reserve headroom
    /// for the response, so a prompt that passes this check can still hit
    /// `exceedsContextWindowSize` once output is generated. That remaining case
    /// is still handled reactively via `getGenerationError`/`getRepetitionError`.
    static func getPreflightContextError(tokenCount: Int) -> AIIError {
        return AIIError(
            error: AIIError.Codes.contextExceeded,
            message:
                "Input is \(tokenCount) tokens, exceeding the \(contextWindowSize)-token context window\ntry a shorter input or trim --file/stdin content",
            detail: "Pre-flight token count check failed before calling the model",
            exitCode: 4
        )
    }
}

class RepetitionDetector {
    private var recentFingerprints: [String] = []
    private let maxLines = 20
    private var currentLine = ""

    func detectRepetition(in text: String) -> Bool {
        var detected = false
        for char in text {
            currentLine.append(char)

            if char == "\n" {
                let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
                currentLine = ""

                // Only register lines that are long enough to be meaningful repeats
                if trimmed.count >= 40 {
                    let fp = getFingerprint(for: trimmed)
                    if !recentFingerprints.contains(fp) {
                        recentFingerprints.append(fp)
                        if recentFingerprints.count > maxLines {
                            recentFingerprints.removeFirst()
                        }
                    }
                }
            } else if currentLine.count >= 40 {
                // Proactively check for repetition even before the newline.
                // This ensures we see at least 40 characters of the repeating line.
                let fp = getFingerprint(for: currentLine)
                if recentFingerprints.contains(fp) {
                    detected = true
                    break
                }
            }
        }
        return detected
    }

    private func getFingerprint(for line: String) -> String {
        let chars = Array(line)
        var endPos = chars.count
        let punctuation: Set<Character> = [".", "?", "!"]

        for i in 0..<chars.count {
            if punctuation.contains(chars[i]) {
                // Check if it's followed by whitespace or is the end of the string
                if i + 1 == chars.count || chars[i + 1].isWhitespace {
                    endPos = i + 1
                    break
                }
            }
        }

        // At least 40, at most 60
        let length = min(max(40, endPos), 60)
        let safeLength = min(length, chars.count)
        return String(chars.prefix(safeLength))
    }
}
