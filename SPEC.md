# AII — Apple Intelligence Interface
## Specification v0.7

AII is a Swift command-line tool that exposes Apple's on-device Foundation
Models framework directly, with no third-party dependencies beyond
`swift-argument-parser`. It is built with Swift Package Manager using the
Swiftly-managed Swift 6.3 toolchain.

---

## Requirements

- macOS 26.0 or later (Apple Silicon)
- Swift 6.3 via Swiftly (`~/.swiftly/bin/swift`) — NOT the Xcode CLT swift
- Foundation Models framework (included in macOS 26)
- Apple Intelligence enabled and model assets fully downloaded on the device

### Toolchain note

The Xcode Command Line Tools ship a broken SPM manifest compiler for macOS 26.
Always build using the Swiftly-managed toolchain:

```bash
which swift   # must show ~/.swiftly/bin/swift
swift --version  # must show Swift 6.3
```

---

## Architecture

```
aii (Swift binary)
  └── FoundationModels framework (macOS 26, on-device)
```

AII calls the Foundation Models framework directly via Swift — no C bridge,
no third-party runtime dependency. A single self-contained binary.

---

## Project Structure

```
aii/
├── Package.swift
├── Sources/
│   └── aii/
│       ├── main.swift          # entry point, argument parsing, mode dispatch
│       ├── OneShot.swift       # one-shot mode
│       ├── Interactive.swift   # interactive mode
│       ├── ModelBridge.swift   # Foundation Models API, streaming, buffering
│       └── Errors.swift        # error types, codes, stderr output (plain text + --json mode)
└── SPEC.md
```

---

## Operation Modes

AII has two operation modes, determined by how it is invoked.

### 1. One-Shot Mode (default)

Activated when a positional prompt argument is provided. AII processes a
single prompt and exits. Output is streamed as plain text to stdout for
easy use in shell pipelines and scripts.

Content can be provided via `--file` or by piping to stdin — these are
mutually exclusive. Using both is an error.

```bash
aii "write a haiku about shell scripts"
aii "summarize this" --file journal.md
aii "write a commit message" < diff.patch
cat notes.md | aii "extract the key action items"
```

### 2. Interactive Mode (`-i` / `--interactive`)

Activated via the `-i` flag. AII presents a simple conversational terminal
UI. The user types a message and presses Enter; AII relays it to the
Foundation Models framework and streams the response to the terminal.
History is managed internally via `LanguageModelSession` for the lifetime
of the process.

If a positional argument is provided alongside `-i`, it is used as the
system prompt — setting the model's behaviour and persona for the session.

```bash
aii -i
aii -i "You are a terse, no-nonsense coding assistant"
```

#### Interactive Commands

Commands are entered as messages and are not sent to the model:

| Command | Description |
|---|---|
| `/quit` or `/exit` | Terminate the session |
| `/new` | Clear conversation history and reset the screen |

`/new` clears the screen (ANSI escape `\u{1B}[2J\u{1B}[H`), reprints the
AII header, and creates a fresh `LanguageModelSession` — providing implicit
confirmation of the reset without a status message.

---

## CLI Flags

| Flag | Short | Type | Description |
|---|---|---|---|
| `prompt` | | positional string | One-shot prompt, or system prompt when combined with `-i` |
| `--interactive` | `-i` | bool | Interactive conversational mode |
| `--file` | `-f` | string | Path to a file whose contents are attached as context (one-shot only) |
| `--json` | `-j` | bool | Output errors as JSONL to stderr instead of plain text |
| `--model-info` | `-m` | Display information about the on-device model (context size, model variant, supported languages) |
| `--version` | | bool | Print version and exit |
| `--help` | `-h` | bool | Print help and exit |

Running `aii` with no arguments prints help.

CLI is implemented using **`apple/swift-argument-parser`**.

---

## Mode Behaviour Summary

| Invocation | Mode | Content source | History |
|---|---|---|---|
| `aii "prompt"` | one-shot | none | none |
| `aii "prompt" -f file.md` | one-shot | `--file` | none |
| `aii "prompt" < file.md` | one-shot | stdin | none |
| `cat file.md \| aii "prompt"` | one-shot | stdin | none |
| `aii -i` | interactive | none | session-internal |
| `aii -i "system prompt"` | interactive + system prompt | none | session-internal |
| `aii` | help | — | — |

---

## Output Format

### One-Shot Mode

Plain streamed text written directly to stdout — no JSONL wrapping.
Suitable for shell pipelines and script consumption.

### Interactive Mode

Responses rendered directly to the terminal as they stream in.
A blank line is printed after each response before the next prompt.

---

## Streaming & Buffering

AII uses the Foundation Models async streaming API (`LanguageModelSession`
`response(to:)` returning an `AsyncSequence` of partial results).

Chunks are buffered internally using a hybrid flush strategy — whichever
threshold is reached first:

- Flush immediately on a **newline** in the generated text
- Flush when the buffer reaches **128 bytes**

This avoids per-token write overhead while keeping latency low for prose.
`FileHandle.standardOutput.write()` is used for unbuffered writes;
`synchronizeFile()` is called after each flush.

---

## Foundation Models API Usage

### Availability check

```swift
switch SystemLanguageModel.default.availability {
case .available:
    break
case .unavailable(let reason):
    // map reason to error code and exit
}
```

Checked once at startup before any prompt is processed.

### Session creation

```swift
// no system prompt
let session = LanguageModelSession()

// with system prompt
let session = LanguageModelSession(
    instructions: Instructions("You are a helpful assistant")
)
```

### Streaming generation

```swift
let stream = session.streamResponse(to: prompt)
for try await partial in stream {
    // partial.text contains the latest chunk
}
```

### Prompt composition with content

When `content` is provided (via `--file` or stdin), the final prompt is:

```
{prompt}

---
{content}
```

### Conversation history

`LanguageModelSession` maintains conversation history internally across
multiple calls to `streamResponse(to:)`. AII does not need to manage
history manually — reusing the same session across turns is sufficient.
`/new` creates a fresh session, discarding history.

---

## Availability & Error Handling

AII checks Foundation Models availability before processing any prompt.
Running on macOS 26 alone is not sufficient — Apple Intelligence must be
explicitly enabled and model assets fully downloaded.

### Error output format

By default, errors follow established Unix CLI conventions — plain text
to stderr, prefixed with the tool name, actionable guidance on the next
line:

```
aii: Apple Intelligence is not enabled
aii: enable it in System Settings → Apple Intelligence & Siri
```

When `--json` is passed (for programmatic/scripted use), errors are
written to **stderr** as a single JSONL message instead:

```json
{
  "error": "unavailable_not_enabled",
  "message": "Apple Intelligence is not enabled. Enable it in System Settings → Apple Intelligence & Siri.",
  "detail": "SystemLanguageModel.Availability.Reason.appleIntelligenceNotEnabled"
}
```

| Field | Type | Description |
|---|---|---|
| `error` | string | Machine-readable error code (see table below) |
| `message` | string | Human-readable description with actionable guidance |
| `detail` | string | Underlying Swift API value for diagnostics (optional) |

### Exit codes

Exit codes are the primary machine-readable signal in default mode:

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Internal / unexpected error |
| `2` | Bad input (`file_not_found`, `conflicting_input`) |
| `3` | Availability error (Apple Intelligence not ready) |
| `4` | Generation error (guardrail, context, language, rate limit) |

Shell scripts can switch on `$?` to distinguish error categories without
parsing any output.

### Error codes

Used in `--json` mode and as the basis for plain text messages in default mode.

#### Availability errors — exit code 3

| Code | Maps from | Description |
|---|---|---|
| `unavailable_not_supported` | `.unavailable(.deviceNotEligible)` | Device does not support Apple Intelligence |
| `unavailable_not_enabled` | `.unavailable(.appleIntelligenceNotEnabled)` | Apple Intelligence not enabled by user |
| `unavailable_downloading` | `.unavailable(.modelAssetsNotReady)` | Model assets still downloading |

#### Generation errors — exit code 4

| Code | Maps from | Description |
|---|---|---|
| `assets_unavailable` | `GenerationError.assetsUnavailable` | Model assets became unavailable mid-session |
| `guardrail_violation` | `GenerationError.guardrailViolation` | Prompt blocked by safety filters |
| `unsupported_language` | `GenerationError.unsupportedLanguageOrLocale` | Prompt language not supported |
| `context_exceeded` | `GenerationError.exceedsContextWindowSize` | Exceeds 4,096 token context window or detected output looping |
| `rate_limited` | `GenerationError.rateLimited` | Model busy, try again |

#### Input errors — exit code 2

| Code | Description |
|---|---|
| `file_not_found` | Path provided via `--file` does not exist or is unreadable |
| `conflicting_input` | Both `--file` and piped stdin were provided |

#### Internal errors — exit code 1

| Code | Description |
|---|---|
| `internal_error` | Unexpected error — plain text or detail field contains cause |

### Context Window Note

The Foundation Models context window is **4,096 tokens** (input + output
combined). In interactive mode, history grows with each turn and will
eventually approach this limit. AII surfaces `context_exceeded` clearly
so the user knows to start fresh with `/new`.

---

## Conversation History

| Mode | History ownership | Persistence |
|---|---|---|
| One-shot | None — stateless | n/a |
| Interactive | `LanguageModelSession` — implicit | Lifetime of process only |

History is accumulated within the session and discarded when the process
exits. There is no persistence across invocations.

---

## Build

```bash
# ensure Swiftly toolchain is active
which swift        # must be ~/.swiftly/bin/swift
swift --version    # must be Swift 6.3

# build
swift build -c release

# output binary
.build/release/aii
```

---

## Dependencies

| Package | Purpose |
|---|---|
| `apple/swift-argument-parser` >= 1.3.0 | CLI flag and positional argument parsing |

No other dependencies. Foundation Models framework is provided by macOS 26.

### Package.swift

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

---

## Non-Goals (v0.7)

- No persistent history across invocations
- No support for image or multimodal input
- No LoRA adapter loading
- No tool calling or MCP integration
- No token usage metadata (deferred — straightforward to add later)
- No Windows or Linux support
- No Xcode IDE required — Swiftly + CLT only
