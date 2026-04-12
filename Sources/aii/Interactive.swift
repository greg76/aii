import Foundation
import FoundationModels

enum Interactive {
    private static let header = """
        aii — Apple Intelligence Interface
        Type /new to reset, /quit to exit.
        """

    static func run(systemPrompt: String?) async {
        printHeader()
        var session = ModelBridge.makeSession(systemPrompt: systemPrompt)

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
                session = ModelBridge.makeSession(systemPrompt: systemPrompt)
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
                    if currentContent.count > lastContentCount {
                        let startIndex = currentContent.index(
                            currentContent.startIndex, offsetBy: lastContentCount)
                        let delta = String(currentContent[startIndex...])
                        if ModelBridge.writeBuffered(delta, buffer: &buffer, detector: detector) {
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
            print()  // blank line after response
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
