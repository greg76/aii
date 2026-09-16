# aii — Apple Intelligence Interface

A Swift command-line tool that exposes Apple's on-device Foundation Models
framework directly from the terminal. No API keys. No cloud. No model
downloads. No Xcode required to build.

---

## Features

- **One-shot mode** — single prompt, streams response, exits
- **Pipe as content** — pipe a file or command output as context, provide the instruction as the argument: `cat notes.md | aii "extract action items"`
- **File attachment** — `--file` attaches a file's contents as context
- **Interactive mode** — conversational UI with session history, `/new` to reset, `/quit` to exit
  - **System prompt** — pass a positional argument with `-i` to set model persona: `aii -i "you are a pirate"`
- **Clean error output** — availability and generation errors written to stderr (optinally also as JSONL with machine-readable codes)

---

## Requirements

- macOS 26.0 or later (Apple Silicon)
- Apple Intelligence enabled in System Settings
- Swift 6.3 or 6.4 via [Swiftly](https://github.com/swiftlang/swiftly) (see Build section)

---

## Usage

```bash
# one-shot
aii "explain what a closure is in Swift"

# with file context
aii "summarize this" --file meeting-notes.md

# with piped content
git diff | aii "write a conventional commit message"
cat error.log | aii "what is causing this error?"

# interactive session
aii -i
aii -i "you are a helpful rubber duck"

# version / help
aii --version
aii --help
```

### CLI Flags

| Flag | Short | Description |
|---|---|---|
| `prompt` | | Positional — one-shot prompt, or system prompt with `-i` |
| `--interactive` | `-i` | Start interactive conversational mode |
| `--file` | `-f` | Attach file contents as context (one-shot only) |
| `--model-info` | `-m` | Show context size, model variant, and supported languages |
| `--version` | | Print version and exit |
| `--help` | `-h` | Print help and exit |

### Interactive Commands

| Command | Description |
|---|---|
| `/new` | Clear history and reset the screen |
| `/quit` or `/exit` | Exit |

---

## Build & Install

### 1. Install Swiftly

The Apple Command Line Tools ship a Swift compiler but their SPM (Swift
Package Manager) has a known manifest compiler bug on macOS 26 and 27 as well.
See [Learning & Gotchas](#learning--gotchas) below. [Swiftly](https://github.com/swiftlang/swiftly)
provides a self-contained Swift toolchain that sidesteps this entirely,
without requiring a full Xcode installation.

```bash
curl -O https://download.swift.org/swiftly/darwin/swiftly.pkg
installer -pkg swiftly.pkg -target CurrentUserHomeDirectory
~/.swiftly/bin/swiftly init
# follow the prompts — adds swiftly to your PATH
```

Then install Swift 6.3 on macOS26, or Swift 6.4 on macOS27

```bash
swiftly install 6.4.0
swiftly use 6.4.0
```

Verify:

```bash
which swift          # should be ~/.swiftly/bin/swift
swift --version      # should show Swift 6.3
```

### 2. Build

```bash
git clone https://github.com/yourusername/aii.git
cd aii
swift build -c release
```

### 3. Install to PATH

```bash
make install
# installs to ~/.local/bin/aii
```

---

## Error Codes

Errors are written to stderr as JSONL:

```json
{"error":"unavailable_not_enabled","message":"Apple Intelligence is not enabled...","detail":"..."}
```

| Code | Meaning |
|---|---|
| `unavailable_not_supported` | Device doesn't support Apple Intelligence |
| `unavailable_not_enabled` | Apple Intelligence not enabled in System Settings |
| `unavailable_downloading` | Model assets still downloading |
| `context_exceeded` | Input exceeds the maximum allowed token context window — use `/new` |
| `guardrail_violation` | Prompt blocked by safety filters |
| `unsupported_language` | Prompt language not supported by the model |
| `rate_limited` | Model busy, try again |
| `file_not_found` | `--file` path doesn't exist or isn't readable |
| `conflicting_input` | Both `--file` and piped stdin provided |

---

## Learning & Gotchas

This project was built as an **agentic coding exercise** — the design,
specification, and architecture were developed collaboratively with
**Claude Sonnet 4.6**, and the implementation was written by
**Gemini 3 Flash Preview**. The process surfaced several non-obvious issues
worth documenting.

### The Swift CLT SPM manifest bug

The biggest obstacle was a broken SPM manifest compiler in the Apple
Command Line Tools on macOS 26. The error looks like this:

```
error: 'aii': Invalid manifest (compiled with: [..."-target",
"arm64-apple-macosx14.0"...])
Undefined symbols for architecture arm64:
  "PackageDescription.Package.__allocating_init(..."
```

The root cause: the CLT's `libPackageDescription` runtime is compiled
against `macosx14.0` and is ABI-incompatible with the Swift 6.x compiler,
regardless of which SDK or `SDKROOT` you point it at. The manifest
compiler and the Swift compiler are separate binaries and don't share the
same ABI in the macOS 26 CLT release.

**The fix:** install [Swiftly](https://github.com/swiftlang/swiftly),
which provides a self-contained Swift toolchain with its own
`libPackageDescription` that matches the compiler. No Xcode needed.

### `swift-tools-version: 5.9`

Counterintuitively, `Package.swift` should declare
`swift-tools-version: 5.9` even when building with Swift 6.3. Using
`6.0` as the tools version triggers the broken CLT manifest path even
when Swiftly is installed, due to how SPM selects its manifest compiler.
`5.9` routes through the compatible path.

### `MacOSX.sdk` symlink

The CLT maintains a `MacOSX.sdk` symlink in
`/Library/Developer/CommandLineTools/SDKs/` that points to the active
SDK. After updating the CLT, verify it points to the current SDK:

```bash
ls -la /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
# should point to MacOSX26.x.sdk, not MacOSX15.x.sdk
```
### Repeated `-target-arch-variant` compile error

After updating to macOS27 and the CLT v27.0.0.0.1788430756 the build broke due
to a new toolchain bug. The host-side compiler invocation SwiftPM uses to build plugins under Xcode 27 is emitting a driver flag that the same-version Swiftly frontend doesn't recognize. ([Skip bumped into the same issue.](https://github.com/skiptools/skip/issues/733)) The resolution is to install Swift 6.4.0, but:

* Swiftly 1.1.3 is broken
  * You can not use `install 6.4.0` it will complain about non existant pkg.
  * You can't also use `self-update`, you need to [reinstall Swiftly](https://www.swift.org/install/macos/), to get to v1.1.4
* Once on Swiftly 1.1.4, you can issue `install 6.4.0` and `use 6.4.0`

If it points to an older SDK, cgo and other C toolchain operations will
use the wrong headers and frameworks. Updating the CLT via
`softwareupdate` fixes the symlink automatically.

### Foundation Models context window

Originally the on-device model has a **4,096 token context window** covering both
input and output combined. This has been expanded on macOS27 devices to 8192.
In interactive mode, history accumulates with each turn and will eventually hit
this limit. Use `/new` to start a fresh session when this happens.

### Prompt quoting

Unlike some CLI tools that accept unquoted multi-word arguments, `aii`
requires the prompt in quotes. This is intentional — the shell expands
special characters (`?`, `*`, `$` etc.) before passing arguments to any
program, so unquoted prompts with punctuation will produce unexpected
results regardless of how the CLI is designed. Quotes are the honest
interface.

---

## Architecture

```
aii (Swift binary)
  └── FoundationModels.framework (macOS 26, on-device)
```

Single self-contained binary. No C bridge, no runtime dependencies beyond
macOS 26. Conversation history is managed internally by
`LanguageModelSession` and discarded when the process exits.

---

## Prior Art — apfel

While working on this project
[apfel](https://github.com/Arthur-Ficial/apfel) got published, a polished
Swift CLI tool that covers a similar ground. Hats off: it's a well-designed,
actively maintained project that also exposes Apple's Foundation Models
from the terminal, and its source code was a useful reference for the
correct Foundation Models API surface.

apfel is a broader tool — it includes an OpenAI-compatible local HTTP
server, a native macOS GUI debug inspector, voice input/output, and
self-discussion mode. If that feature set fits your workflow, use it.

`aii` made sense to complete for a few specific reasons:

- **Instruction + content separation.** `aii` treats piped stdin and
  `--file` as *context attached to a separate instruction*, not as the
  prompt itself. `cat notes.md | aii "extract the action items"` is
  a different interaction model than apfel's single-string approach —
  more composable for scripting and agentic use cases where the
  instruction and the content come from different sources.
- **Minimal footprint.** No GUI, no server, no voice — just a binary
  that reads from stdin and writes to stdout. Easier to audit, easier
  to embed as a subprocess in other tools.
- **JSONL error protocol.** Errors go to stderr as structured JSONL
  with machine-readable codes, making `aii` easier to drive
  programmatically from other applications or shell scripts that need
  to distinguish between availability failures, guardrail violations,
  and context window exhaustion.
- **Learning.** This project was an agentic coding exercise from the
  start. Discovering apfel mid-journey was a useful reality check, not
  a reason to stop — the constraints, design decisions, and toolchain
  lessons documented here have value independent of the end result.
