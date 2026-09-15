import ArgumentParser
import Foundation

@main
struct AII: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "aii",
        abstract: "Apple Intelligence Interface — on-device LLM",
        version: "0.8.0"
    )

    @Argument(help: "Prompt (one-shot), or system prompt when used with --interactive")
    var prompt: String?

    @Flag(name: [.short, .long], help: "Start interactive conversational mode")
    var interactive: Bool = false

    @Option(name: [.short, .long], help: "File to attach as context (one-shot only)")
    var file: String?

    @Flag(name: [.short, .long], help: "Output errors as JSONL to stderr")
    var json: Bool = false

    @Flag(name: [.short, .long], help: "Display the maximum context size supported.")
    var max_ctx: Bool = false

    mutating func run() async throws {
        AIIError.jsonMode = json
        ModelBridge.checkAvailability()

        let isPiped = isatty(STDIN_FILENO) == 0

        if interactive {
            await Interactive.run(systemPrompt: prompt)
        } else if prompt != nil || file != nil || isPiped {
            await OneShot.run(prompt: prompt, filePath: file)
        } else if max_ctx {
            print("Maximum context size: \(ModelBridge.contextWindowSize)")
        } else {
            print(AII.helpMessage())
        }
    }
}
