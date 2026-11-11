# Session recovery plan

Status: plan, revised 2026-11-11. Nothing here is implemented. Code references
are to `main` at `3c96cb7`.

## Summary

After a crash, kill, force quit or hard reset, the app reopens its windows,
tabs and panes with their working directories and scrollback, and offers to
resume the coding agent that was running in each pane. Programs are not kept
alive; they are restarted.

### Decisions (Helge, 2026-11-11)

| # | Decision | Effect on the plan |
| --- | --- | --- |
| 1 | Restore only after an unclean exit | No restore after a normal quit, no setting. A clean quit deletes the saved state |
| 2 | Trusted resume rules: undecided | One open question, prepared in [Resume rules](#resume-rules) |
| 3 | Use existing defaults, no new knobs | Scrollback is saved up to the existing history and copy limits. No new settings |
| 4 | No encryption | Files are readable by the user only; the environment is not saved. Everything else is plain text |
| 5 | No tmux, no keeping processes alive | Helper phase and tmux alternative removed; see [Considered and not planned](#considered-and-not-planned) |
| 6 | Nothing is implemented yet | Phases 0 to 2 can start now. Phase 3 waits for the answer to the open question |

Consequence of decision 1: a normal macOS restart, shutdown or logout quits
the app cleanly, so nothing is restored after it. Only a crash, a kill, a
force quit, a power loss or a hard reset leads to a restore.

### First version

| Does | Does not |
| --- | --- |
| Restore window frames, tab groups, pane splits and ratios, focus | Restore after ⌘Q, after closing the last window, or after an orderly restart |
| Start a fresh login shell in each pane's last working directory | Keep any process alive, or restore a process's memory |
| Show each pane's saved scrollback, dimmed, above the new shell | Restore the alternate screen, images, selection, find state, per-pane font size |
| Offer to resume a recognised coding agent in its pane | Run any command without a click (unless the open question is answered `auto`) |
| Keep agent knowledge in a data file, none in Swift code | Add settings, encryption, opt-outs or new limits |

### Open question

**After a crash, should agents resume only when you click (per pane, or one
"Resume All"), or automatically for rules you have marked trusted? Answer
`click` or `auto`.** Recommendation: `click`. The material is in
[Resume rules](#resume-rules).

Nothing else blocks phase 0.

## Failure classes

| Class | Event | Outcome in the first version |
| --- | --- | --- |
| a | The app dies, the machine stays up: crash, `kill`, force quit | Children get a hang-up when the PTY closes. Layout, cwd and scrollback are restored; agents are offered for resume |
| b | The machine dies: hard reset, power loss, kernel panic | Same as a, from what was on disk |
| c | A child exits while the app runs | Unchanged from today: the pane stays, titled "Terminal — Finished" |

An orderly restart or logout is a clean quit, not class b.

## Current code

| Area | State at `3c96cb7` | Source |
| --- | --- | --- |
| Saved state | Preferences and the first pane's last grid size (`LaunchGrid`) in `UserDefaults`. No window state, no state files, no AppKit restoration | `Preferences.swift:166-213`, `Session.swift:47-93` |
| Windows | `TerminalWindow` opens at 1000×680 points, centred. The frame is not saved | `main.swift:69-88` |
| Tabs | Native AppKit tabs; each tab is a `TerminalWindow` with `tabbingIdentifier = "HelgeTerminal"` | `main.swift:77-78`, `527-536` |
| Pane tree | The nested `TerminalSplitView` hierarchy is the only model. Splits are binary | `main.swift:232-265`, `298-325`, `675` |
| Pane and window identity | `automationID`: a new UUID per launch, on the pane and on the window | `Canvas.swift:5`, `main.swift:54`, `Automation.swift:26` |
| Pane presentation | Each pane has a `TerminalPanePresentationView` with a header, a find bar, and an optional colour chosen for that pane; the default colour is a preference | `PanePresentation.swift:18-21`, `Preferences.swift:95` |
| Font size | Per pane; ⌘+ and ⌘− change one pane | `Canvas.swift:808-819` |
| Launch | `LaunchSpec { executable, arguments, cwd, launcher }`; default `$SHELL -l`. No per-pane environment | `Session.swift:96-125` |
| Early child | The first window's login shell is spawned at process launch, before the application object exists. The first session adopts it only if its `LaunchSpec` is equal; otherwise the early child is closed | `main.swift:414-419`, `662-666`, `Session.swift:43-94`, `623` |
| Child environment | The app's environment plus `TERM`, `COLORTERM`, `TERM_PROGRAM=HelgeTerminal` and a zsh `ZDOTDIR` shim. `HELGE_TERMINAL_` is the reserved prefix | `Interop/Spawn.c:75-85` |
| cwd | OSC 7, stored by the emulator, delivered in snapshots, inherited by splits | `Emulation/TerminalEmulator.swift:1215`, `Session.swift:325`, `1357` |
| Prompt marks | OSC 133 A/B/C/D set the prompt phase. zsh integration only | `Emulation/TerminalEmulator.swift:1226`, `Resources/Terminal/ShellIntegration/zsh/hooks.zsh` |
| History | Setting 0 to 50,000 rows, default 50,000; the emulator also stops at 64 MiB per session | `Preferences.swift:181-188`, `Emulation/TerminalEmulator.swift:88`, `Settings.swift:201` |
| Text capture | Copy walks text on the session owner in bounded turns, up to 16 MiB | `Emulation/TerminalSelection.swift:32` |
| Find | ⌘F searches history through `HistorySearch`; state is per pane and transient | `FindBar.swift`, `Canvas.swift:822-836` |
| Quit | `applicationShouldTerminate` closes every window and replies when `LiveChildren` reports no child left, 3 s at most. A session sends SIGHUP, then SIGKILL after 2 s | `main.swift:573-594`, `Session.swift:29-37`, `1413-1418` |
| Last window | Closing it quits the app | `main.swift:568` |
| Signals | The app installs no signal handlers; SIGTERM ends it without `applicationShouldTerminate` | grep of `Sources/Terminal` |
| Bundle id | `no.helgesverre.terminal` for the installed app **and** for `dist/Terminal.app`; `just dev` launches the latter with no arguments | `Resources/Terminal/Info.plist:11-12`, `justfile:46-47` |
| Fixture | `Terminal Automation Fixture`, bundle id `no.helgesverre.terminal.automation-fixture` | `tools/Dev/AppleScriptSmoke.swift:23`, `docs/automation.md` |

What this forces:

- A value-type layout model and stable pane ids come first (phase 0).
- The restore decision is made before `EarlyChild.start` (`main.swift:662`),
  or the early shell starts in the wrong directory and is thrown away.
- The bundle id does not separate a development build from the installed app.
  State is tied to where the bundle runs from; see [Location](#location).
- A clean quit takes milliseconds. Nothing is flushed during it.

## Findings

Marks: **V 11-11** verified 2026-11-11 for this revision; **V 11-10** verified
2026-11-10 for the first version of this plan and not rechecked; **U** not
verified.

### cmux

Source and [README](https://github.com/manaflow-ai/cmux/blob/main/README.md)
read at `manaflow-ai/cmux@b4cb6ad` on 2026-11-10; nothing was built or run.
All rows V 11-10.

| Question | Finding |
| --- | --- |
| Live processes | Not kept alive. No PTY-holding daemon. Opt-in `cmux local-tmux` runs panes in a user-owned tmux server |
| What is restored | Layout, working directories, best-effort scrollback, browser URLs |
| Format | One JSON snapshot in `~/Library/Application Support/cmux/`, with a previous generation |
| Cadence | Layout every 8 s without scrollback. Scrollback checkpoints at most every 60 s, only for terminals with new output and only when typing is quiet |
| Scrollback limit | 4,000 lines and 400,000 characters per terminal |
| Scrollback replay | Through the shell: integration `cat`s a temp file. Depends on shell integration |
| Crash detection | A sentinel file with the pid, removed on clean termination |
| Restore trigger | Automatic at launch; skipped when launch arguments are present |
| Agent resume | Hooks record each agent's session id; on restore cmux types a resume command into the new shell. Automatic once hooks are installed |
| Agent knowledge | Compiled into the app: an enum of agents and per-agent argv builders |

Taken: own state file, cheap layout save separate from scrollback checkpoint,
checkpoints gated on new output and quiet, previous generation, sentinel, no
restore with launch arguments. Not taken: agent knowledge in app code, replay
through the shell.

### Other terminals

All rows V 11-10. Sources: [iTerm2](https://iterm2.com/documentation-restoration.html),
[Terminal.app](https://support.apple.com/guide/terminal/change-profiles-window-settings-trmlwindw/mac),
[Ghostty](https://ghostty.org/docs/config/reference#window-save-state),
[kitty](https://sw.kovidgoyal.net/kitty/sessions/),
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect/blob/master/docs/restoring_programs.md),
[zellij](https://zellij.dev/documentation/session-resurrection.html).

| Tool | After the app dies | After a reboot | Taken from it |
| --- | --- | --- | --- |
| iTerm2 | Jobs survive in long-lived servers | Contents return with a "Session Restored" banner | Marker row |
| Terminal.app | Text and layout | Same | — |
| Ghostty | Layout and cwd; no scrollback | Same | — |
| kitty | Nothing automatic | Layout and scrollback, restored before the shell starts; non-shell programs are not restarted | Scrollback fed before the shell's output; no automatic re-run |
| tmux + resurrect | Everything (server outlives clients) | Layout, cwd, allowlisted programs with per-program restore commands | The rules table |
| zellij | Not checked | Layout and commands; commands wait behind "Press ENTER to run" | Consent before running |

### Claude Code and Codex

Checked 2026-11-11 against official documentation, upstream source and local
`--help` output (Claude Code 2.1.322, codex-cli 0.167.1). No session of either
was started.

| # | Claim | Mark | Source |
| --- | --- | --- | --- |
| C1 | `claude --resume <session-id>` resumes that session and works from any directory | V 11-11 | [sessions](https://code.claude.com/docs/en/sessions), local help |
| C2 | `claude --continue` reopens the most recent session in the current directory | V 11-11 | [cli reference](https://code.claude.com/docs/en/cli-reference), local help |
| C3 | A resumed session keeps its id unless `--fork-session` is passed | V 11-11 | cli reference, local help |
| C4 | Transcripts are at `~/.claude/projects/<project>/<session-id>.jsonl`, kept 30 days by default (`cleanupPeriodDays`) | V 11-11 | sessions |
| C5 | Hooks receive `session_id`, `transcript_path`, `cwd` and `permission_mode` on stdin. `SessionStart` fires with source `startup`, `resume`, `clear`, `compact` or `fork` | V 11-11 | [hooks](https://code.claude.com/docs/en/hooks) |
| C6 | User hooks are configured in `~/.claude/settings.json` | V 11-11 | hooks |
| C7 | A running session has `~/.claude/sessions/<pid>.json` with `sessionId` and `cwd` | V 11-11 locally; the file is undocumented | local listing, field names only |
| C8 | The process reports `argv[0]` = `claude`; its executable is `~/.local/share/claude/versions/<version>` | V 11-11 locally | `ps` |
| C9 | A tool call that was running when the process died is not rerun on resume. Background shells and subagents are not restarted | V 11-11 | sessions |
| C10 | Resume by id from a terminal restores `plan` and `auto` mode. A session that ended in `bypassPermissions` resumes in the mode a new session would start in | V 11-11 | sessions, "Permission mode on resume" |
| C11 | A new session starts in `bypassPermissions` when `--dangerously-skip-permissions` is passed or `permissions.defaultMode` says so; auto mode is the built-in default since 2.1.283 | V 11-11 | [permission modes](https://code.claude.com/docs/en/permission-modes) |
| C12 | A goal that was active when the session ended is restored on resume | V 11-11 | [goal](https://code.claude.com/docs/en/goal) |
| C13 | Whether a resumed session with an active goal starts a turn before the user types | U | not stated in the docs |
| C14 | Whether `SessionEnd` hooks run on SIGKILL or power loss | U | the design assumes not |
| C15 | Whether `~/.claude/sessions/<pid>.json` follows `/clear` and forks | U | |
| C16 | Whether a hook command inherits environment variables the terminal set for the pane | U | tested in phase 3 |
| X1 | `codex resume <SESSION_ID>` resumes that session; the id is a UUID or a session name | V 11-11 | [developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli), local help |
| X2 | `codex resume --last` picks the most recent session in the current directory unless `--all` | V 11-11 | developer commands, local help |
| X3 | If the current directory differs from the session's saved directory, Codex asks which to use | V 11-11 | developer commands |
| X4 | Sessions are at `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`; the first line holds the id and cwd | V 11-11 locally | local listing, field names only |
| X5 | Hooks receive `session_id`, `transcript_path`, `cwd` on stdin; `SessionStart` has source `startup`, `resume`, `clear`, `compact` or `fork` | V 11-11 | [hooks](https://learn.chatgpt.com/docs/hooks) |
| X6 | User hooks are configured in `~/.codex/hooks.json` or `~/.codex/config.toml`, and a new or changed hook is skipped until trusted through `/hooks` | V 11-11 | hooks |
| X7 | On exit Codex prints `codex resume <id>` | V 11-11 | [exit_summary.rs](https://github.com/openai/codex/blob/main/codex-rs/tui/src/app/exit_summary.rs) |
| X8 | The process's `argv[0]` ends in `/codex` | V 11-11 locally | `ps` |
| X9 | A file or other signal that maps a running Codex pid to its session id | U | none found |
| X10 | Whether a resumed session keeps its id | U | not stated in the docs |
| X11 | Whether resume restores the session's approval policy and sandbox, including `--dangerously-bypass-approvals-and-sandbox` | U | not in the docs; [issue 59666](https://github.com/openai/codex/issues/59666) reports that 0.166 and later restore them |
| X12 | Behaviour after a hard kill | U | |

What follows from the table:

- Both agents resume by id. A template with `{session}` covers them.
- The id is not in argv. It is looked up (C7, Claude Code only) or reported by
  a hook (C5, X5).
- "Most recent in this directory" (C2, X2) is wrong when two agents share a
  directory, which is Helge's normal setup. It is a guess and is labelled so.
- Resume restores the conversation, not the moment (C9).
- A resumed agent can come back with wide permissions (C10 to C13, X11). The
  terminal cannot change that; it can only decide who starts the agent.

### Not verified

- `tcgetpgrp` on the PTY master, `proc_pidpath` and reading another process's
  argv from inside the app, including under the hardened runtime. `ps` returns
  them for same-user processes on this machine.
- That macOS logout, restart and shutdown always reach
  `applicationShouldTerminate` for this app. Standard AppKit behaviour; not
  tested here.
- Durability of `fsync` versus `F_FULLFSYNC` on APFS, and whether an unsynced
  rename can leave an empty file after power loss. The design assumes it can.
- Claims C13 to C16 and X9 to X12 above.

## Design

### State saved

| Item | Saved | Note |
| --- | --- | --- |
| Window frame, zoomed or full screen | Yes | Clamped to the visible screens on restore |
| Tab groups | Yes | Window order per group, selected tab |
| Pane tree | Yes | Binary tree: pane, or split with orientation and ratio. Ratio, not points |
| Active pane, key window | Yes | |
| Pane id | Yes | Stable UUID; also the automation id |
| cwd | Yes | Last OSC 7 value |
| Title | Yes | Shown until the new shell sets one |
| Pane colour | Yes, when the pane has its own | One hex value |
| Scrollback | Yes | Primary history and primary screen as plain text, soft wraps joined |
| Resume record | Yes | Rule id and session id; see [Resume rules](#resume-rules) |
| Environment | **No** | |
| Command lines and argv | **No** | Only the matched rule id |
| Alternate screen, modes, images, selection, find state, font size | No | Not meaningful for a new process, or reset to the preference |

Limits, all existing:

| Limit | Value | Unit | Source |
| --- | --- | --- | --- |
| Scrollback rows saved per pane | the pane's history: setting, default 50,000, maximum 50,000 | rows | `Preferences.swift:181-188` |
| Scrollback text saved per pane | 16; the newest rows are kept | MiB | `TerminalSelection.maximumCopyBytes`, `Emulation/TerminalSelection.swift:32` |
| cwd length | 8,192 | bytes | `Preferences.swift:124` |

**Stored in plain text:** everything each pane printed that is still in its
history, including any secret a command printed; working directories; pane
titles; agent session ids. **Not stored:** the environment, command lines,
and input that was never echoed, such as typed passwords.

### Location

| Launch | State directory |
| --- | --- |
| `--state-directory <dir>` given | `<dir>` |
| No launch arguments, and the bundle is inside `/Applications` or `~/Applications` | `~/Library/Application Support/no.helgesverre.terminal/Sessions/` |
| Anything else: `dist/Terminal.app`, a frozen benchmark copy, any smoke or benchmark flag | None. No state is read or written |

A development build shares the installed app's bundle id, so the bundle's
location, not its id, decides. `just dev --state-directory <dir>` gives a
development build its own state.

```
Sessions/                  mode 0700
  running                  pid and process start time; held with flock
  layout.json              current layout, mode 0600
  layout.previous.json     last generation that loaded
  panes/<pane-uuid>.scrollback
  panes/<pane-uuid>.resume written by an agent hook; see Resume rules
  quarantine/              the one most recent state that failed to restore
```

- `layout.json`: `{ "version": 1, "saved_at", "app_build", "windows": [...] }`.
- `*.scrollback`: one JSON header line (`version`, `rows`, `bytes`,
  `captured_at`, checksum of the body), then the text.

### Clean and unclean exit

- At launch the app takes the lock on `running` and writes its pid, and
  whether a restore is in progress. If another live process holds the lock,
  this instance runs without state.
- **Clean exit:** `applicationShouldTerminate` (`main.swift:573`). It is
  reached by ⌘Q, by closing the last window (`main.swift:568`) and by a
  system restart, shutdown or logout. It stops the writers, deletes
  `layout.json`, `layout.previous.json` and `panes/`, then deletes `running`.
- **Unclean exit:** `running` exists at launch and no live process holds its
  lock. Every other way of ending leaves it: crash, SIGKILL, SIGTERM, force
  quit, power loss, hard reset.
- Closing a pane or window deletes that pane's files.

### Writing

| Write | Trigger | Where the work runs |
| --- | --- | --- |
| Layout | A structural change (split, close, tab, move, resize end, focus, cwd, title, colour, resume record), debounced 1 s. Nothing is written when nothing changed | Main thread gathers values it already has; encoding and I/O on a utility queue |
| Scrollback checkpoint | The pane has new output since its last checkpoint and has been quiet for 2 s, or has had new output for 60 s | One pane at a time. Capture on the pane's session queue in the existing bounded turns, yielding to input; encoding and I/O on a utility queue |
| Both, immediately | `NSWorkspace.willSleepNotification` | Same queues |

- **Atomic replace:** write `name.tmp`, `fsync`, `rename`.
- **Two generations:** a layout that loads is copied to
  `layout.previous.json` before the next write replaces it.
- **No log of PTY bytes.** The only cost on the output path is setting a
  per-pane flag.
- **No timers when idle.** An idle app has no pane with new output and
  schedules nothing.
- ⌘K needs no special case: the next checkpoint holds the cleared history.

Worst-case loss after a hard reset: the last 1 s of layout changes and the
last 60 s of output in a busy pane.

If phase 2 misses its throughput criterion with whole-file rewrites, the fix
is appending by row identity, not a setting.

### Restore

Decided at the top of `main.swift`, before `EarlyChild.start`:

| Condition at launch | Action |
| --- | --- |
| No state directory (see [Location](#location)) | Normal launch |
| `running` absent | Normal launch; leftover state is deleted |
| `running` present, lock free | Unclean exit: restore |
| `running` shows the previous launch died during a restore | Move the state to `quarantine/`, open one window, log one line |
| Lock held by a live process | Normal launch without state |

On a normal launch the cost is one `stat`. On a restore the early child is
started with the first restored pane's `LaunchSpec`, so adoption
(`Session.swift:78`) still succeeds.

Per pane:

1. Create the pane with its saved id, colour and split position.
2. In `Session.start`, between `terminal_create` and the read endpoint
   (`Session.swift:611-638`), feed the saved text into the emulator as faint
   text (SGR 2). It does not pass through the shell and works for every shell.
3. Append one marker row: `Restored · saved 2026-11-10 14:02`.
4. The shell is `LaunchSpec.shell` in the saved cwd. Its output follows the
   marker.
5. Restored rows are ordinary history: selectable, copyable, found by ⌘F.
6. A pane with a resume record gets a strip; see [Resume rules](#resume-rules).

### Failures

| Failure | Behaviour |
| --- | --- |
| `layout.json` missing, truncated or invalid | Use `layout.previous.json`; if that fails, normal launch and quarantine both |
| Newer `version` than the app knows | Do not load, do not overwrite; quarantine, normal launch |
| Older `version` | Migrate in memory; write the new version after a successful restore |
| Scrollback checksum mismatch | The pane restores without history; the marker row says so |
| cwd missing or not a directory | The preference starting directory, as `launchDirectory(inheriting:)` does today (`Preferences.swift:123-133`); the marker row names the saved path |
| Screens changed | Frames are clamped to visible screens |
| Tree does not fit the window | Existing `reconcileLayout` minimum-size logic (`main.swift:266-297`) |
| Shell fails to launch | Existing "Unable to start the shell" alert (`main.swift:143-150`) |
| The app dies during a restore | The next launch quarantines the state and opens one window |
| State directory unwritable | No state for this run; one log line |

## Resume rules

### What a resume rule is

A resume rule is one entry in a data file. It says: "a process that looks
like *this* is the program *X*; its session id is found *here*; to bring it
back, run *this command*." The terminal reads rules; it contains no agent
names in Swift code. The first version ships two rules, in
`Resources/Terminal/ResumeRules.json`:

```json
{
  "version": 1,
  "rules": [
    {
      "id": "claude-code",
      "label": "Claude Code",
      "match": { "argv0": "claude" },
      "session": { "json_file": "~/.claude/sessions/{pid}.json", "key": "sessionId" },
      "session_pattern": "^[0-9a-f-]{36}$",
      "resume": ["claude", "--resume", "{session}"],
      "guess": ["claude", "--continue"],
      "warn_argv": ["--dangerously-skip-permissions", "bypassPermissions"]
    },
    {
      "id": "codex",
      "label": "Codex",
      "match": { "argv0": "codex" },
      "session_pattern": "^[0-9a-f-]{36}$",
      "resume": ["codex", "resume", "{session}"],
      "guess": ["codex", "resume", "--last"],
      "warn_argv": ["--dangerously-bypass-approvals-and-sandbox", "--yolo", "danger-full-access"]
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `match.argv0` | Basename of the foreground process's `argv[0]` |
| `session` | Optional lookup of the session id from a file named by the process id |
| `session_pattern` | The id must match, or it is discarded |
| `resume` | The command when the session id is known. `{session}` is the only variable |
| `guess` | The command when it is not: "most recent in this directory" |
| `warn_argv` | If the original process had one of these arguments, the strip says so and nothing runs automatically |

How the terminal learns what runs in a pane:

- **Sampling.** At each layout save, per pane: ask the PTY for its foreground
  process group, read that process's `argv` and pid, match the rules. A pane
  at its shell prompt matches nothing. The environment is never read.
- **Hook file.** Each pane's shell gets `HELGE_TERMINAL_RESUME_FILE`, the
  path of `panes/<pane-uuid>.resume`. An agent's own `SessionStart` hook
  writes `{"rule": "<id>", "session": "<id>"}` there. The file names a rule
  and a session id. It cannot supply a command.

A resume record is offered after a restore only if the rule still matched the
pane's foreground process at the last save. An agent that had already exited
is not offered.

### Worked example: Claude Code

Helge runs `claude` in a pane whose cwd is `/Users/helge/code/terminal`. No
hook is installed.

| Step | What happens | Basis |
| --- | --- | --- |
| Sample | Foreground process pid 41822, `argv[0]` = `claude`. Rule `claude-code` matches | C8 |
| Look up | `~/.claude/sessions/41822.json` gives `sessionId` = `0b6c…` | C7 |
| Record | In `layout.json`, for that pane: `"resume": {"rule": "claude-code", "session": "0b6c…", "exact": true, "warned": false}` | |
| Hard reset | The agent dies. Its transcript is on disk | C4 |
| Restore | New login shell in `/Users/helge/code/terminal`. Strip: `Was running: Claude Code · Resume · Dismiss` | |
| Click Resume | The terminal types `claude --resume 0b6c…` and Return into that shell | C1 |
| Result | The conversation is back with the same id. A tool call that was running is not rerun. Plan or auto mode is restored; bypass mode is not, unless the user's settings default to it | C3, C9, C10, C11 |

With the hook installed, the lookup step is replaced by the hook's report,
which also follows `/clear` and forks (C5). The lookup file is undocumented
(C7); the hook is the documented route. The hook is one command in
`~/.claude/settings.json` under `SessionStart`:

```sh
[ -n "$HELGE_TERMINAL_RESUME_FILE" ] || exit 0
jq -c '{rule: "claude-code", session: .session_id}' > "$HELGE_TERMINAL_RESUME_FILE.tmp" \
  && mv "$HELGE_TERMINAL_RESUME_FILE.tmp" "$HELGE_TERMINAL_RESUME_FILE"
```

### Worked example: Codex

Helge runs `codex` in a pane whose cwd is `/Users/helge/code/terminal`.

| Step | Without a hook | With a `SessionStart` hook in `~/.codex/hooks.json` | Basis |
| --- | --- | --- | --- |
| Sample | `argv[0]` ends in `/codex`. Rule `codex` matches | Same | X8 |
| Session id | None: no pid-to-session file is known | The hook writes `{"rule": "codex", "session": "7f3a…"}` | X9, X5 |
| Record | `{"rule": "codex", "session": null, "exact": false, "warned": false}` | `{"rule": "codex", "session": "7f3a…", "exact": true, "warned": false}` | |
| Strip after restore | `Was running: Codex · Resume most recent in this directory · Dismiss` | `Was running: Codex · Resume · Dismiss` | |
| Click | Types `codex resume --last` | Types `codex resume 7f3a…` | X2, X1 |
| Result | The newest Codex session in that directory. With two Codex panes in one directory, one of them gets the wrong conversation | The exact conversation | X2 |

The Codex hook is the same command with `rule: "codex"`. Codex skips a new
hook until it is trusted through `/hooks` (X6). Whether a resumed Codex
session keeps its approval and sandbox settings is unverified (X11).

### What "trusted" would mean

- **Who:** Helge, and only by an explicit action in the app: a
  "Resume automatically from now on" control on a resume strip. No rule
  ships trusted. No file, hook or program can mark a rule trusted.
- **What:** one rule id together with a hash of that rule's content. Editing
  the rule removes the trust.
- **Where:** the app's `UserDefaults` domain, next to the other preferences
  (`Preferences.swift:203-213`), as a list of rule id and hash.
- **Revoking:** a list in Settings with a remove button per rule.

### Click versus automatic

| | Click | Automatic |
| --- | --- | --- |
| After a restore | Each agent pane shows a strip. Nothing runs | A trusted rule with an exact session id types its command as soon as the shell shows a prompt |
| Starting everything | Shell → Resume All: one action for every strip | No action |
| Guesses (`exact: false`) | Offered, labelled as a guess | Never automatic; offered as a strip |
| What Helge sees first | The restored scrollback and the strip | The agent, already running |

### Risks of automatic resume

| Risk | Concrete case | With click | With automatic |
| --- | --- | --- | --- |
| A command runs without consent | The machine comes back from a hard reset and six agents start at once, while Helge is not there, on a machine that was just overloaded | Does not happen | Limited to trusted rules. Agents start one at a time. Still runs unattended |
| A rule matches the wrong process | A script or another tool named `claude` was in the foreground | Helge sees the strip and dismisses it | The session id must exist and match `session_pattern`, so a non-agent has no record. A different tool with the same name and a UUID in the same place would run |
| The agent returns with wide permissions | Claude Code restores `auto` mode and an active goal (C10, C12); with `defaultMode: bypassPermissions` it returns in bypass mode (C11); Codex is reported to restore full access (X11, unverified). Whether it then acts before Helge types is unverified (C13) | Helge chooses per pane, and the strip flags `warn_argv` | `warn_argv` blocks automatic resume when the original command line asked for a bypass. A mode set in the agent's settings or during the session is invisible to the terminal and is not blocked |
| The directory has changed | The repository was moved, a worktree was removed, or the branch changed since the snapshot | Helge sees the cwd in the prompt before clicking | Automatic only when the saved cwd still exists. A changed branch or changed files are not detected. Codex asks which directory to use (X3); Claude Code resumes from anywhere (C1) |
| The wrong conversation | Two agents in one directory, no session id | Labelled as a guess | Never automatic |
| A planted hook file | Another process of the same user writes a `.resume` file | The file can only name a shipped rule and a session id; Helge sees the label | Same limit: it can select which session a trusted rule resumes, not which command runs |
| A crash loop | The resumed program's output is what crashed the app | One click per crash | Nothing runs automatically when the previous run ended uncleanly within 60 s of a restore |

### The first version under each answer

| | `click` | `auto` |
| --- | --- | --- |
| Built in phase 3 | Rules file, sampling, hook file, strip with Resume and Dismiss, Shell → Resume All | Everything under `click`, plus: trust list in `UserDefaults`, the "automatically from now on" control, a revoke list in Settings, the wait-for-prompt gate, the one-at-a-time start, the crash-loop gate |
| New settings | None | One list in Settings |
| Needs shell integration | No | Yes: automatic start waits for OSC 133;B, which only the zsh integration sends |
| After a crash with six agent panes | One menu action, or six clicks | No action |
| Unverified claims it depends on | None for safety; C7 or C16 for exact ids | C13 and X11 decide how much an unattended agent can do |
| Changing the answer later | Adding `auto` changes no file format | Removing it deletes code |

### Recommendation

**`click`.** One "Resume All" brings every agent back after a crash, so the
cost is one action per crash. Automatic resume adds a trust store, a Settings
list and three gates, and its main risk (an agent that returns with wide
permissions and acts unattended) rests on two claims that are not verified.
The record format is the same either way, so `auto` can be added later
without migration.

### The question

**After a crash, should agents resume only when you click (per pane, or one
"Resume All"), or automatically for rules you have marked trusted? Answer
`click` or `auto`.**

## Roadmap

| Phase | Scope | Acceptance criteria | Blocked by |
| --- | --- | --- | --- |
| 0. Groundwork | Value-type layout model; stable pane and window ids; state-directory rule as a pure function. No files written, no visible change | Views → model → views reproduces single, nested and closed-pane trees with ratios within one cell. AppleScript pane ids keep their format. Startup, throughput and idle measurements unchanged. Existing suites pass | Nothing |
| 1. Layout and cwd | `running` sentinel and lock; layout writes, two generations; restore decision before `EarlyChild.start`; restore; quarantine; cwd fallback; clean-exit deletion | After `kill -9` of a disposable instance with 3 windows, 2 tab groups and nested splits, relaunch reproduces tree, ratios, tab order, focus, colours and cwds. After a normal quit, relaunch opens one default window and the state directory is empty. Every row of the fault matrix ends in a usable window. A kill during restore does not loop. Normal-launch startup time is within run-to-run noise of phase 0 | Phase 0 |
| 2. Scrollback | Checkpoints gated on new output and quiet; flush on sleep; seeding in `Session.start`; faint rows and marker row | After `kill -9`, each pane shows its last checkpoint, at most 60 s old, with the marker. Restored text is found by ⌘F and copies. With 20 panes under sustained output, throughput and input latency are within run-to-run noise of a run without state. An idle app schedules no work | Phase 1 |
| 3. Resume | `ResumeRules.json` loader and matcher; foreground sampling; `HELGE_TERMINAL_RESUME_FILE`; resume strip; Shell → Resume All. With answer `auto`: the additions listed above | With a fake agent: an exact record is offered after `kill -9` and Resume runs the exact command. An agent that had exited is not offered. A match without a session is offered as a guess. Nothing runs without a click (answer `click`). No agent name in `Sources/` | Phase 1 and **the open question** |
| 4. Agent rules | The two shipped rules checked against real agents; hook commands and install notes in `docs/usage.md`; a version-migration test | Manual run in a scratch repository: Claude Code and Codex are offered and resume the right conversation when two agents shared one directory (hook route). Claims C7, C15, C16, X9 and X10 are marked verified or the rules are changed | Phase 3 |

Phases 0 to 2 restore layout and context. Phases 3 and 4 bring the agents
back. Each phase ships on its own.

### Phase 0 in the current code

| File | Change |
| --- | --- |
| `Sources/Terminal/PaneLayout.swift` (new; add to the `app` group in `tools/swift-sources.json`) | `struct PaneID: Hashable, Codable` wrapping a UUID. `indirect enum PaneLayout: Equatable, Codable { case pane(PaneID); case split(vertical: Bool, ratio: Double, first: PaneLayout, second: PaneLayout) }`. `struct WindowLayout: Equatable, Codable { id, frame, root: PaneLayout, activePane }` |
| `Sources/Terminal/Canvas.swift` | `TerminalCanvasView.init(frame:session:)` (line 92) takes a `PaneID`, default new. `automationID` (line 5) is derived from it; the accessibility identifier (line 113) keeps its format |
| `Sources/Terminal/main.swift` | `TerminalWindow.makePane(launch:)` (line 131) takes a `PaneID`. New `var layout: WindowLayout`, read from `root` by the same recursion as `terminalMinimumSize` (lines 19-32). New `init(layout:)` that builds the tree; the split construction in `split(vertical:)` (lines 238-252) moves into a helper both use. Window `automationID` (line 54) becomes a saved id the same way |
| `Sources/Terminal/SessionState.swift` (new) | `enum StateLocation` with one pure function from launch arguments and bundle path to a state directory or none, per [Location](#location). Parses `--state-directory` like `TerminalPreferences.launchInteger` parses its options (`Preferences.swift:159-165`) |
| `Tests/TerminalTests/PaneLayoutTests.swift` (new; add to `tests` in `tools/swift-sources.json`) | Codec round-trip, ratio clamping, `StateLocation` table |
| `Sources/Terminal/PaneLifecycleSmoke.swift` | One added check: views → model → views after its existing split and close sequence |

Not touched in phase 0: `Session.swift`, `Preferences.swift`, `Settings.swift`.
The view tree stays the source of truth; the model is derived from it. That
keeps the change to `main.swift` and `Canvas.swift`, the two files that
conflict most between branches, small.

## Test strategy

Safety rules for every test:

- Tests run only against a disposable instance: the automation fixture
  (its own bundle id) or a copied development bundle, always started with
  `--state-directory` pointing at a new temporary directory.
- By the [Location](#location) rule a bundle outside an Applications folder
  has no state directory unless one is passed, so a test cannot read or write
  the installed app's state.
- A test signals only the pid it started. No name-based kills. The installed
  app (`~/Applications/Helge Terminal.app`) and every instance the test did
  not launch are never signalled, scripted, rebuilt or replaced.
- Agent tests use a fake agent, a private `ZDOTDIR` and a temporary home.
  Real `~/.claude` and `~/.codex` are not read or written.
- New runners are Swift subcommands of `tools/Dev`, called from `justfile`
  recipes. One heavy job at a time on the machine.

| Level | What | How |
| --- | --- | --- |
| Unit | Layout codec, version migration, frame clamping, `StateLocation`, rule matching, template expansion and shell quoting, checkpoint scheduling | Directly compiled test programs in `Tests/TerminalTests`, with an injected clock and directory |
| Fault matrix | Every file state a crash can leave: missing, empty, truncated at each byte of a small sample, wrong checksum, stale `.tmp`, only `previous` present, newer version, unwritable directory | Table-driven loader test; each row has one defined outcome |
| Crash points | Death at each step of a write | A test-only environment variable stops the writer at a named step; the runner sends SIGKILL to that pid, relaunches, and checks the result is the old or the new generation |
| `kill -9` | Whole-app recovery | The runner builds a known layout through the AppleScript commands (`new window`, `new tab`, `split right`, `split below`), prints marker text per pane, waits for one checkpoint, kills, relaunches, and inspects through AppleScript and accessibility |
| Clean quit | No restore | Same layout, quit through the menu command, relaunch: one default window, empty state directory |
| Simulated power loss | Children die with the app | SIGKILL the instance's whole process tree at random times over many iterations, including during checkpoints. Does not test disk-cache loss |
| Resume | Sampling, hook file, rules, strip | A scripted fake agent that writes a session file and a hook file, records how it was relaunched, and can exit before the kill |
| Performance | No regression | Existing startup, throughput and input-latency benchmarks with and without a state directory in the same run; the idle measurement with state on |
| Manual | Real agents; real power loss | Phase 4 checklist in a scratch repository. Power loss only in a disposable virtual machine, never on Helge's machine |

## Considered and not planned

| Option | Why not |
| --- | --- |
| PTY-holding helper process (programs survive an app crash or update) | Decision 5. It is the largest item researched: a second signed executable, a reconnect protocol, version skew between app and helper, orphaned helpers, and unknown screen state after reattach because the emulator dies with the app. It does not help after a hard reset. Precedents: iTerm2's session servers, shpool |
| Running panes inside tmux or zellij | Decision 5. What cmux offers as `local-tmux`. It needs no terminal code, so it stays available to the user without being a feature |
| Restore after a normal quit, with a setting | Decision 1 |
| Encryption at rest, keychain key (kitty does this) | Decision 4 |
| Opt-outs: global, per pane, environment variable | Decision 3 |
| Separate scrollback limit; backup exclusion; window and pane count limits | Decision 3 |
| Styled scrollback (colours) | Plain text is what the existing capture produces. The file header has a version for adding it |
| Recording the typed command line (`OSC 133;C` with `cmdline`) | Re-running a command is not resuming it, and it stores command lines |
| A program declaring its own resume command, by file or escape sequence | Lets any process or printed file plant a command. The hook file names a shipped rule instead |
| Carrying the original launch flags into the resume command | Would carry `--dangerously-skip-permissions` across a crash |
| A command that installs hooks into `~/.claude` or `~/.codex` | Those files are not the terminal's. `docs/usage.md` gives the two commands |
| Restart button on a finished pane; "Reopen Closed Tab" | Not recovery. Closing deletes the pane's state |
| Agent code in the app (cmux) | Agent knowledge stays in `ResumeRules.json` |
| AppKit window restoration | It does not cover the pane tree or scrollback |
| Restoring remote sessions | An ssh pane restores as a local shell in its last local cwd |
