# AII Implementation Prompt
## v0.6 — Swift + Foundation Models + Swiftly

Implement `aii` — a Swift command-line tool that calls Apple's on-device
Foundation Models framework directly. Read `SPEC.md` in full before writing
any code. The spec is the source of truth; if anything below conflicts with
it, follow the spec.

---

## Environment

- macOS 26.0, Apple Silicon (arm64)
- Swift 6.3 managed by Swiftly (`~/.swiftly/bin/swift`)
- **Do not use `/usr/bin/swift` or the Xcode CLT swift** — always use the
  Swiftly toolchain which is first in PATH
- Foundation Models framework available on this device
- Apple Intelligence is enabled and model assets are present
- No Xcode IDE — build with `swift build` only

Verify before starting:
```bash
which swift          # must show ~/.swiftly/bin/swift
swift --version      # must show Swift 6.3
```

---

## File Structure

Create exactly these files:

```
aii/
├── Package.swift
├── Sources/
│   └── aii/
│       ├── main.swift        # entry point, argument parsing, mode dispatch
│       ├── OneShot.swift     # one-shot mode
│       ├── Interactive.swift # interactive mode
│       ├── ModelBridge.swift # Foundation Models API, streaming, buffering
│       └── Errors.swift      # error types, codes, stderr output
└── SPEC.md                   # do not modify
```

Keep each source file under 150 lines.

---

## Implementation Order

Work through files in this order. Do not skip ahead.

### Step 1: Package.swift

Use exactly this — the `swift-tools-version: 5.9` is required for
compatibility with the Swiftly toolchain's SPM manifest compiler:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "aii",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.3.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "aii",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
```

Verify: `swift package resolve` completes without error before proceeding.

---

### Step 2: Errors.swift

Define the error output type and all error codes from the spec.

```swift
import Foundation

struct AIIError: Codable {
    let error: String
    let message: String
    let detail: String?
}

extension AIIError {
    func fatal() -> Never {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(self),
           let json = String(data: data, encoding: .utf8) {
            fputs(json + "\n", stderr)
        }
        exit(1)
    }
}
```

Define string constants for all error codes listed in the spec:
`unavailable_not_supported`, `unavailable_not_enabled`,
`unavailable_downloading`, `assets_unavailable`, `guardrail_violation`,
`unsupported_language`, `context_exceeded`, `rate_limited`,
`file_not_found`, `conflicting_input`, `internal_error`.

---

### Step 3: ModelBridge.swift

This is the core file. All Foundation Models API calls live here.

**Availability check:**

```swift
import FoundationModels

func checkAvailability() {
    switch SystemLanguageModel.default.availability {
    case .available:
        return
    case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible:
            AIIError(error: "unavailable_not_supported",
                     message: "This device does not support Apple Intelligence.",
                     detail: String(describing: reason)).fatal()
        case .appleIntelligenceNotEnabled:
            AIIError(error: "unavailable_not_enabled",
                     message: "Apple Intelligence is not enabled. Enable it in System Settings → Apple Intelligence & Siri.",
                     detail: String(describing: reason)).fatal()
        case .modelAssetsNotReady:
            AIIError(error: "unavailable_downloading",
                     message: "Apple Intelligence model assets are still downloading. Try again shortly.",
                     detail: String(describing: reason)).fatal()
        @unknown default:
            AIIError(error: "internal_error",
                     message: "Apple Intelligence is unavailable for an unknown reason.",
                     detail: String(describing: reason)).fatal()
        }
    }
}
```

**Session creation:**

```swift
func makeSession(systemPrompt: String?) -> LanguageModelSession {
    if let prompt = systemPrompt, !prompt.isEmpty {
        return LanguageModelSession(
            instructions: Instructions(prompt)
        )
    }
    return LanguageModelSession()
}
```

**IMPORTANT — Foundation Models API surface:**

The Foundation Models framework is new and evolving. Before implementing
`streamResponse`, read the actual framework headers to confirm the exact
method names and types available in the SDK on this device:

```bash
find /Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk \
  -name "*.swiftmodule" -path "*FoundationModels*" 2>/dev/null | head -5

# or inspect the framework directly
ls /System/Library/Frameworks/FoundationModels.framework/
```

The async streaming API is expected to look like one of:

```swift
// option A
let stream = session.streamResponse(to: Prompt(prompt))
for try await partial in stream { ... }

// option B  
let response = try await session.respond(to: prompt)
// with streaming via AsyncSequence property
```

**If you cannot confirm the exact API from headers or documentation,
implement using the synchronous `respond(to:)` API first and note a
TODO for streaming. A working synchronous implementation is better than
a broken streaming one.**

**Prompt composition with content:**

```swift
func composePrompt(prompt: String, content: String?) -> String {
    guard let content, !content.isEmpty else { return prompt }
    return "\(prompt)\n\n---\n\(content)"
}
```

**Buffered streaming output:**

```swift
func writeBuffered(_ text: String, buffer: inout String) {
    buffer += text
    let shouldFlush = buffer.contains("\n") || buffer.utf8.count >= 128
    if shouldFlush {
        FileHandle.standardOutput.write(Data(buffer.utf8))
        FileHandle.standardOutput.synchronizeFile()
        buffer = ""
    }
}

func flushBuffer(_ buffer: inout String) {
    if !buffer.isEmpty {
        FileHandle.standardOutput.write(Data(buffer.utf8))
        FileHandle.standardOutput.synchronizeFile()
        buffer = ""
    }
}
```

**Error mapping from GenerationError:**

```swift
func mapGenerationError(_ error: Error) -> Never {
    // inspect error and map to appropriate AIIError code
    // check for GenerationError cases from the spec
    // fall through to internal_error for unknown errors
    AIIError(error: "internal_error",
             message: error.localizedDescription,
             detail: String(describing: error)).fatal()
}
```

---

### Step 4: OneShot.swift

```swift
import Foundation

func runOneShot(prompt: String, filePath: String?) async {
    // 1. detect if stdin is a pipe
    let isPiped = !isatty(STDIN_FILENO)

    // 2. conflicting input check
    if filePath != nil && isPiped {
        AIIError(error: "conflicting_input",
                 message: "Cannot use both --file and piped stdin. Use one or the other.",
                 detail: nil).fatal()
    }

    // 3. read content
    var content: String? = nil
    if let path = filePath {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            AIIError(error: "file_not_found",
                     message: "Cannot read file: \(path)",
                     detail: nil).fatal()
        }
        content = text
    } else if isPiped {
        content = String(data: FileHandle.standardInput.readDataToEndOfFile(),
                         encoding: .utf8)
    }

    // 4. compose and run
    let finalPrompt = composePrompt(prompt: prompt, content: content)
    let session = makeSession(systemPrompt: nil)
    var buffer = ""

    do {
        // stream response — see ModelBridge.swift for API
        // write each chunk via writeBuffered(_:buffer:)
        // call flushBuffer after stream ends
    } catch {
        mapGenerationError(error)
    }
}
```

---

### Step 5: Interactive.swift

```swift
import Foundation

private let header = """
aii — Apple Intelligence Interface
Type /new to reset, /quit to exit.
"""

func runInteractive(systemPrompt: String?) async {
    printHeader()
    var session = makeSession(systemPrompt: systemPrompt)

    while true {
        // print prompt prefix
        print("> ", terminator: "")
        FileHandle.standardOutput.synchronizeFile()

        // read input
        guard let line = readLine(strippingNewline: true) else { break }
        let input = line.trimmingCharacters(in: .whitespaces)

        // handle commands
        switch input {
        case "/quit", "/exit":
            exit(0)
        case "/new":
            session = makeSession(systemPrompt: systemPrompt)
            clearScreen()
            printHeader()
            continue
        case "":
            continue
        default:
            break
        }

        // generate response
        var buffer = ""
        do {
            // stream response using session
            // write chunks via writeBuffered(_:buffer:)
            // flush when done
        } catch {
            mapGenerationError(error)
        }
        print() // blank line after response
    }
}

private func printHeader() {
    print(header)
}

private func clearScreen() {
    print("\u{1B}[2J\u{1B}[H", terminator: "")
    FileHandle.standardOutput.synchronizeFile()
}
```

---

### Step 6: main.swift

```swift
import ArgumentParser
import Foundation

@main
struct AII: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "aii",
        abstract: "Apple Intelligence Interface — on-device LLM",
        version: "0.6.0"
    )

    @Argument(help: "Prompt (one-shot), or system prompt when used with --interactive")
    var prompt: String?

    @Flag(name: [.short, .long], help: "Start interactive conversational mode")
    var interactive: Bool = false

    @Option(name: [.short, .long], help: "File to attach as context (one-shot only)")
    var file: String?

    mutating func run() async throws {
        checkAvailability()

        if interactive {
            await runInteractive(systemPrompt: prompt)
        } else if let prompt {
            await runOneShot(prompt: prompt, filePath: file)
        } else {
            print(AII.helpMessage())
        }
    }
}
```

---

## Build & Verification

```bash
swift build -c release
```

Run through all verification steps — do not stop at first compile success:

1. `.build/release/aii` → prints help, exits 0
2. `.build/release/aii --version` → prints `aii 0.6.0`, exits 0
3. `.build/release/aii "write a haiku about Swift"` → streams response, exits 0
4. `.build/release/aii "summarize this" --file SPEC.md` → streams summary, exits 0
5. `echo "what is cgo?" | .build/release/aii "answer this"` → streams response, exits 0
6. `.build/release/aii "test" --file SPEC.md < /dev/stdin` → `conflicting_input` error to stderr, exits 1
7. `.build/release/aii "test" --file nonexistent.md` → `file_not_found` error to stderr, exits 1
8. `.build/release/aii -i` → interactive mode, `/new` clears screen, `/quit` exits 0
9. `.build/release/aii -i "you are a pirate"` → system prompt applied

---

## Swift 6 Concurrency Notes

Swift 6 enforces strict concurrency. Common issues to watch for:

- Any value crossing an actor boundary must be `Sendable`
- `LanguageModelSession` may or may not be `Sendable` — check and handle accordingly
- Use `@MainActor` on `main.swift` entry point if needed
- Prefer `async/await` throughout — no Combine, no callbacks
- Do not suppress concurrency warnings with `nonisolated(unsafe)` unless
  you add a comment explaining why it is safe

If the compiler reports a concurrency error you do not understand, stop
and reason through the data flow rather than suppressing it.

---

## Critical Reminders

- **Always use `~/.swiftly/bin/swift`** — never `/usr/bin/swift`
- **Read the framework headers before assuming API shape** — Foundation
  Models is new and the exact method signatures matter
- **Working synchronous first, streaming second** — a working sync
  implementation is better than broken streaming
- **Errors to stderr, response to stdout** — never mix them
- **The spec is the source of truth** — when in doubt, re-read SPEC.md
