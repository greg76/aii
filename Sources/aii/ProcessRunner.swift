import Foundation

enum Exec {
    static let timeout: TimeInterval = 30
    static let outputCap = 2048
    static let killGrace: TimeInterval = 2
}

/// Injectable so tests can use short limits.
struct ExecLimits: Sendable {
    var timeout: TimeInterval = Exec.timeout
    var outputCap: Int = Exec.outputCap
    var killGrace: TimeInterval = Exec.killGrace

    static let standard = ExecLimits()
}

struct ProcessResult: Sendable {
    let status: Int32
    let output: String  // first `outputCap` bytes, decoded leniently
    let totalBytes: Int
    let timedOut: Bool
}

enum ProcessRunner {
    /// Runs one program without a shell. stdin is /dev/null; stdout and stderr
    /// share one pipe; cwd and environment are inherited. Throws only if the
    /// process cannot be launched.
    static func run(path: String, arguments: [String], limits: ExecLimits) async throws
        -> ProcessResult
    {
        let job = Job(cap: limits.outputCap)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            do {
                try job.launch(path: path, arguments: arguments) { continuation.resume(returning: $0) }
                job.armTimeout(limits)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return job.result(status: status)
    }
}

// `@unchecked Sendable`: `Process` and `Pipe` are not Sendable, but they are only
// touched through thread-safe calls (`run`, `kill(pid)`, fd reads), and all
// mutable state below is guarded by `lock`. One Job never leaves this file.
private final class Job: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private let cap: Int
    private var retained = Data()
    private var total = 0
    private var timedOut = false
    private var exited = false
    private var stopLevel = 0  // 0 keep reading, 1 stop when idle, 2 stop now
    private var timeoutTask: Task<Void, Never>?
    private let drained = DispatchSemaphore(value: 0)

    init(cap: Int) { self.cap = cap }

    func launch(path: String, arguments: [String], onExit: @escaping @Sendable (Int32) -> Void)
        throws
    {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [self] finished in
            let status = finished.terminationStatus
            lock.lock()
            exited = true
            stopLevel = max(stopLevel, 1)
            let task = timeoutTask
            lock.unlock()
            task?.cancel()
            // Let the reader drain what the child wrote. A grandchild that keeps
            // the pipe open must not hold us up for long.
            if drained.wait(timeout: .now() + 1) == .timedOut { setStop(2) }
            onExit(status)
        }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            throw error
        }
        try? pipe.fileHandleForWriting.close()  // else the reader never sees EOF
        let fd = pipe.fileHandleForReading.fileDescriptor
        DispatchQueue.global(qos: .userInitiated).async { self.drain(fd) }
    }

    /// SIGTERM after `timeout`, SIGKILL after a further `killGrace`.
    func armTimeout(_ limits: ExecLimits) {
        lock.lock()
        defer { lock.unlock() }
        guard !exited else { return }
        timeoutTask = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(limits.timeout * 1_000_000_000))
            guard !Task.isCancelled, signalIfRunning(SIGTERM, markTimeout: true) else { return }
            try? await Task.sleep(nanoseconds: UInt64(limits.killGrace * 1_000_000_000))
            _ = signalIfRunning(SIGKILL, markTimeout: false)
        }
    }

    func result(status: Int32) -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        return ProcessResult(
            status: status, output: String(decoding: retained, as: UTF8.self),
            totalBytes: total, timedOut: timedOut)
    }

    private func signalIfRunning(_ signal: Int32, markTimeout: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exited else { return false }
        if markTimeout { timedOut = true }
        kill(process.processIdentifier, signal)
        return true
    }

    private func setStop(_ level: Int) {
        lock.lock()
        stopLevel = max(stopLevel, level)
        lock.unlock()
    }

    private func currentStop() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stopLevel
    }

    /// Runs on a dedicated dispatch thread. Keeps draining past the cap so the
    /// child never blocks on a full pipe; retains only the first `cap` bytes.
    private func drain(_ fd: Int32) {
        defer { drained.signal() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while currentStop() < 2 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 {
                if currentStop() >= 1 { return }  // child gone and pipe idle
                continue
            }
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { return }  // EOF: every writer closed
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            lock.lock()
            total += n
            if retained.count < cap {
                retained.append(contentsOf: buffer[0..<min(n, cap - retained.count)])
            }
            lock.unlock()
        }
    }
}
