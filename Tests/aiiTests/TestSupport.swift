import Foundation
import os

@testable import aii

func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("aii-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Scripted terminal: answers are consumed in order; nil answers mean EOF.
final class FakeTTY: TerminalIO {
    private struct State {
        var written = ""
        var answers: [String]
        var events: [String] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(answers: [String]) { state = OSAllocatedUnfairLock(initialState: State(answers: answers)) }

    func write(_ text: String) {
        state.withLock {
            $0.written += text
            $0.events.append("w")
        }
    }

    func readLine() -> String? {
        state.withLock {
            $0.events.append("r")
            return $0.answers.isEmpty ? nil : $0.answers.removeFirst()
        }
    }

    var written: String { state.withLock { $0.written } }
    var events: [String] { state.withLock { $0.events } }
}

final class Collector: Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ s: String) { items.withLock { $0.append(s) } }
    var all: [String] { items.withLock { $0 } }
}

func cmd(_ path: String, _ args: [String] = []) -> ResolvedCommand {
    ResolvedCommand(path: path, args: args)
}
