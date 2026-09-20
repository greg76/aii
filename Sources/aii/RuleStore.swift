import Foundation

/// Owns the effective exec rule set (SPEC-EXEC Section 6).
///
/// - no config file: built-in defaults are effective, nothing is written
/// - config file exists: it is authoritative (even if empty)
/// - first `add` with no file seeds it with defaults + the new rule, atomically
actor RuleStore {
    private(set) var rules: [Rule] = AllowPolicy.defaults
    private var fileExists = false
    private let dir: URL
    private let file: URL
    private let warn: @Sendable (String) -> Void

    static func defaultConfigDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/aii", isDirectory: true)
    }

    init(
        configDir: URL = RuleStore.defaultConfigDir(),
        warn: @escaping @Sendable (String) -> Void = { Diagnostics.warn($0) }
    ) {
        self.dir = configDir
        self.file = configDir.appendingPathComponent("allow")
        self.warn = warn
    }

    func load() {
        guard FileManager.default.fileExists(atPath: file.path) else {
            rules = AllowPolicy.defaults
            fileExists = false
            return
        }
        fileExists = true
        guard let data = FileManager.default.contents(atPath: file.path),
            let text = String(data: data, encoding: .utf8)
        else {
            warn("cannot read \(file.path); using built-in defaults")
            rules = AllowPolicy.defaults
            return
        }
        let parsed = Allowlist.parseConfig(text)
        for line in parsed.skippedLines {
            warn("\(file.path): skipping malformed line \(line)")
        }
        rules = []
        for rule in parsed.rules where !rules.contains(rule) { rules.append(rule) }
    }

    func matches(_ cmd: ResolvedCommand) -> Bool {
        rules.contains { Allowlist.matches($0, cmd) }
    }

    /// Adds to the in-memory set immediately, then persists. A persistence
    /// failure only warns: the rule still applies for this process.
    func add(_ rule: Rule) {
        guard !rules.contains(rule) else { return }
        rules.append(rule)
        do {
            if fileExists {
                try appendLine(Allowlist.formatRule(rule))
            } else {
                try seed(adding: rule)
                fileExists = true
            }
        } catch {
            warn("could not save rule to \(file.path): \(error.localizedDescription)")
        }
    }

    /// Deletes the config file. Returns whether a file was removed.
    func reset() throws -> Bool {
        let existed = FileManager.default.fileExists(atPath: file.path)
        if existed { try FileManager.default.removeItem(at: file) }
        fileExists = false
        rules = AllowPolicy.defaults
        return existed
    }

    /// Text for `--list-allowed`.
    func describe() -> String {
        let source = fileExists ? file.path : "built-in defaults (no config file)"
        return (["# source: \(source)"] + rules.map(Allowlist.formatRule)).joined(separator: "\n")
    }

    // MARK: - Persistence

    private func appendLine(_ line: String) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var out = ""
        if end > 0 {
            // A hand-made file may lack a trailing newline; don't glue lines together.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { out = "\n" }
            _ = try handle.seekToEnd()
        }
        out += line + "\n"
        try handle.write(contentsOf: Data(out.utf8))
    }

    private func seed(adding rule: Rule) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".allow.\(UUID().uuidString).tmp")
        let data = Data(Allowlist.seedText(adding: rule).utf8)
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, file.path) != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
