import Foundation
import FoundationModels

enum Interactive {
    private static let header = """
        aii — Apple Intelligence Interface
        Type /new to reset, /quit to exit.
        """

    static func run(systemPrompt: String?, exec: Bool = false) async {
        printHeader()
        // Exec mode: load the rule store once; approvals persist across /new.
        let tool: RunCommandTool? = exec ? await RunCommandTool.makeDefault() : nil
        var session = ModelBridge.makeSession(systemPrompt: systemPrompt, exec: tool)

        while true {
            // print prompt prefix
            print("> ", terminator: "")
            FileHandle.standardOutput.synchronizeFile()

            // read input
            guard let line = readLine(strippingNewline: true) else { break }
            let input = line.trimmingCharacters(in: .whitespaces)

            // handle commands
            switch input {
            case "/quit", "/exit":
                exit(0)
            case "/new":
                session = ModelBridge.makeSession(systemPrompt: systemPrompt, exec: tool)
                clearScreen()
                printHeader()
                continue
            case "":
                continue
            default:
                break
            }

            // generate response
            var buffer = ""
            var lastContentCount = 0
            let detector = RepetitionDetector()
            do {
                let stream = session.streamResponse(to: input)
                for try await partial in stream {
                    let currentContent = partial.content
                    // After a tool call the snapshot may restart; begin a new segment.
                    if exec && currentContent.count < lastContentCount { lastContentCount = 0 }
                    if currentContent.count > lastContentCount {
                        let startIndex = currentContent.index(
                            currentContent.startIndex, offsetBy: lastContentCount)
                        let delta = String(currentContent[startIndex...])
                        if ModelBridge.emit(
                            delta, buffer: &buffer, detector: detector, immediate: exec)
                        {
                            ModelBridge.getRepetitionError().report()
                            break
                        }
                        lastContentCount = currentContent.count
                    }
                }
                ModelBridge.flushBuffer(&buffer)
            } catch {
                let error = ModelBridge.getGenerationError(error)
                error.report()
                if error.error == AIIError.Codes.contextExceeded {
                    fputs("aii: use /new to start a fresh conversation\n", stderr)
                }
            }
            ModelBridge.endResponse(immediate: exec)  // blank line after response
        }
    }

    private static func printHeader() {
        print(header)
    }

    private static func clearScreen() {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        FileHandle.standardOutput.synchronizeFile()
    }
}
