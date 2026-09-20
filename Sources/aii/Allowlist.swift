import Foundation

/// An allowlist rule: an argv prefix. The first token is the program name,
/// the rest must be a prefix of the command's arguments (SPEC-EXEC 5.3).
struct Rule: Equatable, Sendable {
    let argv: [String]
}

enum AllowPolicy {
    /// Built-in defaults (SPEC-EXEC 5.6). Each is the program alone, so it
    /// auto-approves with any arguments. Review whenever this list changes.
    static let defaultPrograms = [
        "ls", "pwd", "cat", "head", "tail", "wc", "date", "whoami", "uname",
        "df", "du", "stat", "file", "which", "ps", "uptime", "sw_vers",
    ]
    static let defaults: [Rule] = defaultPrograms.map { Rule(argv: [$0]) }

    /// Programs for which "always" is never offered (SPEC-EXEC 5.5).
    static let neverAlways: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish",
        "python", "python3", "perl", "ruby", "node", "osascript", "swift",
        "env", "xargs", "sudo", "su", "doas", "nice", "nohup", "time",
        "find", "sed", "awk", "gawk", "tee", "dd", "make", "npm", "npx", "pip",
        "curl", "wget", "nc", "ssh", "scp", "rsync",
        "open", "launchctl",
        "rm", "rmdir", "mv", "cp", "chmod", "chown", "kill", "killall",
        "defaults", "diskutil",
    ]

    /// Directories whose executables may match rules (SPEC-EXEC 5.3).
    static let trustedDirs = [
        "/bin", "/usr/bin", "/sbin", "/usr/sbin", "/usr/local/bin", "/opt/homebrew/bin",
    ]
}

struct ResolvedCommand: Sendable {
    let path: String  // resolved executable path (symlinks not followed)
    let program: String  // last path component
    let args: [String]

    init(path: String, args: [String]) {
        self.path = path
        self.program = (path as NSString).lastPathComponent
        self.args = args
    }

    var inTrustedDir: Bool {
        AllowPolicy.trustedDirs.contains((path as NSString).deletingLastPathComponent)
    }
}

/// Pure(ish) allowlist logic: PATH and cwd are parameters; the only
/// filesystem access is the executable-file check in `resolve`.
enum Allowlist {
    /// Lexical normalisation (removes `.`/`..`), deliberately not following symlinks.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { _ = parts.popLast(); continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    /// SPEC-EXEC 5.2. Returns nil when the executable cannot be found.
    static func resolve(executable: String, args: [String], path: String, cwd: String)
        -> ResolvedCommand?
    {
        guard !executable.isEmpty, !executable.contains("\0") else { return nil }
        if executable.contains("/") {
            let absolute = executable.hasPrefix("/") ? executable : cwd + "/" + executable
            let resolved = normalize(absolute)
            return isExecutableFile(resolved) ? ResolvedCommand(path: resolved, args: args) : nil
        }
        for dir in path.split(separator: ":", omittingEmptySubsequences: false) {
            let d = String(dir)
            guard d.hasPrefix("/") else { continue }  // skip empty, ".", relative entries
            let candidate = normalize(d + "/" + executable)
            if isExecutableFile(candidate) {
                return ResolvedCommand(path: candidate, args: args)
            }
        }
        return nil
    }

    /// SPEC-EXEC 5.3: program name equal, trusted directory, rule tail is an argv prefix.
    static func matches(_ rule: Rule, _ cmd: ResolvedCommand) -> Bool {
        guard let first = rule.argv.first, first == cmd.program, cmd.inTrustedDir else {
            return false
        }
        let rest = Array(rule.argv.dropFirst())
        return cmd.args.count >= rest.count && Array(cmd.args.prefix(rest.count)) == rest
    }

    /// SPEC-EXEC 5.5 table.
    static func derivePrefix(for cmd: ResolvedCommand) -> Rule {
        guard let first = cmd.args.first else { return Rule(argv: [cmd.program]) }
        if first.hasPrefix("-") { return Rule(argv: [cmd.program] + cmd.args) }
        return Rule(argv: [cmd.program, first])
    }

    /// "Always" is offered only for trusted-dir programs outside the never-always
    /// set, and only when the prefix survives a round trip through the config
    /// file (no control/format characters).
    static func alwaysEligible(_ cmd: ResolvedCommand) -> Bool {
        cmd.inTrustedDir
            && !AllowPolicy.neverAlways.contains(cmd.program)
            && derivePrefix(for: cmd).argv.allSatisfy(Rendering.isPlain)
    }
}
