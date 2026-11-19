# Session handoff: replacing the app under running programs

Status: experimental, off unless enabled. Verified locally with real programs
on 2026-11-18, including an update installed by Sparkle from a local feed
(`just update-rehearsal`, below). Evidence is in
[reports/session-handoff-2026-11-18](../reports/session-handoff-2026-11-18/README.md).

A terminal's programs normally end with it: quitting closes each PTY and the
kernel hangs the programs up. Handoff lets the app be replaced, by a relaunch
or an update, while shells, editors, agents and anything else in its panes
keep running. The new app shows the same windows, tabs and splits, with the
same processes behind them.

## Enabling it

| Copy | How |
| --- | --- |
| Installed app | `defaults write no.helgesverre.terminal KeepSessionsAcrossRelaunch -bool true`, then restart it once |
| Development build | Pass `--handoff-directory DIRECTORY` |

When enabled, the app menu has **Relaunch Keeping Sessions**, and an update
installed through Sparkle hands the sessions to the new version. An ordinary
Quit is unchanged: it ends the programs.

A development build never uses the installed app's handoff directory, so it
cannot take over the installed app's panes.

## How it works

1. **Copy the PTYs.** The app duplicates each pane's PTY descriptor and starts
   a *keeper*: its own executable run with `--session-keeper`, in a new
   session, holding only those descriptors. Until the keeper is listening,
   nothing has changed and a failure costs nothing.
2. **Detach.** Each session stops reading, finishes parsing what it has read
   (including a sequence cut in two by the last read), writes out replies it
   owes, and captures its terminal. It no longer owns its child: closing the
   session does not hang the child up.
3. **Leave a manifest.** The handoff directory gets `manifest.json` (the
   window layout as crash recovery saves it, the keeper's socket, and one
   record per pane) and each pane's terminal as `PANE.content` and
   `PANE.state`.
4. **Quit.** The app exits normally. Each program's parent is now `launchd`;
   the keeper's copies of the PTYs are what keep them from being hung up.
5. **Claim.** The next app to start with the same handoff directory reads the
   manifest, connects to the keeper's socket, receives the descriptors
   (`SCM_RIGHTS`), acknowledges, and the keeper exits. The directory is
   removed: a handoff is claimed once.
6. **Adopt.** The windows are rebuilt from the layout. Each pane with a
   running program gets a session that restores the saved terminal and reads
   and writes the received PTY. Nothing is started again. A program is
   adopted only if its process ID still belongs to the process that was
   handed off, checked by the start time the manifest records; the same
   check precedes every signal an adopted session sends, because a process
   ID can pass to an unrelated process once the program has ended.

The keeper never reads a PTY. A program that writes while the app is away
blocks once the kernel's buffer is full, as behind a slow terminal, and
continues when the new app starts reading. A keeper that is not claimed
within 15 minutes exits, which hangs the programs up as closing their windows
would have.

## What is carried

`TerminalHandoff` (engine) holds a terminal in two parts so that a newer
build can read what an older one wrote:

- `content`: ordinary terminal output that paints history and the screen, and
  the alternate screen when it is in use, into a fresh terminal of the same
  size: text, colors, underline styles, hyperlinks, protection and soft
  wrapping.
- `state`: JSON for what output cannot say: both screens' cursors and saved
  cursors, margins, Kitty keyboard flags and stacks, cursor visibility and
  shape, the pen, character sets, modes (application cursor and keypad,
  bracketed paste, focus and mouse reporting, modifyOtherKeys, origin, wrap
  and insert), tab stops, titles, the working directory and color overrides.
  Unknown keys are ignored and missing ones keep the terminal's defaults. A
  state this build cannot read still restores the rows.

Because the restored terminal answers every query as the old one did and the
PTY's size is unchanged, a program sees no resize, redraws nothing and cannot
tell that the app changed. While the new windows are being laid out, a pane's
intermediate sizes are not sent to an adopted program. When the windows are
laid out the app says so, and only the size the pane then has is sent, if it
differs from the saved one. A session whose host never says so stops waiting
after 2 seconds.

## What is not carried

| Lost | Effect |
| --- | --- |
| Images (Kitty, Sixel, iTerm2) | Disappear until the program draws them again |
| OSC 133 command marks | Command navigation does not reach commands run before the handoff |
| Selection, search and scroll position | Cleared; the view follows the tail |
| Title stack, pending clipboard and download offers | Dropped |
| The child's exit status | The new app is not the parent, so a program's exit is seen but its status reads as 0 |
| Output during the gap | Not lost, but delayed: writers block until the new app reads |

## Limits and open questions

- **Sparkle is rehearsed, not released.** `Updates` postpones the relaunch
  until the handoff has finished (`shouldPostponeRelaunchForUpdate`). The
  rehearsals below show Sparkle then installing and relaunching with the
  sessions adopted: with Developer ID signed, notarized copies, through
  Sparkle's own windows, and, separately, taking the published release from
  the published feed. What no rehearsal can show is a released version that
  contains handoff updating to a later one; no such release exists yet.
- **One stall was seen and not reproduced.** The first rehearsal through
  Sparkle's windows left the old copy waiting in its quit: it had been asked
  to quit twice and the second request waited for an answer already given.
  That wait is fixed. What caused the second request is not known; seven
  further runs passed.
- **A failed claim loses the sessions.** If the new app cannot read the
  manifest or reach the keeper, it starts normally and the keeper times out.
- **A failure after detaching loses the sessions.** The keeper is started
  before any session is touched, so this needs a write failure in the handoff
  directory. The keeper is then ended, which hangs the programs up at once,
  and the app quits or relaunches as it was asked to.
- **One app instance per handoff directory** is assumed.
- **Layout below a pane's minimum size is not restored exactly**, which
  resizes those panes once.
- The handoff smoke below is an in-app diagnostic started by hand. Neither
  it nor the update rehearsal is part of `just test`: both open windows and
  run for up to a minute.

## Code

| Piece | Where |
| --- | --- |
| Capture and restore of a terminal | `Sources/TerminalEngine/Emulation/TerminalHandoff.swift`, `TerminalHandoffBridge` |
| Detach, adopt and PTY copy | `TerminalSession.detachForHandoff`, `init(adopting:launch:)`, `duplicatePTY` |
| Descriptor passing | `Sources/TerminalInterop/Descriptors.c` |
| Keeper | `Sources/Terminal/SessionKeeper.swift` |
| Manifest, handing off and claiming | `Sources/Terminal/SessionHandoff.swift` |
| Smoke harness (diagnostic builds) | `Sources/Terminal/HandoffSmoke.swift` |
| Update rehearsal | `tools/Dev/UpdateRehearsal.swift`, `Sources/Terminal/UpdateRehearsal.swift` |

Tests: `TerminalHandoffTests` (round trips, including a second-generation
capture being identical), `SessionHandoffTests` (a child surviving two
handoffs with its screen and input), `SessionKeeperTests` (the keeper
process, the claim rules and where handoff is allowed).

## Rehearsing an update

```shell
just update-rehearsal                      # a shell, vim and a program that keeps printing
just update-rehearsal --scenario FILE      # your own programs, in the smoke's scenario format
just update-rehearsal --signed             # Developer ID, hardened runtime, notarized update
just update-rehearsal --windows            # Sparkle's own windows, buttons pressed for you
just update-rehearsal --manual             # Sparkle's own windows: you click Install
just update-rehearsal --published          # the published release from the published feed
just update-rehearsal --keep-open          # leave the updated copy open to look at
```

| Option | What it adds | Needs |
| --- | --- | --- |
| `--signed` | Both copies signed as a release is; the update notarized and stapled; Gatekeeper's verdict on the bundle Sparkle installed | A Developer ID Application identity and the notary profile of `just release`. Uploads the rehearsal build to Apple's notary service |
| `--windows` | Sparkle's standard windows instead of silent acceptance; the command presses Install Update and Install and Relaunch | Accessibility permission for the app running the command |
| `--published` | The installed copy keeps the release's feed and key, so Sparkle downloads the published release, checks it with the published key and installs it. Implies a signed installed copy | Network. The published release decides what survives; one without handoff adopts nothing |

Options combine, except `--manual` with `--windows`.

Nothing is published and the installed app is not involved. The command:

1. builds the development bundle and makes two copies of it under the bundle
   identifier `no.helgesverre.terminal.update-rehearsal`, in
   `~/Library/Caches/no.helgesverre.terminal.update-rehearsal/RUN`: an
   "installed" copy numbered 0.0.1 (1) and the current version as its update;
2. makes an update key for the run, puts its public half in both copies,
   archives the update and signs the archive with the private half;
3. writes the appcast with the production generator and serves it and the
   archive on a loopback port;
4. starts the installed copy. It opens one pane per scenario entry, runs the
   commands, then asks Sparkle for the update. Sparkle downloads, verifies,
   waits for the handoff, replaces the bundle and relaunches;
5. waits for the relaunched copy's report and fails unless the bundle on disk
   and the copy that adopted the sessions are both the new build and every
   pane passed the smoke's checks.

The copies read their instructions from an `TerminalUpdateRehearsal` entry in
their Info.plist, because Sparkle relaunches an app without arguments. Only
diagnostic builds read it. Runs older than an hour are deleted by the next
run.

A scenario may set `columns` and `rows` for the window, `extraTabs` and
`extraWindows`. A copy under this identifier has default preferences, so its
shells start in the home folder: begin a command with `cd` where that
matters.

## Running the smoke

```shell
just build
mkdir -p reports/handoff && cat > reports/handoff/scenario.json <<'JSON'
{"settle": 14, "rounds": 3, "panes": [
 {"name": "shell", "command": "echo before", "probe": "echo HANDOFF_$((6*7))\r", "expect": "HANDOFF_42"},
 {"name": "htop", "command": "htop", "animated": true},
 {"name": "nvim", "command": "nvim -u NONE", "probe": "ihello\u001b", "expect": "hello"}
]}
JSON
open -n dist/Terminal.app --args --background --columns 250 --rows 70 \
  --handoff-directory "$PWD/reports/handoff/handoff" --handoff-smoke "$PWD/reports/handoff"
```

The app opens one pane per entry, runs each command, hands off and relaunches
itself `rounds` times, and writes `round-N.json`: for each pane, whether the
process and its descendants are the same, whether the grid and screen came
back, whether an animated screen still changes and whether the probe's
expected text appeared. With `"externalRelaunch": true` it exits after
handing off, so the caller can replace the bundle before starting it again.
