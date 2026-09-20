import Foundation
import Testing

@testable import aii

@Suite struct ExecToolTests {
    private let rules = "echo\nfalse\nsleep\nyes\nprintf\n"

    private func makeTool(
        rules: String? = nil, tty: FakeTTY? = nil, limits: ExecLimits = .standard,
        log: Collector = Collector()
    ) async throws -> (RunCommandTool, RuleStore, URL) {
        let dir = makeTempDir()
        let text = rules ?? self.rules
        try text.write(to: dir.appendingPathComponent("allow"), atomically: true, encoding: .utf8)
        let store = RuleStore(configDir: dir, warn: { _ in })
        await store.load()
        let approver = Approver(opener: { tty }, beforePrompt: {})
        let tool = RunCommandTool(
            store: store, approver: approver, limits: limits,
            environment: ExecEnvironment(path: "/usr/bin:/bin", cwd: dir.path),
            log: { log.add($0) })
        return (tool, store, dir)
    }

    @Test func echoAndLog() async throws {
        let log = Collector()
        let (tool, _, _) = try await makeTool(log: log)
        #expect(await tool.execute(executable: "/bin/echo", arguments: ["hello"]) == "exit 0\nhello\n")
        #expect(log.all == ["$ echo hello"])
    }

    @Test func nonZeroExit() async throws {
        let (tool, _, _) = try await makeTool()
        #expect(await tool.execute(executable: "false", arguments: []) == "exit 1\n")
    }

    @Test func timeoutTerminates() async throws {
        let limits = ExecLimits(timeout: 1, outputCap: 2048, killGrace: 0.5)
        let (tool, _, _) = try await makeTool(limits: limits)
        let start = Date()
        let result = await tool.execute(executable: "/bin/sleep", arguments: ["30"])
        #expect(result == "Terminated: the command exceeded the 1-second time limit.\n")
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func capAndTimeoutTogether() async throws {
        let limits = ExecLimits(timeout: 1, outputCap: 64, killGrace: 0.5)
        let (tool, _, _) = try await makeTool(limits: limits)
        let result = await tool.execute(executable: "/usr/bin/yes", arguments: [])
        #expect(result.hasPrefix("Terminated: the command exceeded the 1-second time limit.\n"))
        #expect(result.contains("[output truncated: "))
        #expect(result.hasSuffix("showing first 64]"))
        #expect(result.contains("y\ny\ny\n"))
    }

    @Test func outputCapTruncates() async throws {
        let (tool, _, _) = try await makeTool()
        let long = String(repeating: "x", count: 3000)
        let result = await tool.execute(executable: "/bin/echo", arguments: [long])
        #expect(result.hasPrefix("exit 0\n" + String(repeating: "x", count: 2048)))
        #expect(result.hasSuffix("\n[output truncated: 3001 bytes, showing first 2048]"))
    }

    @Test func invalidUtf8IsDecodedLeniently() async throws {
        let (tool, _, _) = try await makeTool()
        let result = await tool.execute(executable: "/usr/bin/printf", arguments: ["\\377"])
        #expect(result == "exit 0\n\u{FFFD}")
    }

    @Test func errorStrings() async throws {
        let (tool, _, _) = try await makeTool()
        #expect(await tool.execute(executable: "", arguments: []) == "Error: invalid executable")
        #expect(await tool.execute(executable: "a\0b", arguments: []) == "Error: invalid executable")
        #expect(
            await tool.execute(executable: "no-such-program-xyz", arguments: [])
                == "Error: executable not found: no-such-program-xyz")
    }

    @Test func denialStringsAreExact() {
        #expect(Denial.user == "Denied: the user declined to run this command. Do not retry it.")
        #expect(
            Denial.noTerminal
                == "Denied: this command is not on the allowlist and there is no terminal to ask the user for approval. Do not retry it."
        )
    }

    @Test func userSaysNoAndNothingRuns() async throws {
        let (tool, _, dir) = try await makeTool(tty: FakeTTY(answers: ["n"]))
        let target = dir.appendingPathComponent("x.txt").path
        #expect(await tool.execute(executable: "touch", arguments: [target]) == Denial.user)
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func noTerminalDenies() async throws {
        let (tool, _, dir) = try await makeTool(tty: nil)
        let target = dir.appendingPathComponent("x.txt").path
        #expect(await tool.execute(executable: "touch", arguments: [target]) == Denial.noTerminal)
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func approveOnceRunsWithoutStoringRule() async throws {
        let (tool, store, dir) = try await makeTool(tty: FakeTTY(answers: ["y"]))
        let target = dir.appendingPathComponent("x.txt").path
        #expect(await tool.execute(executable: "touch", arguments: [target]) == "exit 0\n")
        #expect(FileManager.default.fileExists(atPath: target))
        #expect(await !store.rules.contains(Rule(argv: ["touch", target])))
    }

    @Test func alwaysStoresPrefixAndSkipsPromptNextTime() async throws {
        let tty = FakeTTY(answers: ["a"])
        let (tool, store, _) = try await makeTool(tty: tty)
        #expect(await tool.execute(executable: "/usr/bin/stat", arguments: ["-x", "/"]).hasPrefix("exit 0"))
        // stat is not in this test's rules, so it prompted; "-x" starts with "-" → full argv stored
        #expect(await store.rules.contains(Rule(argv: ["stat", "-x", "/"])))
        _ = await tool.execute(executable: "stat", arguments: ["-x", "/", "extra"])
        #expect(tty.events == ["w", "r"])  // second call did not prompt
    }
}
