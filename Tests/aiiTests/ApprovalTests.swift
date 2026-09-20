import Foundation
import Testing

@testable import aii

@Suite struct ApprovalTests {
    @Test func renderingQuotesAndEscapes() {
        #expect(Rendering.render(["ls", "-la", "/tmp"]) == "ls -la /tmp")
        #expect(Rendering.render(["echo", "a b"]) == "echo 'a b'")
        #expect(Rendering.render(["echo", "it's"]) == "echo 'it'\\''s'")
        #expect(Rendering.render(["echo", ""]) == "echo ''")
        #expect(Rendering.render(["echo", "x\ny"]) == "echo 'x\\ny'")
        #expect(Rendering.render(["echo", "\u{1B}[31m"]) == "echo '\\x1B[31m'")
        #expect(Rendering.render(["echo", "\u{85}"]) == "echo '\\x85'")
        #expect(Rendering.render(["echo", "\u{7F}"]) == "echo '\\x7F'")
        #expect(Rendering.render(["echo", "a\u{202E}b"]) == "echo 'a\\u{202E}b'")
        #expect(Rendering.render(["echo", "a\u{200B}b"]) == "echo 'a\\u{200B}b'")
    }

    @Test func renderedOutputHasNoRawControlOrFormatCharacters() {
        let nasty = "a\u{0}\n\r\t\u{1B}\u{85}\u{202E}\u{200B}\u{2028}z"
        #expect(Rendering.isPlain(Rendering.render(["x", nasty])))
    }

    @Test func promptText() {
        let git = cmd("/usr/bin/git", ["status", "--short"])
        let text = Approval.promptText(for: git)
        #expect(text.contains("aii: run this command?\n  git status --short\n"))
        #expect(text.contains("[y] yes once   [a] always allow \"git status\"   [N] no"))
        #expect(text.hasSuffix("> "))

        let rm = Approval.promptText(for: cmd("/bin/rm", ["x"]))
        #expect(!rm.contains("[a]"))

        let local = Approval.promptText(for: cmd("/tmp/tool", ["x"]))
        #expect(local.contains("/tmp/tool x (not in a system directory)"))
        #expect(!local.contains("[a]"))
    }

    private func decide(_ answers: [String], _ command: ResolvedCommand) async -> ApprovalDecision {
        let tty = FakeTTY(answers: answers)
        return await Approver(opener: { tty }, beforePrompt: {}).decide(command)
    }

    @Test func decisions() async {
        let git = cmd("/usr/bin/git", ["status"])
        #expect(await decide(["y"], git) == .once)
        #expect(await decide(["Y"], git) == .once)
        #expect(await decide(["a"], git) == .always)
        #expect(await decide(["n"], git) == .no)
        #expect(await decide([""], git) == .no)
        #expect(await decide(["maybe"], git) == .no)
        #expect(await decide([], git) == .no)  // EOF
    }

    @Test func alwaysRejectedWhenNotOffered() async {
        #expect(await decide(["a"], cmd("/bin/rm", ["x"])) == .no)
        #expect(await decide(["a"], cmd("/tmp/tool")) == .no)
        #expect(await decide(["y"], cmd("/bin/rm", ["x"])) == .once)
    }

    @Test func noTerminal() async {
        let approver = Approver(opener: { nil }, beforePrompt: {})
        #expect(await approver.decide(cmd("/usr/bin/touch", ["x"])) == .noTerminal)
    }

    @Test func promptsAreSerialised() async {
        let tty = FakeTTY(answers: ["n", "n"])
        let approver = Approver(opener: { tty }, beforePrompt: {})
        async let a = approver.decide(cmd("/usr/bin/touch", ["a"]))
        async let b = approver.decide(cmd("/usr/bin/touch", ["b"]))
        _ = await (a, b)
        #expect(tty.events == ["w", "r", "w", "r"])
    }
}
