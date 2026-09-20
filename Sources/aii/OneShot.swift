import Foundation
import FoundationModels

enum OneShot {
    static func run(prompt: String?, filePath: String?, exec: Bool = false) async {
        // 1. detect if stdin is a pipe
        let isPiped = isatty(STDIN_FILENO) == 0

        // 2. conflicting input check
        if filePath != nil && isPiped {
            AIIError(
                error: AIIError.Codes.conflictingInput,
                message: "Cannot use both --file and piped stdin. Use one or the other",
                detail: nil,
                exitCode: 2
            ).fatal()
        }

        // 3. read content
        var content: String? = nil
        if let path = filePath {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                AIIError(
                    error: AIIError.Codes.fileNotFound,
                    message: "Cannot read file: \(path)",
                    detail: nil,
                    exitCode: 2
                ).fatal()
            }
            content = text
        } else if isPiped {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            content = String(data: data, encoding: .utf8)
        }

        // Exec mode: load the rule store once at startup.
        let tool: RunCommandTool? = exec ? await RunCommandTool.makeDefault() : nil
        let session = ModelBridge.makeSession(systemPrompt: nil, exec: tool)
        var buffer = ""
        var lastContentCount = 0
        let detector = RepetitionDetector()

        let finalPrompt: String
        if let content {
            if let prompt {
                // Case 3 & 4: content + prompt. Concatenate as per SPEC.md.
                finalPrompt = ModelBridge.composePrompt(prompt: prompt, content: content)
            } else {
                // Case 2: only content.
                finalPrompt = content
            }
        } else if let prompt {
            // Case 1: only prompt.
            finalPrompt = prompt
        } else {
            return
        }

        // Pre-flight: if the prompt alone already meets or exceeds the context
        // window, fail immediately with a clear error rather than spending time
        // invoking the model only to hit exceedsContextWindowSize (or trigger the
        // repetition detector) partway through generation. `tokenCount(for:)`
        // requires 26.4+; on older SDKs/OS versions this check is skipped and the
        // existing reactive handling below still applies.
        if #available(macOS 26.4, *) {
            if let promptTokens = try? await SystemLanguageModel.default.tokenCount(for: finalPrompt),
                promptTokens >= ModelBridge.contextWindowSize
            {
                ModelBridge.getPreflightContextError(tokenCount: promptTokens).fatal()
            }
        }

        do {
            let stream = session.streamResponse(to: finalPrompt)
            for try await partial in stream {
                let currentContent = partial.content
                // After a tool call the snapshot may restart; begin a new segment.
                if exec && currentContent.count < lastContentCount { lastContentCount = 0 }
                if currentContent.count > lastContentCount {
                    let startIndex = currentContent.index(
                        currentContent.startIndex, offsetBy: lastContentCount)
                    let delta = String(currentContent[startIndex...])
                    if ModelBridge.emit(delta, buffer: &buffer, detector: detector, immediate: exec) {
                        ModelBridge.getRepetitionError().fatal()
                    }
                    lastContentCount = currentContent.count
                }
            }
            ModelBridge.flushBuffer(&buffer)
            ModelBridge.endResponse(immediate: exec)  // Newline after completion
        } catch {
            ModelBridge.getGenerationError(error).fatal()
        }
    }
}
