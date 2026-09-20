# AII Implementation Prompt
## v0.9 — Command execution (`--exec`)

Add opt-in command execution to `aii`, an existing Swift command-line tool
(currently v0.8.0) that calls Apple's on-device Foundation Models framework.

This is an **incremental change to a working codebase, not a rewrite.**

Before writing any code, read in full, in this order:

1. `SPEC.md` — the CLI surface and existing behaviour
2. `SPEC-EXEC.md` — the exec subsystem (wins on anything about exec)
3. The existing sources: `aii.swift`, `ModelBridge.swift`, `OneShot.swift`,
   `Interactive.swift`, `Errors.swift`

The specs are the source of truth. Do not modify `SPEC.md` or
`SPEC-EXEC.md`; if you find a problem in them, work around it sensibly and
record it in your final report.

---

## Environment

- macOS 26+ (Apple Silicon), Foundation Models available, Apple Intelligence
  enabled
- Swift via Swiftly: 6.3 on macOS 26, 6.4 on macOS 27
- **Do not use `/usr/bin/swift` or the Xcode CLT swift.** Always use the
  Swiftly toolchain (`~/.swiftly/bin/swift`)
- No Xcode IDE. Use `swift build` and `swift test` only

```bash
which swift          # must show ~/.swiftly/bin/swift
swift --version
```

---

## Ground Rules

- **Existing behaviour without `-x` must not change:** same output, same
  errors, same exit codes.
- Match the existing style: enum namespaces with static functions,
  `AIIError` for reported errors. Do not reformat or restructure existing
  code beyond what the change needs.
- New files: aim for under ~150 lines each; split rather than exceed. Name
  any extra files sensibly and list them in your report.
- **Never** run commands through a shell (`/bin/sh -c`, `zsh -c`).
- **Never** add a `--yes` or any auto-approve flag or environment variable.
- `Tool.call` **never throws** for expected failures; it returns the fixed
  strings from SPEC-EXEC Section 4.
- Errors and diagnostics go to stderr, the model's response to stdout,
  approval prompts to `/dev/tty`. Never mix them.
- Default to deny: anything unexpected in the approval path means "not
  approved".
- Do not use `nonisolated(unsafe)` or `@unchecked Sendable` unless you add a
  comment explaining why it is safe.

---

## Step 0 — Baseline and API Spike

**0a. Baseline.** Before changing anything:

```bash
swift build -c release
```

Note that `Package.swift` currently has **no test target**, although
`Tests/aiiTests/aiiTests.swift` exists. Add the `.testTarget` exactly as in
the `Package.swift` snippet in `SPEC.md`, then confirm `swift test` runs
the placeholder test. Record baseline results.

**0b. Read the real API.** Foundation Models is new; do not assume method
names. Find and read the interface for `Tool`, `LanguageModelSession`'s
initializers (the one taking `tools:` and `instructions:`), `@Generable`,
`@Guide`, `GeneratedContent`, `GenerationSchema`, and
`DynamicGenerationSchema`:

```bash
find /Library/Developer/CommandLineTools/SDKs \
  -path "*FoundationModels*" -name "*.swiftinterface" 2>/dev/null | head
```

**0c. Macro spike.** The `@Generable` and `@Guide` macros may not be
available to the Swiftly toolchain, because their implementation plugin
normally ships with Apple's toolchain. In a throwaway file, define a minimal
`Tool` with a `@Generable struct Arguments { var executable: String;
var arguments: [String] }` and compile it. Then decide, in this order:

1. It compiles → use the macros.
2. Macro plugin not found → try pointing the compiler at a plugin
   directory that contains it (e.g. under the CLT, via
   `swiftSettings: [.unsafeFlags(["-plugin-path", "<dir>"])]`). If you do,
   keep it minimal, comment why, and report it.
3. Still failing → build the schema by hand with `DynamicGenerationSchema`
   and take `GeneratedContent` as `Arguments` (SPEC-EXEC Section 4 allows
   this). The wire contract is only the two fields `executable` (string)
   and `arguments` (array of strings).
4. Nothing works → stop and report exactly what failed.

Delete the spike file afterwards.

---

## Step 1 — Allowlist logic (pure, tested)

Implement in `Allowlist.swift` (SPEC-EXEC Sections 5.2, 5.3, 5.5, 5.6 and
the config format of Section 6). Keep these functions **pure and
synchronous**, taking their inputs (PATH, current directory) as parameters
so they are trivially testable. Suggested shape, adapt freely:

```swift
struct Rule: Equatable, Sendable { let argv: [String] }   // an argv prefix

enum AllowPolicy {
    static let defaults: [Rule]            // 5.6
    static let neverAlways: Set<String>    // 5.5
    static let trustedDirs: [String]       // 5.3
}

struct ResolvedCommand: Sendable {
    let path: String        // resolved executable path
    let program: String     // last path component
    let args: [String]
    var inTrustedDir: Bool { get }
}

func resolve(executable: String, args: [String],
             path: String, cwd: String) -> ResolvedCommand?
func matches(_ rule: Rule, _ cmd: ResolvedCommand) -> Bool
func derivePrefix(for cmd: ResolvedCommand) -> Rule       // 5.5 table
func alwaysEligible(_ cmd: ResolvedCommand) -> Bool       // 5.5
func tokenize(line: String) -> [String]?                  // POSIX-style quotes
func parseConfig(_ text: String) -> (rules: [Rule], skippedLines: [Int])
```

Unit tests (Swift Testing) for everything in SPEC-EXEC Section 11's
"Unit tests" list that concerns matching, prefix derivation, never-always,
parsing, and resolution (including skipping relative `PATH` entries).

---

## Step 2 — Rule store and persistence

Implement an `actor` (in `Allowlist.swift` or a new file) that owns the
effective rule set at runtime:

- `load()` per SPEC-EXEC Section 6: no file → built-in defaults; file
  exists → only its rules (an empty file means nothing auto-approved);
  unreadable → defaults plus a stderr warning.
- `add(_ rule:)`: add to the in-memory set immediately, then persist. If the
  file exists, append one line. If it does not, **seed it**: header comment
  plus all defaults plus the new rule, written **atomically** (temp file in
  the same directory, then rename). Create the directory `0700` and the file
  `0600`. If persisting fails, warn (stderr, suppressed in `--json`) and keep
  the in-memory rule.
- No duplicate rules.
- `reset()` and `describe()` for the management flags (Step 6).

Inject the config directory URL so tests can use a temp directory. Test:
no file, empty file, seeded first write, append, duplicate, unreadable file,
reset.

---

## Step 3 — Approval (`Approval.swift`)

Per SPEC-EXEC Section 5.4.

- Abstract the terminal:

  ```swift
  protocol TerminalIO: Sendable {
      func write(_ text: String)
      func readLine() -> String?
  }
  ```

  The real implementation opens `/dev/tty` (read and write). The opener is
  injectable (`() -> TerminalIO?`); `nil` means "no terminal". Tests use a
  fake.
- `render(_ argv:) -> String`: shell-quote where needed, escape control
  characters, C1 controls, bidi/format characters, and newlines exactly as
  specified. Show the argv unabbreviated.
- The decision is an enum, e.g. `.once`, `.always`, `.no`. Default is `.no`
  for empty input, unrecognised input, and EOF. `a` is only accepted when
  `[a]` was offered.
- **Serialise prompts.** The model may issue several tool calls in one turn;
  two prompts must never interleave. Use an actor or an equivalent
  serialisation point.

Tests: rendering and escaping cases from SPEC-EXEC Section 11, default-no
behaviour, `a` rejected when not offered, the no-terminal path.

---

## Step 4 — The tool (`ExecTool.swift`)

Implement `run_command` per SPEC-EXEC Sections 4, 5.1 and 7.

- Follow the decision order of 5.1 exactly, using Steps 1–3.
- Launch with `Process` and an explicit `executableURL`; arguments passed as
  an array (no shell). Child stdin is `FileHandle.nullDevice`; stdout and
  stderr share one pipe; working directory and environment inherited.
- **Timeout:** 30 s wall clock; SIGTERM, then SIGKILL after 2 s. Return the
  partial output with the "Terminated" string.
- **Output cap:** retain the first 2048 bytes and count the total. Keep
  draining past the cap so the child never blocks on a full pipe. Decode
  leniently.
- Define the limits as constants in one place (`Exec.timeout`,
  `Exec.outputCap`) and make them injectable for tests.
- Do not block a cooperative-pool thread waiting for the process: use
  `terminationHandler` with a `CheckedContinuation`, and race it against a
  timeout task.
- Log each executed command to stderr as `aii: $ <rendered argv>` unless
  `--json` is set. Return every failure as one of the fixed strings from
  SPEC-EXEC Section 4.

Tests (real processes, injected short limits): `/bin/echo` output and
`exit 0`; a non-zero exit; `/bin/sleep` with a 1 s timeout terminates;
`/usr/bin/yes` with a short timeout exercises cap and timeout together;
executable not found; denial strings match Section 4 exactly.

---

## Step 5 — Wiring

**`ModelBridge.makeSession`** gains an `exec` parameter. With `exec` on, the
session is created with the tool and the instruction text from SPEC-EXEC
Section 8 (verbatim; user system prompt first, blank line, then exec text).
Without `exec`, behaviour is byte-for-byte as today.

**`aii.swift`**

- Add the flags. Note that `.short` would derive `-e` from the property
  name, so declare the short option explicitly:

  ```swift
  @Flag(name: [.customShort("x"), .long],
        help: "Let the model run programs (see SPEC-EXEC.md)")
  var exec: Bool = false
  @Flag(help: "Print the effective exec allowlist and exit")
  var listAllowed: Bool = false
  @Flag(help: "Delete the exec allowlist config file and exit")
  var resetAllowed: Bool = false
  ```

- Dispatch order in `run()`:
  1. set `AIIError.jsonMode`
  2. if `listAllowed` or `resetAllowed`: reject combinations with a prompt,
     `-i`, `-x`, `-f`, or each other (`conflicting_input`, exit 2), run the
     action, exit 0 — **before** `checkAvailability()`
  3. `ModelBridge.checkAvailability()`
  4. existing dispatch, passing `exec` to `Interactive.run` and
     `OneShot.run`
- Bump the version to `0.9.0`.

**`OneShot.swift` / `Interactive.swift`:** pass `exec` through; load the rule
store once at startup when `exec` is set. No other logic changes.

**Terminal interplay.** When stdout is a terminal, model text and
approval/log output must not interleave mid-line (SPEC-EXEC Section 9). The
stdout buffer is currently a local variable in the streaming loop, which a
tool running in another task cannot safely touch. Pick the smallest
approach that works. One suggestion: in exec mode write each delta
immediately (skip the 128-byte buffering) and track "output ends at line
start" in a small lock-guarded, `Sendable` state object that the tool
consults, emitting a leading newline when needed. Explain whichever you
choose in a comment. This only matters when stdout is a terminal.

---

## Step 6 — Management flags

- `--list-allowed`: print `# source: <config path>` if the file exists,
  otherwise `# source: built-in defaults (no config file)`, then the
  effective rules one per line.
- `--reset-allowed`: delete the file (no confirmation) and print
  `aii: removed config; using built-in defaults`, or
  `aii: no config file; using built-in defaults` if there was none.
  Exit 0 in both cases.

---

## Step 7 — Docs

- `README.md`: add `--exec/-x`, `--list-allowed`, `--reset-allowed` to the
  flag table; replace the stale `--max_ctx | -m` row with
  `--model-info | -m`; add a short "Command execution" section (what it
  does, the approval model in three sentences, link to `SPEC-EXEC.md`).
- Leave `TODO.md` alone.

---

## Verification

Do not stop at the first successful compile.

```bash
swift build -c release
swift test
```

Then run everything in the SPEC.md behaviours you can exercise, plus the
manual checks from SPEC-EXEC Section 11:

1. `aii` with no args in a terminal → help; `aii --version` → `aii 0.9.0`
2. Without `-x`, every earlier behaviour is unchanged (one-shot, `--file`,
   piped stdin, `conflicting_input`, `file_not_found`, `-i`, `/new`,
   `/quit`, `-m`, `--json` errors)
3. `aii -x "how much free disk space do I have?"` → runs silently, log line
   on stderr, sensible answer
4. `aii -x "create an empty file named x.txt"` → prompt; `n` → model reports
   the denial; nothing created
5. Approve something with `a` → `~/.config/aii/allow` created with defaults
   plus the new rule; next run auto-approves it
6. `cat notes.md | aii -x "…"` → prompt still appears; behaviour same as
   without the pipe
7. `aii -x "…" 2>/dev/null` → prompt still visible
8. `aii -x --json "…"` → stderr contains only JSONL
9. No controlling terminal, non-allowlisted request → "No terminal" denial
   returned to the model, no hang
10. `aii --list-allowed`, `aii --reset-allowed`, and their conflict cases
11. `aii -x -i` → approvals persist across `/new`

If a manual check cannot be run in your environment (approval prompts need
a real terminal), say so explicitly in the report rather than claiming it
passed.

---

## Swift 6 Concurrency Notes

- `Tool` conformances must be `Sendable`. Keep the tool a struct with
  immutable properties; put mutable state (the rule set, prompt
  serialisation) in actors.
- `Process` and `Pipe` are not `Sendable`: create, use, and finish them
  within one function; do not pass them across tasks.
- Blocking calls (`readDataToEndOfFile`, `waitUntilExit`) do not belong on
  the cooperative pool. Use `readabilityHandler` or a dedicated queue for
  draining, and `terminationHandler` for exit.
- If the compiler reports a concurrency error you do not understand, reason
  through the data flow rather than suppressing it.

---

## Critical Reminders

- Always `~/.swiftly/bin/swift`; never `/usr/bin/swift`
- Read the framework interface before assuming API shape
- `SPEC-EXEC.md` wins on exec; `SPEC.md` wins elsewhere
- No shell, no `--yes`, never throw from `call`, default to deny
- Existing behaviour without `-x` is unchanged
- Prompts to `/dev/tty`, logs to stderr, model text to stdout

---

## Final Report

When done, report:

1. Files added and changed (including any extra files you split out)
2. The Step 0 macro-spike outcome and which schema approach you used
3. Any deviation from the specs, and why
4. Test results (`swift test` output summary) and which manual checks you
   ran versus could not run
5. Open issues or spec problems you noticed
