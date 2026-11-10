# Session recovery plan

Status: proposal, 2026-11-10. Research and design only; nothing here is implemented.

## Summary

Today the app persists nothing about its windows. A crash, a kill or a reboot
loses every window, tab, pane, scrollback and running program.

**Recommendation.** Build recovery in three layers, in this order:

1. **Core snapshot and restore (failure class b, also covers a and c partly).**
   The app writes its own crash-safe state: window frames, tab groups, pane
   tree, per-pane cwd, title, launch spec and bounded scrollback text. On
   launch it rebuilds the layout, shows the saved scrollback as dimmed
   "restored" history, and starts a fresh shell in each pane's cwd.
2. **Generic resume recipes.** Each pane can carry one *resume recipe*: an
   argv plus cwd that would bring back what was running. A recipe comes from
   a program declaring it, or from a data-only rules table matched against the
   pane's foreground process. The terminal offers it per pane; it never runs
   one without consent unless Helge has trusted that rule.
3. **Agent pack (separate layer).** Claude Code, Codex and others are entries
   in the rules table plus optional hook snippets. No agent name appears in
   the terminal's Swift code.

A PTY-holding helper process (keeps programs alive across an app crash or
update) is a later, optional phase behind a spike. It would not have helped
with today's hard reset.

**What cmux does, in one line:** it reconstructs layout, cwd and best-effort
scrollback from a JSON snapshot and re-runs agent resume commands from session
ids captured by hooks. It does not keep processes alive unless the user opts
into running panes inside tmux. Details in [cmux](#cmux).

## Failure classes

| Class | Event | What can survive | Mechanism needed |
| --- | --- | --- | --- |
| a | App crash, `kill -9`, force quit, app update; machine stays up | Child processes, if something other than the app holds the PTY master | PTY-holding helper, or a multiplexer inside the pane |
| b | Logout, reboot, hard reset, power loss | Only what is on disk | Periodic snapshot, restore, resume recipes |
| c | The child exits or is killed | The pane and its final screen | Keep the pane, offer restart or resume |

Without a helper, class a degrades to class b: the children get SIGHUP when
the master closes. Phases 1 to 3 therefore cover all three classes at the
"reconstruct" level; only phase 5 adds "keep alive" for class a.

## What exists today

Read from the worktree at `359c8f3` (`perf/terminal-throughput`).

| Area | Current state | Source |
| --- | --- | --- |
| State restoration | None. No `NSWindowRestoration`, no state files; only preferences in `UserDefaults` | `Sources/Terminal/Preferences.swift`, grep of `Sources` |
| Windows | `TerminalWindow` creates a 1000×680 window and centres it; frame is never saved | `Sources/Terminal/main.swift:69-88` |
| Tabs | Native AppKit tabs: each tab is its own `TerminalWindow` in a tab group (`tabbingIdentifier = "HelgeTerminal"`) | `main.swift:77-78`, `466-475` |
| Pane tree | The nested `NSSplitView` hierarchy *is* the model; there is no value-type layout. Splits are binary | `main.swift:223-256`, `289-316` |
| Pane identity | `automationID` is a fresh UUID per launch | `main.swift:54`, `Sources/Terminal/Automation.swift:26` |
| Launch | `LaunchSpec { executable, arguments, cwd, launcher }`; default is `$SHELL -l`. No per-pane environment | `Sources/Terminal/Session.swift:18-34` |
| Child environment | The app's environment, with `TERM`, `COLORTERM`, `TERM_PROGRAM=HelgeTerminal`, and a zsh `ZDOTDIR` shim. `HELGE_TERMINAL_*` is the reserved prefix | `Sources/Terminal/Interop/Spawn.c:56-88` |
| cwd | OSC 7 stored by the emulator, delivered in snapshots, used for split inheritance | `Emulation/TerminalEmulator.swift:1173`, `Session.swift:231-232` |
| Prompt marks | OSC 133 A/B/C/D drive prompt phase only. `C` carries no command line | `TerminalEmulator.swift:1185-1203`, `Resources/Terminal/ShellIntegration/zsh/hooks.zsh` |
| Shell integration | zsh only | `Resources/Terminal/ShellIntegration/zsh` |
| History | Up to 50,000 rows per pane, rows have stable identities | `Preferences.swift:111-118`, `docs/decisions.md` |
| Text capture | Copy captures text on the session owner in bounded turns, 16 MiB cap | `docs/status.md` (owner-confined selection) |
| Quit | `applicationShouldTerminate` closes every window, children get SIGHUP then SIGKILL after 2 s; a 3 s timer ends termination | `main.swift:512-524`, `Session.swift:1230-1289` |
| Child exit | Pane stays, title becomes "Terminal — Finished", content stays selectable | `main.swift:117-124`, `docs/status.md` |
| Test fixtures | Smoke modes are launch flags; a separately signed disposable "Terminal Automation Fixture" exists | `main.swift:367-459`, `docs/automation.md:227` |

Consequences for the design:

- A layout model and stable pane ids must be added before anything can be saved.
- The bounded owner-side text capture is the natural basis for scrollback checkpoints.
- The existing "installed app remains 0.2.2 with live sessions; 0.2.3 publication
  is pending" note in `docs/status.md` shows that app updates are already blocked
  by live sessions. That is the main argument for phase 5.

## Research

Every claim is marked **V** (verified today, with source) or **U** (not verified).

### cmux

Source read from a shallow clone of `manaflow-ai/cmux` at
`b4cb6ad1920a1b1f825427bca6bc6dcc986d0ef4` (2026-11-10). Nothing was built or
run; behaviour below is from reading source and README.

| Question | Finding | Mark | Source |
| --- | --- | --- | --- |
| What is it | Native macOS Swift/AppKit app that uses libghostty as a library for terminal rendering; not a Ghostty fork (it builds against its own fork of the ghostty repo as a submodule) | V | [README](https://github.com/manaflow-ai/cmux/blob/main/README.md) lines 148, 394; `.gitmodules` |
| Claim scope | "cmux does not checkpoint arbitrary live process state. Ordinary terminals, tmux, vim, shells, and unsupported terminal apps reopen as normal terminals." | V | README "Session restore" |
| What is restored | Window/workspace/pane layout, working directories, "terminal scrollback (best effort)", browser URL and history | V | README "Session restore" |
| Format and place | One JSON snapshot, schema version 1, at `~/Library/Application Support/cmux/session-<bundleId>.json`, with a `-previous.json` backup | V | `Sources/SessionPersistence.swift`, `Packages/macOS/CmuxWorkspaces/.../SessionSnapshotFileLocation.swift` |
| Cadence | 8 s autosave timer **without** scrollback; full save with scrollback on quit, power-off notification and update relaunch | V | `SessionPersistence.swift:37`, `Sources/SessionScrollbackCheckpoint.swift:5-12` |
| Crash-safe scrollback | Separate checkpoints: at most every 60 s, only after typing has been quiet, only for terminals with new output, at most a few exports per round within a main-thread budget, one file per terminal; merged only after an unclean exit | V | `Sources/SessionScrollbackCheckpoint.swift:5-40` |
| Scrollback limits | 4,000 lines and 400,000 characters per terminal | V | `SessionPersistence.swift:41-42` |
| Scrollback replay | Text is written to a 0600 temp file whose path is passed in an environment variable; cmux's shell integration `cat`s it at shell start. Replay therefore depends on shell integration | V | `SessionPersistence.swift`, `Resources/shell-integration/cmux-zsh-integration.zsh` |
| Restore trigger | Automatic at launch, no prompt; skipped when launch arguments are present or `CMUX_DISABLE_SESSION_RESTORE=1` | V | `SessionPersistence.swift:245-262` |
| Crash detection | Launch sentinel file with the pid, removed only on clean termination | V | `Sources/GhosttyCrashBreadcrumb.swift` |
| Live processes | No PTY-holding daemon for ordinary panes. Opt-in `cmux local-tmux` (or `local-zellij`) runs panes inside a user-owned tmux server, which survives cmux quit, crash and update but "cannot survive logout, restart, shutdown, or power loss" | V | README FAQ "Are my sessions saved?", `docs/local-tmux.md` |
| Agent resume | Hooks installed by `cmux hooks setup` record each agent's native session id; on restore cmux types a `cmux restore <kind> <sessionId>` command into the new shell, which builds the native resume argv (for example `claude --resume <id>`, `codex resume <id>`) | V | README; `Sources/RestorableAgentSession.swift`; `Packages/macOS/CMUXAgentLaunch/.../AgentResumeArgv.swift` |
| Auto-run | Auto-resume is on by default once hooks are installed | V (setting default read in source) | `Packages/macOS/CmuxSettings/.../TerminalCatalogSection.swift` |
| Where agent knowledge lives | In the app: a `RestorableAgentKind` enum, per-agent argv builders, a hook-definition table, and a Claude wrapper binary | V | `Sources/RestorableAgentTypes.swift`, `AgentResumeArgv.swift` |
| Generic escape hatch | `cmux surface resume set --shell "..."` attaches a custom resume command to a pane; it auto-runs only if trusted (signed approved prefix bound to cwd and environment); secret-looking environment keys are dropped | V | README "Session restore" |
| Reboot | No separate path: the power-off notification triggers a full save, and restore is the same as after a quit | V | `Sources/AppDelegate.swift` |
| Per-agent resume flags | Exact argv for each of the 13 listed agents | U | not read line by line |
| Hosted docs page | cmux.com session-restore page | U | not fetched |

Lessons taken: own the snapshot file instead of AppKit restoration; separate the
cheap layout save from the expensive scrollback checkpoint; gate checkpoints on
idleness and dirtiness; keep a previous generation; detect unclean exit with a
sentinel; skip restore when launched with arguments. Lessons rejected: agent
knowledge compiled into the app, and replaying scrollback through the shell.

### Other terminals and multiplexers

| Tool | (a) app dies, machine up | (b) reboot | Notes that inform this design | Mark and source |
| --- | --- | --- | --- | --- |
| iTerm2 | Jobs survive: they run "within long-lived servers rather than as child processes"; app reconnects. Not on Cmd-Q by default | Jobs die; window contents come back with a "Session Restored" banner | The server passes the PTY master fd with `SCM_RIGHTS`; newer builds use one multi-server daemon | V: [restoration docs](https://iterm2.com/documentation-restoration.html), [design note](https://github.com/gnachman/iTerm2/blob/master/docs/session-restoration-and-process-reattachment.md) |
| Terminal.app | Text and layout only | Same | Profile option "Restore text when reopening windows" with a row limit; per-session shell history files keyed by `TERM_SESSION_ID`; `SHELL_SESSIONS_DISABLE=1` opts out | V: [Apple guide](https://support.apple.com/guide/terminal/change-profiles-window-settings-trmlwindw/mac), local `/etc/zshrc_Apple_Terminal` |
| Ghostty | Layout and cwd | Same | `window-save-state`; each surface encodes only pwd, uuid and title. Scrollback is not restored (open issue) | V: [config reference](https://ghostty.org/docs/config/reference#window-save-state), [issue 1847](https://github.com/ghostty-org/ghostty/issues/1847). Behaviour after power loss: U |
| tmux | Everything (server outlives clients) | Nothing built in | tmux-resurrect saves layout, cwd, optional pane contents, and restores only allowlisted programs; `"grunt->grunt development"` maps a program to a custom restore command. tmux-continuum saves every 15 min | V: [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), [restoring programs](https://github.com/tmux-plugins/tmux-resurrect/blob/master/docs/restoring_programs.md), [continuum](https://github.com/tmux-plugins/tmux-continuum) |
| zellij | Not checked | Layout and each pane's command, serialized every 1 s | Restored commands wait behind "Press ENTER to run..." to prevent accidents; a hook can rewrite the discovered command | V: [session resurrection](https://zellij.dev/documentation/session-resurrection.html) |
| WezTerm | Panes live when attached to its mux server | Nothing built in found | Third-party resurrect plugin | V: [multiplexing](https://wezterm.org/multiplexing.html); absence of built-in restore: U |
| kitty | Nothing automatic | `restore_session_after_logout` (0.50): layout plus scrollback | Scrollback is restored **before** the shell starts, followed by a line saying when it was saved; non-shell programs are not restarted "since they could have been run for their effects, like rm"; on macOS the saved state is encrypted with a key in the login keychain | V: [kitty sessions](https://sw.kovidgoyal.net/kitty/sessions/) |
| VS Code | Reconnects on window reload | "Revive": content restored, process relaunched | Separate settings for reconnection, revive and scrollback amount | V: [terminal advanced](https://code.visualstudio.com/docs/terminal/advanced) |
| shpool | Shells live in a daemon | Not stated | Minimal precedent for a PTY-holding daemon without multiplexing | V: [shpool](https://github.com/shell-pool/shpool) |

Patterns worth copying:

- **Program restore is an allowlist with templates** (tmux-resurrect). That is the rules table.
- **Consent before re-running** (zellij banner, kitty's refusal). That is the default here.
- **Scrollback restored by the terminal, before the shell starts, with a marker line** (kitty, iTerm2).
- **Class a needs a second process**; every tool that keeps programs alive has one (iTerm2 server, tmux, WezTerm mux, shpool).

### Coding-agent CLIs

Checked against official docs, upstream source, and local `--help` output
(Claude Code 2.1.322, codex-cli 0.167.0).

| Fact | Claude Code | Codex CLI |
| --- | --- | --- |
| Resume most recent | `claude --continue` / `-c`: most recent conversation **in the current directory** (V: [cli reference](https://code.claude.com/docs/en/cli-reference)) | `codex resume --last`: filtered to the current cwd unless `--all` (V: local help, [tui/src/lib.rs](https://github.com/openai/codex/blob/main/codex-rs/tui/src/lib.rs)) |
| Resume exact | `claude --resume <session-id>`; an id works from any directory (V: [sessions](https://code.claude.com/docs/en/sessions)) | `codex resume <SESSION_ID>` (V: local help) |
| Pre-assign id at launch | `--session-id <uuid>` (V: cli reference) | Not found (U) |
| Resume keeps the id | Yes unless `--fork-session` (V) | U |
| Storage | `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`; retention `cleanupPeriodDays`, default 30 (V: sessions, [claude directory](https://code.claude.com/docs/en/claude-directory)) | `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`; first line holds id and cwd (V: local listing) |
| Learn the running session id | Hooks receive `session_id`, `transcript_path`, `cwd`; `SessionStart` fires with `source` = startup, resume, clear, compact or fork (V: [hooks](https://code.claude.com/docs/en/hooks)). Also `~/.claude/sessions/<pid>.json` with `sessionId` and `cwd` while running; its field layout is undocumented (V locally, format U) | `SessionStart` hook with `session_id`, `cwd` (V: [hooks docs](https://learn.chatgpt.com/docs/hooks)); prints `codex resume <uuid>` on exit (V: [exit_summary.rs](https://github.com/openai/codex/blob/main/codex-rs/tui/src/app/exit_summary.rs)) |
| Argv reveals the session | No. Argv shows launch flags only (V locally) | No (V locally) |
| Open transcript file as a signal | No file held open (V locally) | Not reliable (V locally) |
| After a hard kill | Transcript is saved continuously but may lag; an interrupted tool call is not rerun; background shells and subagents are not restored (V: sessions) | U |
| Flags lost on resume | Several launch flags must be passed again, and permission-bypass mode is not restored (V: sessions) | U |

Other CLIs, for generality (V from local `--help` unless noted): opencode
`--continue` and `--session <id>`; Gemini CLI `--resume` and `--session-id`;
Copilot CLI `--continue`, `--resume [id]`; Amp `amp threads continue`; Cursor
`agent resume` / `--resume [chatId]` ([docs](https://cursor.com/docs/cli/reference/parameters));
aider `--restore-chat-history`, no session ids ([docs](https://aider.chat/docs/config/options.html)).

What this means:

- Every agent has "resume by id" and most have "resume latest in this cwd".
  A template with `{session}` and `{cwd}` covers all of them.
- The id is not discoverable from argv. It must be **declared** (hook) or
  **looked up** (a per-pid file, for Claude).
- "Latest in cwd" is wrong when two agents ran in the same directory, which is
  Helge's normal setup. It is a fallback and must be labelled as a guess.
- Resume does not bring back in-flight tool calls or background work. The plan
  can restore the conversation, not the moment.
- No standard lets a program tell a terminal how to restart it (U: none found;
  nearest are kitty's `cmdline` on OSC 133;C and the agents' own hooks).

### Not verified

- `tcgetpgrp` on the PTY master, `proc_pidpath` and `PROC_PIDVNODEPATHINFO`
  were not exercised individually; `ps` and `lsof` returned argv, environment,
  cwd and open files for a same-user process on this machine. Hardened-runtime
  effects on these calls were not tested.
- What process name or executable path a running Claude Code or Codex reports
  (it may be a versioned binary path rather than `claude`).
- Whether closing a PTY master always delivers SIGHUP (the man page describes
  modem disconnect only), and whether a helper started by double fork plus
  `setsid` survives app termination under launchd.
- iTerm2 `OSC 1337 SetUserVar` semantics; Ghostty's handling of `cmdline`.
- Durability of `fsync` versus `F_FULLFSYNC` on APFS, and whether an unsynced
  rename can leave an empty file after power loss. The design assumes it can.
- Whether agent `SessionEnd` hooks run on SIGKILL or power loss. Assume not.
- macOS saved-state paths, `NSQuitAlwaysKeepsWindows`, and crash-loop handling
  of AppKit restoration (third-party sources only). The design does not use them.

## Design

### Layers

| Layer | Owns | Knows about agents |
| --- | --- | --- |
| 0. Core snapshot | Layout model, state files, checkpoint scheduling, restore, restored-history presentation | No |
| 1. Resume recipes | Recipe storage per pane, the declaration channel, the rules engine, foreground-process sampling, consent and trust | No. It knows "argv templates" and "process matchers" |
| 2. Packs | Data files with rules, and optional hook snippets a user installs into an agent's own config | Yes, as data |

Layer 2 ships as files (`Resources/Terminal/ResumeRules/*.json` for bundled
defaults, `~/Library/Application Support/<bundle id>/ResumeRules/*.json` for
user rules). It can live in a separate repository. Removing it leaves a
terminal that still restores layout, cwd, scrollback and declared recipes.

### Resume recipe

One optional value per pane:

```json
{
  "argv": ["claude", "--resume", "0b6c…"],
  "cwd": "/Users/helge/code/terminal",
  "label": "Claude Code",
  "source": "declared",
  "exact": true,
  "owner_pid": 41822
}
```

- `source` is `declared`, `rule` or `command-line`.
- `exact: false` marks a guess such as "latest in this cwd".
- `owner_pid` is the process the recipe belongs to. A recipe is offered after
  restore only if that process was still in the pane at the last snapshot.
  This replaces "session ended" hooks, which do not fire on power loss.

### Options for producing a recipe

| Option | How | Strengths | Weaknesses | Verdict |
| --- | --- | --- | --- | --- |
| A. Declaration file | The app sets `HELGE_TERMINAL_PANE_ID` and `HELGE_TERMINAL_RESUME_FILE` in each pane's environment. Any program or hook writes the recipe JSON to that path | Exact; works from hooks that have no tty; no parser change; only same-user local processes can write it; trivially testable | Local only (not over ssh); the agent needs a hook or wrapper | **Primary** |
| B. Rules table | Data entries: match the pane's foreground process, optionally look up a session id, expand an argv template | Zero setup for the user; this is tmux-resurrect's proven model | Needs process inspection; lookups depend on each agent's file layout; guesses when no id is found | **Primary fallback** |
| C. Shell hook command line | `preexec` emits `OSC 133;C;cmdline_url=…` (kitty's convention); the terminal stores the running command | Generic, shows what the user typed, works over ssh | Shows aliases, not real argv; re-running is not resuming; zsh only today | **Supporting**: display, and a prefilled prompt, never auto-run |
| D. Escape sequence | A program emits an OSC that sets its recipe | Works over ssh; no file | Any printed file or remote host can plant a command; needs a new or borrowed OSC number | **Deferred**; stricter trust if added |
| E. Per-pane restart command | User pins a command to a pane ("always run `npm run dev` here") | Simple, explicit | Manual | **Later**, same storage as A |
| F. Agent code in the app | What cmux does | Polished per agent | Violates the requirement | **Rejected** |

### Rules table format

```json
{
  "version": 1,
  "rules": [
    {
      "id": "claude-code",
      "label": "Claude Code",
      "match": { "argv0": ["claude"], "executable": ["/claude/versions/"] },
      "session": { "json_file": "~/.claude/sessions/{pid}.json", "key": "sessionId" },
      "resume": ["claude", "--resume", "{session}"],
      "fallback": ["claude", "--continue"]
    },
    {
      "id": "codex",
      "label": "Codex",
      "match": { "argv0": ["codex"] },
      "resume": ["codex", "resume", "{session}"],
      "fallback": ["codex", "resume", "--last"]
    }
  ]
}
```

- Matchers: `argv0` basename, `executable` path substring, optional `argv` regex.
- One lookup primitive in phase 3: `json_file` with `{pid}` and a key path.
  More primitives are added only when a real rule needs one.
- Template variables: `{session}`, `{cwd}`, `{argv}` (original arguments, so a
  pack can carry launch flags across a resume).
- `resume` is used when the lookup yields a session; otherwise `fallback`,
  marked `exact: false`.
- Expansion produces an argv array. The terminal never builds a shell string
  from untrusted parts; when it types a recipe into a shell it quotes each
  argument.
- The Claude lookup above relies on an undocumented file. That risk stays in
  the pack; the hook route (option A) is the stable path.

Pack hook snippet, for illustration only (installed by the user into the
agent's own hook configuration, not by the terminal):

```sh
# SessionStart hook: read the hook JSON on stdin, declare how to resume.
[ -n "$HELGE_TERMINAL_RESUME_FILE" ] || exit 0
jq -c '{argv:["claude","--resume",.session_id], cwd:.cwd, label:"Claude Code"}' \
  > "$HELGE_TERMINAL_RESUME_FILE.tmp" && mv "$HELGE_TERMINAL_RESUME_FILE.tmp" "$HELGE_TERMINAL_RESUME_FILE"
```

`SessionStart` fires again on resume, clear and fork, which is when the id
changes, so the declaration stays current.

### Foreground process sampling

At each layout save (not on the PTY path), for each pane:

1. Ask for the foreground process group of the PTY, pick its leader.
2. If it is the pane's shell, the pane is "at a shell": no rule recipe.
3. Otherwise read executable path, argv and cwd, and evaluate the rules.

Cost is a few syscalls per pane per save. Environment is never read or stored.

### Persisted state

| Item | Stored | Notes |
| --- | --- | --- |
| Window frame, screen, zoom/fullscreen | Yes | Frame is validated against current screens on restore |
| Tab groups | Yes | Ordered window ids per group, selected tab |
| Pane tree | Yes | Binary tree: leaf(pane id) or split(orientation, ratio, first, second). Ratio, not points |
| Focused pane, key window | Yes | |
| Pane id | Yes | Stable UUID; also becomes the automation id |
| cwd | Yes | Last OSC 7 value; fallback to the foreground shell's cwd by process inspection |
| Title | Yes | Shown until the new shell sets one |
| Launch spec | Yes | Executable and arguments; cwd is taken from the row above |
| Environment | **No** | Too likely to hold secrets; the new shell gets the app's environment as today |
| Font size override | Yes, if per-pane sizes exist at implementation time | |
| Foreground command | Yes | Executable, argv, pid, start time; and the typed command line from OSC 133;C when present |
| Resume recipe | Yes | As above |
| Scrollback | Yes, bounded | Primary history plus primary screen, as text. Default 10,000 rows and 2 MiB per pane, setting 0 to 50,000 rows |
| Alternate screen | No | A full-screen program redraws itself when resumed |
| Terminal modes, images, selection, search | No | Not meaningful for a new process |
| Child exit state | Yes | A pane that had already finished is restored as finished, not relaunched |

Scrollback format: phase 2 stores plain UTF-8 logical lines (soft wraps joined),
which is what the existing bounded copy capture produces. Styled text (SGR
runs) is a phase 4 improvement; the file header carries an encoding field so
both can coexist.

### On-disk layout

Root: `~/Library/Application Support/<bundle id>/Sessions/`, mode 0700, or the
directory given by a `--state-directory` launch option. Keying by bundle id
keeps the fixture app and development builds away from the installed app.

```
Sessions/
  lock                     flock + pid + process start time
  running                  sentinel: exists while an instance runs
  layout.json              current layout snapshot
  layout.previous.json     last generation that loaded successfully
  panes/<pane-uuid>.scrollback
  panes/<pane-uuid>.resume declaration file (option A)
  quarantine/<timestamp>/  state that failed to load or crashed a restore
```

- `layout.json`: `{ "version": 1, "saved_at", "app_build", "clean_exit", "windows": [...] }`.
  Expected size is a few kilobytes.
- `*.scrollback`: small header line (`version`, `encoding`, `rows`, `bytes`,
  `captured_at`, checksum of the body) followed by the body.
- All files 0600. The directory is excluded from backups.

### Write cadence and crash safety

| Write | Trigger | Bound |
| --- | --- | --- |
| Layout | Structural change (split, close, tab, move, resize end, focus, cwd or title change, recipe change), debounced 1 s; nothing is written when nothing changed | Encoding and I/O on a utility queue; main thread only gathers values it already has |
| Scrollback checkpoint | Pane is dirty (new output since its last checkpoint) and has been quiet for 2 s; or dirty for 60 s under continuous output | One pane at a time; capture runs on the pane's session queue in the existing bounded turns and yields to input; encode and write on a utility queue |
| Flush everything | Clean quit, `NSWorkspace.willPowerOffNotification`, `willSleepNotification`, window close | Inside the existing 3 s termination window; panes not captured in time keep their last checkpoint |

Rules:

- **Atomic replace.** Write `name.tmp`, `fsync`, `rename`. Layout additionally
  uses `F_FULLFSYNC` on flush events only, never on the debounced path.
- **Two generations.** A layout that loads successfully is copied to
  `layout.previous.json` before the next write replaces it. A scrollback file
  whose checksum fails is ignored; the pane restores without history.
- **No journal of PTY bytes.** Logging raw output would put disk I/O on the
  throughput path, grow without bound and record everything ever printed.
- **No timers when idle.** An idle app has no dirty panes and schedules
  nothing; the measured idle cost in `docs/status.md` must not move.
- **Never on the PTY read lane.** The only cost added to output handling is
  setting a per-pane dirty flag.
- **Off in fixtures.** Persistence and restore are disabled whenever the app
  is launched with `--execute` or any smoke or benchmark flag, unless
  `--state-directory` is given.

Worst-case loss after a hard reset: layout changes from the last second,
scrollback from the last 60 s of a busy pane, and a recipe declared in the
last second.

### Restore

Decision at launch:

| Condition | Action |
| --- | --- |
| Launch arguments present (other than `--state-directory`) | No restore, no persistence |
| `running` sentinel present, lock not held by a live process | Unclean exit: restore |
| Clean exit recorded | Restore if "Restore windows at launch" is on (see open questions) |
| Sentinel shows the previous launch died **during** restore | Do not restore; move state to `quarantine/`, open one window, show a notice with a "Try restoring again" action |
| Another live instance holds the lock | Run without restore or persistence |

Per pane:

1. Create the pane with its saved id and split position.
2. Feed the saved scrollback into the emulator **before** spawning the child,
   so it does not depend on shell integration and works for every shell.
3. Append one marker row: `Restored · session ended 2026-11-10 14:02 · not shut down cleanly`.
4. Restored rows render dimmed. They are ordinary history: selectable,
   searchable, copyable.
5. Spawn the default shell in the saved cwd.
6. If the pane has a valid recipe, show a strip under the pane header:
   `Was running: Claude Code (session 0b6c…) · Resume ⏎ · Edit · Dismiss`.
   A guess reads `Resume most recent in this directory`.

Consent rules:

- Nothing is run automatically by default. "Resume" types the quoted argv into
  the fresh shell and presses return, so the result is visible, uses the
  user's PATH and aliases, and lands in shell history.
- "Resume all" in the Shell menu runs every offered recipe.
- A rule can be marked trusted in settings ("resume automatically"). Trust is
  per rule id, never global, and applies only to `exact` recipes.
- A `command-line` recipe (option C) can only be inserted at the prompt
  without return.
- Recipes from a declaration file are shown with their full argv before first use.

Class c (child exits while the app runs): the finished pane gains
`Restart` (same launch spec, same cwd) and, if a recipe exists, `Resume`.

### Privacy and security

| Concern | Decision |
| --- | --- |
| Secrets in scrollback | Files are 0600 in a 0700 directory, excluded from backups. Same exposure as shell history and the agents' own transcripts, which are plaintext in the home directory |
| Opt-outs | Global setting "Save scrollback for recovery" (off keeps layout and cwd only); per-pane "Don't save this pane"; `HELGE_TERMINAL_NO_PERSIST=1` in a pane's environment at launch |
| Password entry | Typed passwords are not echoed, so they are not in scrollback. Commands that print secrets are |
| Command lines | Stored for the foreground process only, not a history. The settings text says so |
| Environment | Never stored |
| Lifetime | A pane's files are deleted when the user closes the pane or window. Restored-and-dismissed state is deleted. Quarantine is pruned after 14 days |
| Planted recipes | Declaration files are writable only by the user's own processes. No escape-sequence channel in the first version. Nothing auto-runs without per-rule trust |
| Encryption | Not in the first version. kitty encrypts its logout state with a login-keychain key; doing the same here adds keychain prompts for ad-hoc-signed development builds and protects only against other users and offline disk access, which FileVault already covers. Listed as an open question |
| Clear Screen | Command-K also drops the pane's saved scrollback at the next checkpoint, since the checkpoint mirrors live history |

### Failure handling

| Failure | Behaviour |
| --- | --- |
| `layout.json` missing, truncated or invalid | Use `layout.previous.json`; if that fails, start empty and quarantine both |
| Unknown newer `version` | Do not load, do not overwrite; keep the file as `layout.v<N>.json` and start empty |
| Older `version` | Migrate in memory through explicit steps; write the new version only after a successful restore |
| Scrollback checksum mismatch | Pane restores without history; marker row says so |
| cwd missing or not a directory | Nearest existing ancestor, else the preference starting directory; marker row names the original path |
| Screen configuration changed | Clamp frames to visible screens; keep sizes where possible |
| Pane tree deeper or wider than the window allows | Existing `reconcileLayout` minimum-size logic applies; ratios are clamped |
| Recipe program not found | The shell reports it; nothing else happens |
| Shell fails to launch | Existing "Unable to start the shell" path |
| Restore crashes the app | Next launch quarantines the state (see table above) |
| State directory unwritable | Persistence turns off for the run, one log line, no alert loop |
| Limits | 32 windows, 256 panes; beyond that the newest are kept and a notice is logged |

## PTY-holding helper (failure class a)

What it would be: a small "session host" process that owns the PTY masters and
the children. The app receives each master fd over a Unix socket
(`SCM_RIGHTS`) and reads it directly, so the throughput path is unchanged. If
the app dies, the host keeps the children; a new app instance reconnects.

| | Assessment |
| --- | --- |
| Value | Programs survive an app crash, force quit, and **app update**. The last one matters now: releases already wait on live sessions. No value for reboot or power loss |
| Screen state | The emulator lives in the app and dies with it. After reattach the app has only the last checkpoint. Shell panes look right after the restored history; full-screen programs need a forced redraw and can be left in a mismatched mode (mouse, keyboard protocol, alternate screen) because modes are not known exactly |
| Output while detached | The host must either buffer (bounded, then drop or block) or stop reading (child blocks). Either is a visible behaviour to specify and test |
| Lifecycle | New failure modes: orphaned hosts, version skew between a new app and an old host, hosts surviving uninstall, children outliving every window. "Closing the last window reaps all children" stops being true by construction |
| Platform | Needs a second signed, notarized executable (the launcher already sets the precedent). Whether a double-forked host survives app termination under launchd is unverified. Child processes' privacy-permission attribution may change; the Downloads authorization problem in `docs/status.md` suggests this area is already fragile |
| Complexity | Largest item in this plan: protocol, reconnection, host upgrade, and a new test matrix. iTerm2's design note shows a multi-year evolution from per-session servers to a multi-server |
| Cheaper alternative | Run the shell inside tmux or zellij for panes that must survive (what cmux offers as `local-tmux`). Works today with zero terminal code |

Recommendation: do not start it until phases 1 to 4 are in daily use. Then run
a time-boxed spike that answers the unverified platform questions with a
throwaway host and a fixture app. Decide after the spike. If Helge's main pain
is updates, a narrower "hand off fds to the new app version" may be enough and
is far smaller than a persistent host.

## Roadmap

| Phase | Scope | Acceptance criteria |
| --- | --- | --- |
| 0. Foundations | Value-type layout model derived from, and able to build, the split-view tree; stable pane ids; state directory, lock, sentinel; `--state-directory`; persistence off under smoke and benchmark flags. No user-visible change | Layout round-trips (views → model → views) for single, nested and closed-pane cases with ratios within one cell. Throughput and idle measurements unchanged. Existing suites pass |
| 1. Layout and cwd restore | Layout saves, atomic two-generation writes, restore at launch, crash-loop guard, corrupt-state handling, missing-cwd fallback, setting to turn it off | After `kill -9` of a fixture with 3 windows, 2 tab groups and nested splits, relaunch reproduces the same tree, ratios, tab order, focus and cwds. Every corrupt-file case in the fault matrix ends in a usable window. A kill during restore does not loop |
| 2. Scrollback | Dirty and idle gated checkpoints, flush on quit, power-off and sleep; restore into the emulator before spawn; dimmed rows and marker row; row and byte limits; per-pane and global opt-out; Command-K interaction | After `kill -9`, each pane shows its last checkpointed text, at most 60 s stale, with the marker. Restored text is searchable and copyable. With 20 panes under sustained output, whole-app throughput and input latency are within run-to-run noise of persistence off. Idle app schedules no work |
| 3. Recipes | Pane environment variables and declaration file; foreground sampling; rules engine and bundled default rules file; resume strip, "Resume all", per-rule trust; finished-pane Restart; `OSC 133;C` command line in the zsh hook and emulator | With a fake agent: a declared recipe is offered after `kill -9` and resumes the exact session. A recipe whose owner had exited is not offered. A rule match without a session offers the fallback, labelled as a guess. Nothing runs without a click unless the rule is trusted. No agent name in `Sources/` |
| 4. Agent pack and hardening | Rules and hook snippets for Claude Code and Codex with install notes; styled scrollback; version migration test; settings pane; documentation in `docs/usage.md` | Manual run in a disposable directory: Claude Code and Codex sessions are offered and resume the right conversation when two agents shared one cwd (hook route). A version 1 state file loads in a build that writes version 2 |
| 5. Session host (optional) | Spike, then decision | Spike report answers: survival of the host on app death, fd hand-off, signing, permission attribution, redraw behaviour of three real full-screen programs |

Phases 0 to 2 fix today's loss of layout and context. Phase 3 brings the
agents back. Each phase is independently shippable.

## Test strategy

Safety rules, applying to every test:

- Tests run only against the **fixture app** (separate bundle id) or a
  development build started with `--state-directory` pointing at a fresh
  temporary directory. The state directory of `no.helgesverre.terminal` is
  never read or written by a test.
- A test kills only the pid it started, by number. No name-based kills.
- The child shell in a fixture uses a private `ZDOTDIR` and a temporary home
  directory for agent files, so real `~/.claude` and `~/.codex` are untouched.
- No test installs or modifies the installed app.

| Level | What | How |
| --- | --- | --- |
| Unit | Layout codec, version migration, limits, frame clamping, rule matching, template expansion and quoting, recipe validity (owner pid), checkpoint scheduling policy | Directly compiled test programs like the existing `Tests/TerminalTests`, with an injected clock and file system root |
| Fault matrix | Every file state a crash can leave: missing, empty, truncated at each byte boundary of a small sample, wrong checksum, stale `.tmp`, only `previous` present, newer version, unwritable directory | Table-driven loader test; each case must produce a defined outcome |
| Crash points | Death at each step of a write | A test-only environment variable makes the writer stop at a named step (before temp write, after temp write, after sync, after rename); the harness sends SIGKILL at that point, relaunches, and checks the result is either the old or the new generation, never neither |
| `kill -9` integration | Whole-app recovery | Fixture builds a known layout through the AppleScript dictionary, prints marker text in each pane, waits one checkpoint, is killed, relaunched, and inspected through AppleScript and accessibility |
| Simulated power loss | Children die at the same instant as the app | SIGKILL the fixture's whole process tree at once, at random times across many iterations, including during checkpoints; assert the invariants above. This cannot test disk-cache loss |
| Real power loss | Durability of the sync strategy | Manual, occasional: run the fixture in a disposable macOS virtual machine and force it off. Not part of CI. Never on Helge's machine |
| Recipes | Declaration, sampling, rules, consent | A scripted fake agent that writes a session file and a declaration, records how it was relaunched, and can be told to exit before the kill |
| Performance | No regression | Existing throughput and latency benchmarks with persistence on and off in the same run; the 60 s idle measurement with persistence on |
| Manual | Real agents | Phase 4 checklist in a scratch repository with real Claude Code and Codex |

## Non-goals

- Restoring a process's memory or in-flight work. An agent's interrupted tool
  call, background shells and subagents are gone after a reboot.
- Keeping programs alive across reboot. Nothing local can.
- Re-running arbitrary commands automatically.
- Restoring alternate-screen content, images, terminal modes, selections or search state.
- Remote sessions: an ssh pane restores as a local shell in its last local cwd.
- Using AppKit window restoration.
- Syncing state between machines.
- A built-in multiplexer.

## Open questions for Helge

1. **Restore after a normal quit?** Proposed: always after an unclean exit; after
   Command-Q controlled by a setting, default on. Alternative: unclean exit only.
2. **Automatic resume.** Proposed: never by default, per-rule trust available.
   Do you want trusted rules to resume without a click from day one?
3. **Scrollback amount.** Proposed default 10,000 rows / 2 MiB per pane. With
   50 panes that is up to 100 MiB on disk. Higher, lower, or match the history limit?
4. **Plain or styled scrollback first?** Plain text ships sooner; colours come in phase 4.
5. **Encryption at rest.** Proposed: none, rely on file modes and FileVault.
   Do you want keychain-backed encryption despite development-build prompts?
6. **Where does the agent pack live?** Bundled default rules in this repository,
   or a separate repository that only drops files into the rules directory?
7. **Hook installation.** Should the pack only document the snippets, or ship a
   command that edits `~/.claude/settings.json` and `~/.codex` hook config?
   The second touches files the terminal does not own.
8. **Environment variable names.** `HELGE_TERMINAL_PANE_ID` and
   `HELGE_TERMINAL_RESUME_FILE` follow the existing prefix. Acceptable as a
   public interface that third-party hooks will depend on?
9. **Closed tabs.** Should a deliberately closed window be recoverable
   ("Reopen Closed Tab"), or is deletion on close correct?
10. **Phase 5.** Is losing sessions on app update or app crash painful enough to
    fund the spike, or is "run tmux in the panes that matter" acceptable?
11. **Second instance.** A development build started while the installed app
    runs: proposed to key state by bundle id, and to run a second instance of
    the same bundle id without persistence. Agreed?
