import Foundation
import Testing

@testable import aii

@Suite struct RuleStoreTests {
    private func store(_ dir: URL, _ warnings: Collector = Collector()) -> RuleStore {
        RuleStore(configDir: dir, warn: { warnings.add($0) })
    }

    private func read(_ dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("allow"), encoding: .utf8)) ?? ""
    }

    @Test func noFileUsesDefaultsAndWritesNothing() async {
        let dir = makeTempDir()
        let s = store(dir)
        await s.load()
        #expect(await s.rules == AllowPolicy.defaults)
        #expect(await s.describe().hasPrefix("# source: built-in defaults (no config file)"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("allow").path))
    }

    @Test func emptyFileMeansNothingAllowed() async throws {
        let dir = makeTempDir()
        try "".write(to: dir.appendingPathComponent("allow"), atomically: true, encoding: .utf8)
        let s = store(dir)
        await s.load()
        #expect(await s.rules.isEmpty)
        #expect(await !s.matches(cmd("/bin/ls")))
        #expect(await s.describe().hasPrefix("# source: \(dir.path)/allow"))
    }

    @Test func firstAddSeedsFileWithDefaults() async throws {
        let dir = makeTempDir().appendingPathComponent("cfg")  // does not exist yet
        let s = store(dir)
        await s.load()
        await s.add(Rule(argv: ["git", "status"]))

        let lines = read(dir).components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("# seeded from aii"))
        for p in AllowPolicy.defaultPrograms { #expect(lines.contains(p)) }
        #expect(lines.contains("git status"))
        #expect(await s.matches(cmd("/usr/bin/git", ["status"])))

        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("allow").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test func laterAddAppendsAndDuplicatesAreIgnored() async {
        let dir = makeTempDir()
        let s = store(dir)
        await s.load()
        await s.add(Rule(argv: ["git", "status"]))
        let before = read(dir)
        await s.add(Rule(argv: ["git", "log"]))
        await s.add(Rule(argv: ["git", "log"]))
        let after = read(dir)
        #expect(after.hasPrefix(before))
        #expect(after == before + "git log\n")
    }

    @Test func appendHandlesMissingTrailingNewline() async throws {
        let dir = makeTempDir()
        try "ls".write(to: dir.appendingPathComponent("allow"), atomically: true, encoding: .utf8)
        let s = store(dir)
        await s.load()
        await s.add(Rule(argv: ["git", "status"]))
        #expect(read(dir) == "ls\ngit status\n")
    }

    @Test func reloadHonoursPersistedRules() async {
        let dir = makeTempDir()
        let first = store(dir)
        await first.load()
        await first.add(Rule(argv: ["git", "status"]))
        let second = store(dir)
        await second.load()
        #expect(await second.matches(cmd("/usr/bin/git", ["status"])))
        #expect(await second.matches(cmd("/bin/ls")))
    }

    @Test func malformedLinesWarn() async throws {
        let dir = makeTempDir()
        try "ls\n'bad\n".write(to: dir.appendingPathComponent("allow"), atomically: true, encoding: .utf8)
        let warnings = Collector()
        let s = store(dir, warnings)
        await s.load()
        #expect(await s.rules == [Rule(argv: ["ls"])])
        #expect(warnings.all.count == 1)
    }

    @Test func unreadableFileFallsBackToDefaultsWithWarning() async throws {
        let dir = makeTempDir()
        // A directory where the file should be: exists, but cannot be read as text.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("allow"), withIntermediateDirectories: true)
        let warnings = Collector()
        let s = store(dir, warnings)
        await s.load()
        #expect(await s.rules == AllowPolicy.defaults)
        #expect(warnings.all.count == 1)
    }

    @Test func resetRemovesFile() async {
        let dir = makeTempDir()
        let s = store(dir)
        await s.load()
        await s.add(Rule(argv: ["git", "status"]))
        #expect((try? await s.reset()) == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("allow").path))
        #expect(await s.rules == AllowPolicy.defaults)
        #expect((try? await s.reset()) == false)
    }
}
