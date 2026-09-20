import Foundation
import FoundationModels

/// Fixed denial strings (SPEC-EXEC Section 4).
enum Denial {
    static let user = "Denied: the user declined to run this command. Do not retry it."
    static let noTerminal =
        "Denied: this command is not on the allowlist and there is no terminal to ask the user for approval. Do not retry it."
}

extension Exec {
    static func environmentNote(
        home: String = NSHomeDirectory(),
        cwd: String = FileManager.default.currentDirectoryPath
    ) -> String {
        "The user's home directory is \(home) and the current directory is \(cwd); use full paths instead of ~."
    }
    /// Session instructions (SPEC-EXEC Section 8), verbatim.
    static let instructions =
        "You can run programs on the user's Mac with the run_command tool. When the user asks you to do something or find something out on their machine, call the tool instead of showing commands in a code block. There is no shell: give the program and its arguments separately; pipes, redirects, wildcards and ~ do not work. Run one program per call. Do not run destructive commands unless the user explicitly asked for them. If a command is denied, do not retry it."
}

struct ExecEnvironment: Sendable {
    let path: String
    let cwd: String

    static var current: ExecEnvironment {
        ExecEnvironment(
            path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            cwd: FileManager.default.currentDirectoryPath)
    }
}

/// The single tool the model gets with `-x`. The schema is built by hand with
/// `DynamicGenerationSchema` so it does not depend on the `@Generable` macro
/// plugin being available to the Swiftly toolchain. Wire contract: `executable`
/// (string) and `arguments` (array of strings).
///
/// `call` never throws for expected failures: a throw aborts the whole response
/// in Foundation Models, so every failure is returned as a string.
struct RunCommandTool: Tool {
    let name = "run_command"
    let description =
        "Run one program on the user's Mac and return its output. There is no shell: pipes, redirects, wildcards and ~ do not work. Paths are relative to the current directory."

    let store: RuleStore
    let approver: Approver
    let limits: ExecLimits
    let environment: ExecEnvironment
    let log: @Sendable (String) -> Void

    init(
        store: RuleStore,
        approver: Approver = Approver(),
        limits: ExecLimits = .standard,
        environment: ExecEnvironment = .current,
        log: @escaping @Sendable (String) -> Void = { Diagnostics.log($0) }
    ) {
        self.store = store
        self.approver = approver
        self.limits = limits
        self.environment = environment
        self.log = log
    }

    /// Loads the rule store once and builds the tool with real terminal/limits.
    static func makeDefault() async -> RunCommandTool {
        let store = RuleStore()
        await store.load()
        return RunCommandTool(store: store)
    }

    static let schema: GenerationSchema = {
        let text = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                .init(
                    name: "executable",
                    description:
                        "Program name or absolute path, e.g. touch or /usr/bin/git. Only the program, never its arguments.",
                    schema: text),
                .init(
                    name: "arguments",
                    description:
                        "Arguments only, one array element each, NOT including the program name. e.g. executable \"ls\" with [\"-la\", \"/tmp\"], or executable \"touch\" with [\"notes.txt\"]. Include every file name, path or URL the command needs. No quoting, wildcards or ~. Never empty strings.",
                    schema: DynamicGenerationSchema(arrayOf: text)),
            ])
        do {
            return try GenerationSchema(root: root, dependencies: [])
        } catch {
            fatalError("invalid run_command schema: \(error)")
        }
    }()

    var parameters: GenerationSchema { Self.schema }

    func call(arguments: GeneratedContent) async throws -> String {
        // fputs("DEBUG raw arguments: \(arguments.jsonString)\n", stderr)   // temporary
        guard let executable = try? arguments.value(String.self, forProperty: "executable") else {
            return "Error: invalid executable"
        }
        let args = (try? arguments.value([String].self, forProperty: "arguments")) ?? []
        return await execute(executable: executable, arguments: args)
    }

    /// Decision order of SPEC-EXEC 5.1.
    func execute(executable: String, arguments: [String]) async -> String {
        guard !executable.isEmpty, !executable.contains("\0") else {
            return "Error: invalid executable"
        }
        // The small model often repeats the program in `arguments` (["df", "/"]).
        // Return a correctable error instead of running a wrong command.
        if let first = arguments.first,
            first == executable || first == (executable as NSString).lastPathComponent
        {
            return
                "Error: arguments must not include the program name. Pass only the arguments, e.g. executable \"df\" with arguments [\"-h\", \"/\"]."
        }
        if arguments.contains(where: { $0.contains("\0") }) {
            return "Error: could not launch \(executable): argument contains a NUL character"
        }
        guard
            let cmd = Allowlist.resolve(
                executable: executable, args: arguments,
                path: environment.path, cwd: environment.cwd)
        else {
            return "Error: executable not found: \(executable)"
        }

        if !(await store.matches(cmd)) {
            switch await approver.decide(cmd) {
            case .once:
                break
            case .always:
                if Allowlist.alwaysEligible(cmd) {
                    await store.add(Allowlist.derivePrefix(for: cmd))
                }
            case .no:
                return Denial.user
            case .noTerminal:
                return Denial.noTerminal
            }
        }

        log("$ " + Rendering.render(Approval.displayArgv(cmd)))
        do {
            let result = try await ProcessRunner.run(
                path: cmd.path, arguments: cmd.args, limits: limits)
            return format(result)
        } catch {
            return "Error: could not launch \(executable): \(error.localizedDescription)"
        }
    }

    private func format(_ r: ProcessResult) -> String {
        var text =
            r.timedOut
            ? "Terminated: the command exceeded the \(Int(limits.timeout))-second time limit.\n"
            : "exit \(r.status)\n"
        text += r.output
        if r.totalBytes > limits.outputCap {
            text += "\n[output truncated: \(r.totalBytes) bytes, showing first \(limits.outputCap)]"
        }
        return text
    }
}
