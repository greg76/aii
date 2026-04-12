import Foundation
import FoundationModels

enum OneShot {
    static func run(prompt: String?, filePath: String?) async {
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

        let session = ModelBridge.makeSession(systemPrompt: nil)
        var buffer = ""
        var lastContentCount = 0

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

        do {
            let stream = session.streamResponse(to: finalPrompt)
            for try await partial in stream {
                let currentContent = partial.content
                if currentContent.count > lastContentCount {
                    let startIndex = currentContent.index(
                        currentContent.startIndex, offsetBy: lastContentCount)
                    let delta = String(currentContent[startIndex...])
                    ModelBridge.writeBuffered(delta, buffer: &buffer)
                    lastContentCount = currentContent.count
                }
            }
            ModelBridge.flushBuffer(&buffer)
            print()  // Newline after completion
        } catch {
            ModelBridge.getGenerationError(error).fatal()
        }
    }
}
