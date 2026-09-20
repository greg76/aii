import Foundation
import os

/// Terminal interplay (SPEC-EXEC Section 9).
///
/// A tool call runs in another task while the streaming loop owns the stdout
/// buffer, so the tool cannot flush it. In exec mode the streaming loops
/// therefore skip the 128-byte buffering and write every delta immediately
/// through this object, which remembers whether output ends at the start of a
/// line. Before writing a prompt or log line, the tool asks for
/// `ensureLineStart()`, which emits a newline when model text is mid-line.
/// Newlines are only injected when stdout is a terminal, so piped output is
/// never altered. All writes are serialised by one lock.
final class StdoutState: Sendable {
    static let shared = StdoutState()

    private let atLineStart = OSAllocatedUnfairLock(initialState: true)
    private let isTerminal = isatty(STDOUT_FILENO) != 0

    func write(_ text: String) {
        guard !text.isEmpty else { return }
        atLineStart.withLock { atStart in
            FileHandle.standardOutput.write(Data(text.utf8))
            atStart = text.utf8.last == 0x0A
        }
    }

    func ensureLineStart() {
        guard isTerminal else { return }
        atLineStart.withLock { atStart in
            if !atStart {
                FileHandle.standardOutput.write(Data("\n".utf8))
                atStart = true
            }
        }
    }
}

/// stderr output for exec: log lines and warnings. Both are suppressed with
/// `--json` so stderr stays pure JSONL.
enum Diagnostics {
    static func log(_ message: String) {
        emit("aii: \(message)\n")
    }

    static func warn(_ message: String) {
        emit("aii: warning: \(message)\n")
    }

    private static func emit(_ line: String) {
        guard !AIIError.jsonMode else { return }
        StdoutState.shared.ensureLineStart()
        fputs(line, stderr)
    }
}
