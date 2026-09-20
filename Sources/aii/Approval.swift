import Foundation

protocol TerminalIO: Sendable {
    func write(_ text: String)
    /// A full line without its newline; nil on EOF or error (both mean "no").
    func readLine() -> String?
}

/// The controlling terminal, opened read/write. `init?` fails when the process
/// has no controlling terminal (e.g. launchd job).
final class DevTTY: TerminalIO {
    private let fd: Int32

    init?() {
        let f = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard f >= 0 else { return nil }
        fd = f
    }

    deinit { close(fd) }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            offset += n
        }
    }

    func readLine() -> String? {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return nil }  // EOF before a newline: treat as "no"
            if byte == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
    }
}

enum ApprovalDecision: Equatable, Sendable {
    case once, always, no, noTerminal
}

enum Approval {
    /// Program name for trusted-directory commands; full resolved path otherwise.
    static func displayArgv(_ cmd: ResolvedCommand) -> [String] {
        [cmd.inTrustedDir ? cmd.program : cmd.path] + cmd.args
    }

    /// SPEC-EXEC 5.4. `[a]` shows exactly the prefix that would be stored.
    static func promptText(for cmd: ResolvedCommand) -> String {
        var shown = Rendering.render(displayArgv(cmd))
        if !cmd.inTrustedDir { shown += " (not in a system directory)" }
        var options = "[y] yes once"
        if Allowlist.alwaysEligible(cmd) {
            let prefix = Rendering.render(Allowlist.derivePrefix(for: cmd).argv)
            options += "   [a] always allow \"\(prefix)\""
        }
        options += "   [N] no"
        return "aii: run this command?\n  \(shown)\n  \(options)\n> "
    }
}

/// Asks the user. Prompts are serialised through one serial queue, so two tool
/// calls in the same model turn can never interleave their prompts. The queue
/// (a dedicated thread) also keeps the blocking tty read off the cooperative pool.
final class Approver: Sendable {
    private let queue = DispatchQueue(label: "aii.approval")
    private let opener: @Sendable () -> TerminalIO?
    private let beforePrompt: @Sendable () -> Void

    init(
        opener: @escaping @Sendable () -> TerminalIO? = { DevTTY() },
        beforePrompt: @escaping @Sendable () -> Void = { StdoutState.shared.ensureLineStart() }
    ) {
        self.opener = opener
        self.beforePrompt = beforePrompt
    }

    func decide(_ cmd: ResolvedCommand) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.ask(cmd)) }
        }
    }

    private func ask(_ cmd: ResolvedCommand) -> ApprovalDecision {
        guard let tty = opener() else { return .noTerminal }
        beforePrompt()
        tty.write(Approval.promptText(for: cmd))
        guard let answer = tty.readLine() else { return .no }  // EOF: default deny
        switch answer.first?.lowercased() {
        case "y": return .once
        case "a": return Allowlist.alwaysEligible(cmd) ? .always : .no  // only if offered
        default: return .no
        }
    }
}
