import Foundation
import Testing

@testable import aii

@Suite struct AllowlistTests {
    @Test func defaultsMatchWithAnyArguments() {
        let ls = cmd("/bin/ls", ["-la", "/tmp"])
        #expect(AllowPolicy.defaults.contains { Allowlist.matches($0, ls) })
        #expect(AllowPolicy.defaults.contains { Allowlist.matches($0, cmd("/usr/bin/df")) })
    }

    @Test func prefixRules() {
        let rule = Rule(argv: ["git", "status"])
        #expect(Allowlist.matches(rule, cmd("/usr/bin/git", ["status"])))
        #expect(Allowlist.matches(rule, cmd("/usr/bin/git", ["status", "--short"])))
        #expect(!Allowlist.matches(rule, cmd("/usr/bin/git", ["push"])))
        #expect(!Allowlist.matches(rule, cmd("/usr/bin/git")))
        #expect(!Allowlist.matches(rule, cmd("/usr/bin/hg", ["status"])))
    }

    @Test func untrustedDirectoryNeverMatches() {
        #expect(!Allowlist.matches(Rule(argv: ["ls"]), cmd("/tmp/evil/ls")))
        #expect(!Allowlist.matches(Rule(argv: ["ls"]), cmd("/usr/bin/sub/ls")))
        #expect(Allowlist.matches(Rule(argv: ["brew"]), cmd("/opt/homebrew/bin/brew", ["list"])))
    }

    @Test func derivePrefixShapes() {
        #expect(Allowlist.derivePrefix(for: cmd("/usr/bin/git")).argv == ["git"])
        #expect(
            Allowlist.derivePrefix(for: cmd("/usr/bin/git", ["status", "--short"])).argv
                == ["git", "status"])
        #expect(
            Allowlist.derivePrefix(for: cmd("/usr/bin/git", ["-C", "/x", "status"])).argv
                == ["git", "-C", "/x", "status"])
    }

    @Test func neverAlwaysAndEligibility() {
        #expect(!Allowlist.alwaysEligible(cmd("/bin/rm", ["x"])))
        #expect(!Allowlist.alwaysEligible(cmd("/bin/sh", ["-c", "x"])))
        #expect(!Allowlist.alwaysEligible(cmd("/tmp/tool", ["x"])))
        #expect(Allowlist.alwaysEligible(cmd("/usr/bin/git", ["status"])))
        #expect(!Allowlist.alwaysEligible(cmd("/usr/bin/git", ["st\natus"])))
    }

    @Test func tokenizer() {
        #expect(Allowlist.tokenize(line: "git status") == ["git", "status"])
        #expect(Allowlist.tokenize(line: "a 'b c' \"d e\" f\\ g") == ["a", "b c", "d e", "f g"])
        #expect(Allowlist.tokenize(line: "x ''") == ["x", ""])
        #expect(Allowlist.tokenize(line: "\"a\\\"b\"") == ["a\"b"])
        #expect(Allowlist.tokenize(line: "'unterminated") == nil)
        #expect(Allowlist.tokenize(line: "trailing\\") == nil)
    }

    @Test func parseConfigSkipsCommentsBlanksAndMalformed() {
        let text = "# comment\n\nls\n  git status  \n'bad\n\"\"\nwc\r\n"
        let parsed = Allowlist.parseConfig(text)
        #expect(parsed.rules == [Rule(argv: ["ls"]), Rule(argv: ["git", "status"]), Rule(argv: ["wc"])])
        #expect(parsed.skippedLines == [5, 6])
    }

    @Test func formatRoundTrips() {
        let rule = Rule(argv: ["git", "-C", "/my dir", "it's", ""])
        #expect(Allowlist.tokenize(line: Allowlist.formatRule(rule)) == rule.argv)
    }

    @Test func resolutionSkipsRelativePathEntries() throws {
        let dir = makeTempDir()
        let tool = dir.appendingPathComponent("mytool")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(Allowlist.resolve(executable: "mytool", args: [], path: ".", cwd: dir.path) == nil)
        #expect(Allowlist.resolve(executable: "mytool", args: [], path: "", cwd: dir.path) == nil)
        #expect(Allowlist.resolve(executable: "mytool", args: [], path: "rel::.", cwd: dir.path) == nil)
        let found = Allowlist.resolve(
            executable: "mytool", args: ["x"], path: ".:\(dir.path)", cwd: "/")
        #expect(found?.path == tool.path)
        #expect(found?.program == "mytool")
        #expect(found?.inTrustedDir == false)
        // path form, relative to cwd
        #expect(Allowlist.resolve(executable: "./mytool", args: [], path: "", cwd: dir.path)?.path == tool.path)
    }

    @Test func resolutionOfSystemProgram() {
        let r = Allowlist.resolve(executable: "ls", args: [], path: "/bin:/usr/bin", cwd: "/")
        #expect(r?.path == "/bin/ls")
        #expect(r?.inTrustedDir == true)
        #expect(Allowlist.resolve(executable: "/bin/ls", args: [], path: "", cwd: "/")?.program == "ls")
        #expect(Allowlist.resolve(executable: "", args: [], path: "/bin", cwd: "/") == nil)
        #expect(Allowlist.resolve(executable: "/bin", args: [], path: "/bin", cwd: "/") == nil)
    }
}
