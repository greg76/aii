# AII — Command Execution
## Specification v0.9 (extends SPEC.md)

Adds an opt-in ability for the model to run programs on the user's Mac,
using the Foundation Models `Tool` API, so `aii` can do what the user asks
instead of only showing a command in a code block.

`SPEC.md` remains the source of truth for the CLI surface, modes, and error
codes. This document owns everything about command execution. If the two
disagree about exec behaviour, this document wins. Section 14 lists the
edits `SPEC.md` needs.

---

## 1. Goals and Non-Goals

### Goals

- **Opt-in.** Without `-x`, behaviour is identical to v0.8: no tool, no
  extra instructions.
- **Safe by default.** Read-only commands run silently; everything else
  needs a human decision.
- **Minimal.** One tool, one allowlist, one config file.
- **One approval model** in every mode: interactive, one-shot, piped stdin,
  `--file`.

### Non-goals

- No auto-approve-everything flag (no `--yes`, in any spelling).
- No sandboxing (`sandbox-exec`, containers, chroot).
- No shell: no pipes, redirects, globbing, `~` expansion, `&&`, subshells.
- No per-directory or per-project allowlists.
- No `XDG_CONFIG_HOME` support; the config path is fixed.
- No raw single-keypress input; answers are read as a line.
- No file-write, network, or other tools. `run_command` is the only tool.

---

## 2. Threat Model

Two things can cause a harmful command:

1. **Prompt injection.** Content the user pipes in, attaches with `--file`,
   or pastes into an interactive session may contain instructions aimed at
   the model. A small on-device model resists this poorly.
2. **Model mistakes.** Hallucinated or over-eager destructive commands.

Not in scope: a malicious user, or an already-compromised local account.

This is a **guardrail, not a sandbox.** Design consequences:

- No shell, so approving a program cannot smuggle in a second command.
- Approvals are argv prefixes, not program names.
- The exact command is always shown, unabbreviated and escaped.
- A human must be reachable, or the command is denied.
- "Always" can only make narrow, non-dangerous prefixes permanent.

---

## 3. CLI

| Flag | Short | Description |
|---|---|---|
| `--exec` | `-x` | Let the model run programs via the `run_command` tool |
| `--list-allowed` | | Print the effective allowlist rules, then exit 0 |
| `--reset-allowed` | | Delete the config file, reverting to built-in defaults, then exit 0 |

- `-x` works with every mode: one-shot, `--file`, piped stdin, `-i`.
- `--list-allowed` and `--reset-allowed` are standalone, like
  `--model-info`. Combining either with a prompt, `-i`, `-x`, `-f`, or each
  other is an input error: `conflicting_input`, exit 2.
- Both management flags are handled **before** the availability check, so
  they work on devices without Apple Intelligence.
- Use flags, not subcommands: a positional prompt would make `aii allow`
  ambiguous.
- `--list-allowed` prints the **effective** rule set, one rule per line,
  headed by its source: `# source: <config path>` if the config file exists,
  otherwise `# source: built-in defaults (no config file)`.
- `--reset-allowed` deletes the config file (no confirmation), prints
  `aii: removed config; using built-in defaults` (or `aii: no config file;
  using built-in defaults` if there was none), exits 0. This discards all
  user rules and any edits made to the seeded defaults.

---

## 4. The Tool

Name: `run_command`. (Deliberately not "bash": there is no shell, and the
name must not invite shell syntax.)

```swift
@Generable
struct Arguments {
    @Guide(description: "Program name or absolute path, e.g. ls or /usr/bin/git")
    var executable: String
    @Guide(description: "Arguments, one array element each. No quoting, wildcards or ~.")
    var arguments: [String]
}
```

The wire contract is the two fields `executable` and `arguments`. The Swift
shape is an implementation detail: if the `@Generable` / `@Guide` macros are
unavailable with the Swiftly toolchain, build an equivalent schema with
`DynamicGenerationSchema` and take `GeneratedContent` as the arguments type.

Tool description (keep short — it costs context tokens):

> Run one program on the user's Mac and return its output. There is no
> shell: pipes, redirects, wildcards and ~ do not work. Paths are relative
> to the current directory.

### Result contract

`call(arguments:)` **never throws** for expected failures. A throw aborts
the whole response in Foundation Models, so every failure is returned as a
string the model can react to. Strings are fixed (tune after first runs):

| Situation | Returned string |
|---|---|
| Ran | `exit <status>` + newline + output |
| Output over cap | output + `\n[output truncated: <total> bytes, showing first 2048]` |
| Timeout | `Terminated: the command exceeded the 30-second time limit.` + newline + partial output |
| User said no | `Denied: the user declined to run this command. Do not retry it.` |
| No terminal | `Denied: this command is not on the allowlist and there is no terminal to ask the user for approval. Do not retry it.` |
| Not found | `Error: executable not found: <name>` |
| Launch failed | `Error: could not launch <name>: <reason>` |
| Empty or NUL-containing executable | `Error: invalid executable` |

Output is stdout and stderr merged in arrival order.

---

## 5. Approval

### 5.1 Decision order

For every tool call:

1. Validate the executable (non-empty, no NUL).
2. **Resolve** it (5.2).
3. **Match** it against rules (5.3). Match → run without asking.
4. No match → open `/dev/tty`. If that fails → return the "No terminal"
   denial.
5. **Prompt** (5.4). `y` → run. `a` (only if eligible, 5.5) → add rule,
   persist, run. Anything else, including empty input and EOF → "User said
   no" denial.

Every command that runs, approved or not, is logged (Section 9).

### 5.2 Resolution

- If `executable` contains `/`: treat it as a path (absolute, or relative
  to the current directory). Do not follow symlinks for the trusted-directory
  check.
- Otherwise: search the inherited `PATH`, **skipping entries that are not
  absolute** (empty, `.`, relative). First executable regular file wins.
- The **program name** is the last path component of the resolved path.
  So `/bin/ls` and `ls` both have program name `ls`.

### 5.3 Matching

A command matches a rule when **all** hold:

1. Rule's first token equals the program name.
2. The resolved path is inside a **trusted directory**:
   `/bin`, `/usr/bin`, `/sbin`, `/usr/sbin`, `/usr/local/bin`,
   `/opt/homebrew/bin`.
3. The rest of the rule is a prefix of the command's arguments.

An executable outside trusted directories (e.g. `./script.sh`, `~/bin/x`)
**never matches**: it always prompts, and "always" is never offered.

There is one effective rule set: the config file if it exists, otherwise
the built-in defaults (5.6). See Section 6.

### 5.4 Prompt

Written to and read from `/dev/tty`, never stdin/stdout:

```
aii: run this command?
  git status --short
  [y] yes once   [a] always allow "git status"   [N] no
>
```

- The `[a]` option is omitted when ineligible (5.5).
- Default is **no**: Enter, unrecognised input, and EOF all mean no.
- The answer is read as a line; the first character, lowercased, decides.
- If the resolved path is outside trusted directories, show the full
  resolved path as the executable and append `(not in a system directory)`.

**Rendering.** The command is displayed in full — never abbreviated — as the
program followed by arguments, POSIX-shell-quoted where needed. Before
display, escape anything that could spoof or hide content:

- control characters (U+0000–U+001F, U+007F, U+0080–U+009F) as `\xNN`
- Unicode bidi and other format characters (e.g. U+202E, U+200B) as
  `\u{XXXX}`
- newlines as `\n`

The same rendering is used for the prompt, the "always allow" text, and log
lines.

### 5.5 "Always" eligibility and prefix derivation

`[a]` is offered only if:

- the resolved path is in a trusted directory, **and**
- the program name is **not** in the never-always set (below).

The stored prefix is derived from the approved command:

| Command shape | Stored prefix |
|---|---|
| No arguments | `[program]` |
| First argument does not start with `-` | `[program, args[0]]` |
| First argument starts with `-` | the full argv (`[program] + args`) |

Examples: `git status --short` → `git status`; `brew list` → `brew list`;
`git -C /x status` → the full argv (a bare `git` is never stored for a
command with a subcommand).

The prompt shows exactly the prefix that will be stored. Same rule in
every mode; it does not depend on how input reached `aii`.

**Never-always set** (hardcoded; for these the prompt is `y/n` only, every
time). Initial list, to be tuned:

| Category | Programs |
|---|---|
| Shells | `sh` `bash` `zsh` `dash` `ksh` `csh` `tcsh` `fish` |
| Interpreters | `python` `python3` `perl` `ruby` `node` `osascript` `swift` |
| Wrappers | `env` `xargs` `sudo` `su` `doas` `nice` `nohup` `time` |
| Can run or rewrite arbitrary things | `find` `sed` `awk` `gawk` `tee` `dd` `make` `npm` `npx` `pip` |
| Network | `curl` `wget` `nc` `ssh` `scp` `rsync` |
| Launchers | `open` `launchctl` |
| Destructive or system-changing | `rm` `rmdir` `mv` `cp` `chmod` `chown` `kill` `killall` `defaults` `diskutil` |

### 5.6 Built-in defaults

The fallback rule set, used **only when no config file exists**, and the
template that seeds the config file when it is first created (Section 6).
Each rule is the program alone, so it auto-approves with **any** arguments.
Every entry must be safe with arbitrary arguments; review the list whenever
it changes.

`ls` `pwd` `cat` `head` `tail` `wc` `date` `whoami` `uname` `df` `du`
`stat` `file` `which` `ps` `uptime` `sw_vers`

Reading files is not treated as a leak: the model runs on-device, and
sending anything onward needs a further command that is not allowlisted.

---

## 6. Config File

Path: `~/.config/aii/allow`

### Relationship to the built-in defaults

There is exactly one effective rule set at any time:

- **No config file:** the built-in defaults (5.6) are the effective rule
  set. Nothing is written to disk just by running with `-x`.
- **Config file exists:** it is authoritative. The built-in defaults are not
  consulted, so an empty file means nothing is auto-approved, and a
  hand-created file replaces the defaults.
- **First "always"** (no file yet): create the file containing the full
  default list **plus** the new rule, so the defaults become visible and
  editable. The write is atomic (temp file, then rename); a crash must not
  leave a file that lacks the defaults.
- A seeded file starts with the header comment
  `# seeded from aii <version> built-in defaults`.
- A seeded file is **not** updated by later releases, even if the built-in
  defaults change. This is a deliberate trade-off for user control. To pick
  up new defaults, run `--reset-allowed` (this also discards user rules).

### Format

```
# seeded from aii 0.9 built-in defaults
# one rule per line: an argv prefix
ls
pwd
cat
head
tail
wc
date
whoami
uname
df
du
stat
file
which
ps
uptime
sw_vers
git status
```

- Plain UTF-8 text. One rule per line: an argv prefix, tokens separated by
  whitespace, POSIX-style single quotes, double quotes, and backslash
  escapes. No variable or tilde expansion.
- Blank lines and lines starting with `#` are ignored.
- Malformed lines are skipped with a warning on stderr (not in `--json`
  mode).
- Loaded **once at startup**, only when `-x` is set. An unreadable file
  → warn and use the built-in defaults.
- On "always": add to the in-memory set immediately (so it applies for the
  rest of an interactive session, and survives `/new`), then persist: if the
  file exists, append one line; if not, seed it as described above.
  Duplicates are not re-added.
- Create `~/.config/aii/` with mode 0700 and the file with mode 0600.
- If persisting fails, warn; the rule still applies for this process.
- **Hand-edited lines are honoured**, including for never-always programs:
  editing the file is the deliberate out-of-band channel. The trusted-
  directory requirement (5.3) still applies.
- The model has no tool that writes this file (see Section 12).

---

## 7. Execution Limits

Same values in every mode. Defined once as constants (`Exec.timeout`,
`Exec.outputCap`) so they are easy to tune.

| Limit | Value |
|---|---|
| Timeout | 30 s wall clock |
| Output cap | 2048 bytes retained |

- **Timeout:** send SIGTERM; if still running after 2 s, SIGKILL. The result
  includes whatever output was captured.
- **Output cap:** keep draining the pipe past the cap (so the child never
  blocks on a full pipe), retain the first 2048 bytes, count the total.
  Decode leniently (invalid UTF-8 becomes replacement characters).
- **Rationale:** 2048 bytes is roughly 500–700 tokens of a 4,096-token
  window that also holds instructions, tool schema, the prompt, and the
  response. Not scaled with `contextSize` in v0.9.
- Child **stdin is `/dev/null`**, so a command can never consume piped
  content or read the user's terminal.
- Working directory and environment are inherited.

---

## 8. Session Instructions

With `-x`, the session is created with the tool and these instructions:

> You can run programs on the user's Mac with the run_command tool. When the
> user asks you to do something or find something out on their machine, call
> the tool instead of showing commands in a code block. There is no shell:
> give the program and its arguments separately; pipes, redirects, wildcards
> and ~ do not work. Run one program per call. Do not run destructive
> commands unless the user explicitly asked for them. If a command is
> denied, do not retry it.

- **One-shot:** these are the whole instructions.
- **Interactive with a system prompt:** the user's system prompt, a blank
  line, then the text above.
- Without `-x`, nothing is added.

Signature change: `ModelBridge.makeSession(systemPrompt:exec:)`.

The one-shot pre-flight token check is unchanged (it only catches
guaranteed failures); overflow caused by tool schema, instructions or tool
output is handled by the existing reactive `context_exceeded` path.

---

## 9. Output Channels

| Channel | Content |
|---|---|
| stdout | Model text only, as today |
| `/dev/tty` | Approval prompt and answer |
| stderr | `aii: $ <command>` log line for every command that runs; warnings |

- The log line uses the same rendering as the prompt. It makes silently
  auto-approved commands visible.
- In `--json` mode, log lines and warnings are **suppressed**, so stderr
  stays pure JSONL. Prompts still go to `/dev/tty`.
- Before writing to the terminal (prompt or log), flush any pending stdout
  buffer so model text and prompts do not interleave mid-line.

---

## 10. Files

New files under `Sources/aii/` (aim for under ~150 lines each; split
further rather than exceed, the list below is the minimum):

| File | Contents |
|---|---|
| `ExecTool.swift` | `RunCommandTool`, `Arguments`, launching, timeout, output cap, result strings |
| `Allowlist.swift` | rule type, built-in defaults, never-always set, trusted dirs, resolution, matching, prefix derivation, config parse/persist |
| `Approval.swift` | `/dev/tty` prompt, command rendering and escaping, tty abstraction |

Shared state (the rule set) lives in an `actor`; `Tool` conformance
requires `Sendable`, and `call` is async. Do not use `nonisolated(unsafe)`.
The stdout buffer needs a small hook or shared sink so the tool can flush it
(Section 9).

Modified: `aii.swift` (flags, dispatch), `ModelBridge.swift` (`makeSession`),
`OneShot.swift` and `Interactive.swift` (pass `exec`, own no logic beyond
that).

---

## 11. Testing

Allowlist and rendering logic is pure; unit-test it with Swift Testing.
Inject the tty opener and the clock/timeout so the no-tty and timeout paths
are testable without a real terminal.

**Unit tests**

- Matching: defaults match with any arguments; prefix rules match longer
  argv; wrong program or wrong subcommand does not; non-trusted directory
  never matches; relative `PATH` entries are skipped.
- Prefix derivation for the three command shapes.
- Never-always programs produce no `[a]` option.
- Config parsing: comments, blank lines, quotes, malformed lines skipped.
- Rule set selection: no file → built-in defaults; existing file (even
  empty) → only its rules; unreadable file → built-in defaults plus a
  warning.
- Seeding: the first "always" writes defaults plus the new rule in one
  atomic write; later "always" answers append.
- Rendering: newline, ESC, C1 controls, bidi override all escaped; quoting
  of spaces.
- Output cap: truncation at 2048 bytes, total count, invalid UTF-8.
- Timeout: a short injected timeout terminates a `sleep`.
- Denial and error strings match Section 4 exactly.

**Manual checks** (in addition to the SPEC.md verification list)

1. `aii -x "how much free disk space do I have?"` → runs `df`/`du`, no
   prompt, log line on stderr.
2. `aii -x "create an empty file named x.txt"` → prompt for `touch`; `n`
   → model reports it was denied; nothing created.
3. Approve `git status` with `a` → `~/.config/aii/allow` is created
   containing the defaults plus `git status`; the next run auto-approves it.
4. `cat notes.md | aii -x "…"` → prompt still appears (via `/dev/tty`);
   `[a]` behaves the same as without the pipe.
5. `aii -x "…" 2>/dev/null` → prompt still visible.
6. Run without a controlling terminal (e.g. from a launchd job) with a
   non-allowlisted request → "No terminal" denial, exit 0.
7. `aii -x --json "…"` → stderr contains only JSONL.
8. `aii --list-allowed` → source line says built-in defaults. After the
   `a` approval above it names the config path and lists the defaults plus
   `git status`. After `aii --reset-allowed` it is back to built-in defaults.
9. `aii -x -i` → `/new` keeps previously approved rules.

---

## 12. Known Limitations

- **Not a sandbox.** An injected but plausible-looking command can still
  reach a tired user; the exact-argv prompt is the mitigation.
- **Some trusted programs execute code from their environment.** For
  example, `git status` or `git diff` in an untrusted repository can run
  configured helpers (fsmonitor, pager). "Always allow git …" trusts the
  repositories you use it in.
- An approved command that can write files could edit the allow file. The
  prompt shows the command, but there is no special protection.
- The inherited environment (which may contain secrets) is visible to
  approved commands.
- Grandchild processes may outlive a timeout kill.
- Small-model tool calling is inconsistent; expect retries and odd argv.
- No `~` or glob expansion, so the model must use explicit paths.
- Seeded defaults are frozen at the version that created the config file;
  later changes to the built-in list do not reach existing users unless they
  reset.

---

## 13. Tune After First Runs

- Timeout (30 s) and output cap (2048 bytes); head-only vs head+tail
  truncation; scaling the cap with `contextSize`.
- The default allowlist and the never-always set.
- The exact denial strings and instruction text; whether the model loops on
  retries after a denial (if so, add a per-turn denial limit).
- Whether same-mode prompts become noisy enough to justify a
  directory-scoped "always".
- Whether stale seeded defaults need a version check, or a refresh command
  that preserves user rules.

---

## 14. Changes Required in SPEC.md (applied in SPEC.md v0.9)

- Sync first: `SPEC.md` is v0.7 while the code is 0.8.0 (`--model-info`,
  `contextSize` detection, pre-flight token check are missing).
- Bump version to 0.9.
- CLI flags table: add `--exec/-x`, `--list-allowed`, `--reset-allowed`.
- Project structure: add `ExecTool.swift`, `Allowlist.swift`,
  `Approval.swift`.
- Non-goals: replace "No tool calling or MCP integration" with "No tools
  other than `run_command` (see SPEC-EXEC.md); no MCP integration".
- Mode summary: note that `-x` applies to all modes.
- Exit codes and error codes: unchanged.
