# AII — Apple Intelligence Interface
## Specification v0.9

AII is a Swift command-line tool that exposes Apple's on-device Foundation
Models framework directly, with no third-party dependencies beyond
`swift-argument-parser`. It is built with Swift Package Manager using a
Swiftly-managed Swift toolchain.

Command execution (`--exec`) is specified in `SPEC-EXEC.md`. This document
covers everything else and owns the CLI surface. If the two disagree about
exec behaviour, `SPEC-EXEC.md` wins.

---

## Requirements

- macOS 26.0 or later (Apple Silicon)
- Swift 6.3 (macOS 26) or Swift 6.4 (macOS 27) via Swiftly
  (`~/.swiftly/bin/swift`) — NOT the Xcode CLT swift
- Foundation Models framework (included in macOS 26)
- Apple Intelligence enabled and model assets fully downloaded on the device

Some APIs need a newer OS than the 26.0 baseline and are used behind
`#available` checks with fallbacks:

| API | Available from | Fallback |
|---|---|---|
| `SystemLanguageModel.contextSize` | macOS 26.4 | 4096 tokens |
| `SystemLanguageModel.tokenCount(for:)` | macOS 26.4 | pre-flight check skipped |
| `SystemLanguageModel.variant` | macOS 27.0 | OS-range label |

### Toolchain note

The Xcode Command Line Tools ship a broken SPM manifest compiler for
macOS 26 and 27. Always build using the Swiftly-managed toolchain:

```bash
which swift      # must show ~/.swiftly/bin/swift
swift --version  # Swift 6.3 (macOS 26) or 6.4 (macOS 27)
```

On macOS 27 the CLT additionally emits a driver flag the Swift 6.3
frontend rejects, so Swift 6.4 is required there. See README for details.

---

## Architecture

```
aii (Swift binary)
  └── FoundationModels framework (macOS 26+, on-device)
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
│       ├── aii.swift           # @main entry point, argument parsing, mode dispatch
│       ├── OneShot.swift       # one-shot mode
│       ├── Interactive.swift   # interactive mode
│       ├── ModelBridge.swift   # availability, sessions, streaming/buffering,
│       │                       #   model info, error mapping, repetition detection
│       ├── Errors.swift        # error type, codes, exit codes, stderr output
│       ├── ExecTool.swift      # run_command tool            (see SPEC-EXEC.md)
│       ├── Allowlist.swift     # rules, matching, config file (see SPEC-EXEC.md)
│       └── Approval.swift      # /dev/tty approval prompt     (see SPEC-EXEC.md)
├── Tests/
│   └── aiiTests/               # Swift Testing
├── Makefile                    # build / install / uninstall / clean
├── SPEC.md
├── SPEC-EXEC.md
├── README.md
└── TODO.md
```

The exec files may be split further (see SPEC-EXEC.md, Section 10).

---

## Operation Modes

AII has two operation modes, determined by how it is invoked.

### 1. One-Shot Mode (default)

Activated when a positional prompt argument, `--file`, or piped stdin is
present. AII processes a single prompt and exits. Output is streamed as
plain text to stdout for easy use in shell pipelines and scripts.

Content can be provided via `--file` or by piping to stdin — these are
mutually exclusive. Using both is an error. Any non-terminal stdin counts as
piped.

If content is provided **without** a prompt, the content itself is used as
the prompt.

```bash
aii "write a haiku about shell scripts"
aii "summarize this" --file journal.md
aii "write a commit message" < diff.patch
cat notes.md | aii "extract the key action items"
cat question.txt | aii
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

The header printed at start (and after `/new`) is:

```
aii — Apple Intelligence Interface
Type /new to reset, /quit to exit.
```

The input prompt is `> `. End of input (Ctrl-D) also ends the session.
A generation error is reported and the session continues; for
`context_exceeded` an extra hint suggests `/new`.

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
| `--model-info` | `-m` | bool | Print context window size, model variant, supported languages, then exit |
| `--exec` | `-x` | bool | Let the model run programs via the `run_command` tool (see SPEC-EXEC.md) |
| `--list-allowed` | | bool | Print the effective exec allowlist and exit (see SPEC-EXEC.md) |
| `--reset-allowed` | | bool | Delete the exec allowlist config file and exit (see SPEC-EXEC.md) |
| `--version` | | bool | Print version and exit |
| `--help` | `-h` | bool | Print help and exit |

Running `aii` with no arguments and a terminal on stdin prints help.

`--list-allowed` and `--reset-allowed` are standalone: combining either with
a prompt, `-i`, `-x`, `-f`, or each other is a `conflicting_input` error.
They are handled before the availability check.

CLI is implemented using **`apple/swift-argument-parser`**.

---

## Mode Behaviour Summary

| Invocation | Mode | Content source | History |
|---|---|---|---|
| `aii "prompt"` | one-shot | none | none |
| `aii "prompt" -f file.md` | one-shot | `--file` | none |
| `aii -f file.md` | one-shot (content is the prompt) | `--file` | none |
| `aii "prompt" < file.md` | one-shot | stdin | none |
| `cat file.md \| aii "prompt"` | one-shot | stdin | none |
| `cat file.md \| aii` | one-shot (content is the prompt) | stdin | none |
| `aii -i` | interactive | none | session-internal |
| `aii -i "system prompt"` | interactive + system prompt | none | session-internal |
| any of the above with `-x` | same, plus `run_command` tool | as above | as above |
| `aii -m` | prints model info | — | — |
| `aii` (terminal, no args) | help | — | — |

---

## Output Format

### One-Shot Mode

Plain streamed text written directly to stdout — no JSONL wrapping. A
trailing newline is written after the response. Suitable for shell
pipelines and script consumption.

### Interactive Mode

Responses rendered directly to the terminal as they stream in.
A blank line is printed after each response before the next prompt.

### Model Info (`--model-info`)

Three plain-text lines:

```
Context window: <n> tokens
Model variant: <name or OS-range label>
Supported languages (<n>): <comma-separated locale list>
```

---

## Streaming & Buffering

AII uses `LanguageModelSession.streamResponse(to:)`, an `AsyncSequence` of
snapshots. `partial.content` is the **cumulative** text generated so far;
AII tracks how many characters it has already emitted and writes only the
new suffix.

Emitted text is buffered internally using a hybrid flush strategy —
whichever threshold is reached first:

- Flush immediately on a **newline** in the generated text
- Flush when the buffer reaches **128 bytes**
- Flush immediately when repetition is detected (see below)

This avoids per-token write overhead while keeping latency low for prose.
`FileHandle.standardOutput.write()` is used for unbuffered writes;
`synchronizeFile()` is called after each flush. The buffer is flushed when
the stream ends.

### Repetition detection

The small model can fall into loops near the end of its context window.
AII watches the output for lines of 40 or more characters that repeat a
recently seen line (window: the last 20 such lines). On detection AII stops
consuming the stream, writes `...` and a newline to stdout, and reports a
`context_exceeded` error (message notes the repetition). One-shot mode then
exits with code 4; interactive mode reports the error and continues.

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

Checked once at startup before any prompt is processed (after the
management flags of SPEC-EXEC.md, which do not need the model).

### Session creation

```swift
// no system prompt
let session = LanguageModelSession()

// with system prompt
let session = LanguageModelSession(
    instructions: Instructions("You are a helpful assistant")
)
```

With `-x` the session is additionally created with the `run_command` tool
and exec instructions (SPEC-EXEC.md, Section 8).

### Streaming generation

```swift
let stream = session.streamResponse(to: prompt)
for try await partial in stream {
    // partial.content is the cumulative text; emit only the new suffix
}
```

### Prompt composition with content

When `content` is provided (via `--file` or stdin) together with a prompt,
the final prompt is:

```
{prompt}

--- CONTENT ---
{content}
--- END CONTENT ---
```

If `content` is empty the prompt is used unchanged. If there is content but
no prompt, the content is the prompt.

### Conversation history

`LanguageModelSession` maintains conversation history internally across
multiple calls to `streamResponse(to:)`. AII does not need to manage
history manually — reusing the same session across turns is sufficient.
`/new` creates a fresh session, discarding history.

### Context window

The window covers input and output combined. AII reads the real figure from
`SystemLanguageModel.default.contextSize` on macOS 26.4+ (4,096 on most
26.x devices, 8,192 on newer 27.x hardware) and falls back to 4,096 on older
systems.

**Pre-flight check (one-shot only).** On macOS 26.4+ AII counts the composed
prompt with `SystemLanguageModel.tokenCount(for:)`. If the prompt alone
already meets or exceeds the context window, AII fails immediately with
`context_exceeded` (exit 4) without invoking the model. This catches only
guaranteed failures: no headroom is reserved for the response, so a prompt
that passes can still overflow during generation, which is handled
reactively (`exceedsContextWindowSize`, repetition detection).

---

## Availability & Error Handling

AII checks Foundation Models availability before processing any prompt.
Running on macOS 26 alone is not sufficient — Apple Intelligence must be
explicitly enabled and model assets fully downloaded.

### Error output format

By default, errors follow established Unix CLI conventions — plain text
to stderr, each line prefixed with the tool name, actionable guidance on
the following line(s):

```
aii: Apple Intelligence is not enabled
aii: enable it in System Settings → Apple Intelligence & Siri
```

When `--json` is passed (for programmatic/scripted use), errors are
written to **stderr** as a single JSONL message instead:

```json
{"error":"unavailable_not_enabled","message":"Apple Intelligence is not enabled\nenable it in System Settings → Apple Intelligence & Siri","detail":"appleIntelligenceNotEnabled","exitCode":3}
```

| Field | Type | Description |
|---|---|---|
| `error` | string | Machine-readable error code (see table below) |
| `message` | string | Human-readable description; may contain `\n` separating guidance |
| `detail` | string | Underlying Swift API value for diagnostics (omitted when absent) |
| `exitCode` | integer | The process exit code for this error |

In `--json` mode stderr carries only JSONL (SPEC-EXEC.md suppresses its
log lines and warnings accordingly).

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

An unrecognised unavailability reason is reported as `internal_error`
(exit 1).

#### Generation errors — exit code 4

| Code | Maps from | Description |
|---|---|---|
| `assets_unavailable` | `GenerationError.assetsUnavailable` | Model assets became unavailable mid-session |
| `guardrail_violation` | `GenerationError.guardrailViolation` | Prompt blocked by safety filters |
| `unsupported_language` | `GenerationError.unsupportedLanguageOrLocale` | Prompt language not supported |
| `context_exceeded` | `GenerationError.exceedsContextWindowSize`, pre-flight token check, or repetition detection | Exceeds the context window (4,096 tokens, or larger where the device reports it) or output looping |
| `rate_limited` | `GenerationError.rateLimited` | Model busy, try again |

#### Input errors — exit code 2

| Code | Description |
|---|---|
| `file_not_found` | Path provided via `--file` does not exist or is unreadable |
| `conflicting_input` | Both `--file` and piped stdin were provided, or a management flag was combined with other flags |

#### Internal errors — exit code 1

| Code | Description |
|---|---|
| `internal_error` | Unexpected error — plain text or detail field contains cause |

### Context Window Note

In interactive mode, history grows with each turn and will eventually
approach the context limit. AII surfaces `context_exceeded` clearly so the
user knows to start fresh with `/new`.

---

## Conversation History

| Mode | History ownership | Persistence |
|---|---|---|
| One-shot | None — stateless | n/a |
| Interactive | `LanguageModelSession` — implicit | Lifetime of process only |

History is accumulated within the session and discarded when the process
exits. There is no persistence across invocations.

---

## Command Execution (summary)

With `-x` / `--exec` the model gets one tool, `run_command`, and can act on
the user's Mac instead of only showing commands. Key properties (full
detail in `SPEC-EXEC.md`):

- **Opt-in.** Without `-x`, nothing changes.
- **No shell.** The tool takes a program and an argument array.
- **Approval.** Commands matching the allowlist run silently; others need
  `y` / `a` (always) / `n` at a `/dev/tty` prompt. Non-interactive
  contexts without a terminal deny anything not allowlisted.
- **Allowlist** lives in `~/.config/aii/allow`; built-in read-only defaults
  apply until that file exists.
- **Limits.** 30 s timeout, 2048-byte output cap.
- **No auto-approve flag** exists, by design.

The same model applies in every mode.

---

## Build

```bash
# ensure Swiftly toolchain is active
which swift        # must be ~/.swiftly/bin/swift
swift --version    # Swift 6.3 (macOS 26) or 6.4 (macOS 27)

# build
swift build -c release

# output binary
.build/release/aii

# tests
swift test

# install to ~/.local/bin
make install
```

---

## Dependencies

| Package | Purpose |
|---|---|
| `apple/swift-argument-parser` >= 1.3.0 | CLI flag and positional argument parsing |

No other dependencies. Foundation Models framework is provided by macOS 26.
Tests use the Swift Testing framework shipped with the toolchain.

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
        ),
        .testTarget(
            name: "aiiTests",
            dependencies: ["aii"]
        )
    ]
)
```

---

## Non-Goals (v0.9)

- No persistent history across invocations
- No support for image or multimodal input
- No LoRA adapter loading
- No tools other than `run_command` (SPEC-EXEC.md); no MCP integration
- No auto-approval of commands, and no sandboxing
- No token usage metadata (deferred — straightforward to add later)
- No Windows or Linux support
- No Xcode IDE required — Swiftly + CLT only
