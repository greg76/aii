import ArgumentParser
import Foundation

@main
struct AII: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "aii",
        abstract: "Apple Intelligence Interface — on-device LLM",
        version: AIIVersion.current
    )

    @Argument(help: "Prompt (one-shot), or system prompt when used with --interactive")
    var prompt: String?

    @Flag(name: [.short, .long], help: "Start interactive conversational mode")
    var interactive: Bool = false

    @Option(name: [.short, .long], help: "File to attach as context (one-shot only)")
    var file: String?

    @Flag(name: [.short, .long], help: "Output errors as JSONL to stderr")
    var json: Bool = false

    @Flag(name: [.customShort("m"), .customLong("model-info")],
          help: "Display information about the on-device model (context size, image input support, supported languages)")
    var modelInfo: Bool = false

    @Flag(name: [.customShort("x"), .long],
          help: "Let the model run programs")
    var exec: Bool = false

    @Flag(help: "Print the effective exec allowlist and exit")
    var listAllowed: Bool = false

    @Flag(help: "Delete the exec allowlist config file and exit")
    var resetAllowed: Bool = false

    mutating func run() async throws {
        AIIError.jsonMode = json

        // Management flags are standalone and handled before the availability
        // check, so they work on devices without Apple Intelligence.
        if listAllowed || resetAllowed {
            if (listAllowed && resetAllowed) || prompt != nil || interactive || exec || file != nil {
                AIIError(
                    error: AIIError.Codes.conflictingInput,
                    message:
                        "--list-allowed and --reset-allowed cannot be combined with a prompt, -i, -x, -f, or each other",
                    detail: nil,
                    exitCode: 2
                ).fatal()
            }
            await manageAllowlist()
            return
        }

        ModelBridge.checkAvailability()

        let isPiped = isatty(STDIN_FILENO) == 0

        if interactive {
            await Interactive.run(systemPrompt: prompt, exec: exec)
        } else if prompt != nil || file != nil || isPiped {
            await OneShot.run(prompt: prompt, filePath: file, exec: exec)
        } else if modelInfo {
            print(ModelBridge.modelInfoDescription())
        } else {
            print(AII.helpMessage())
        }
    }

    private func manageAllowlist() async {
        let store = RuleStore()
        if listAllowed {
            await store.load()
            print(await store.describe())
            return
        }
        do {
            let removed = try await store.reset()
            print(removed
                ? "aii: removed config; using built-in defaults"
                : "aii: no config file; using built-in defaults")
        } catch {
            AIIError(
                error: AIIError.Codes.internalError,
                message: "Cannot remove config file: \(error.localizedDescription)",
                detail: String(describing: error),
                exitCode: 1
            ).fatal()
        }
    }
}
