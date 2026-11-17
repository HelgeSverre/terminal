# Using Terminal

## Homebrew

```sh
brew install --cask helgesverre/tap/helge-terminal
brew upgrade --cask helgesverre/tap/helge-terminal
brew uninstall --cask helgesverre/tap/helge-terminal
```

Homebrew installs `Helge Terminal.app` in `/Applications`. Uninstalling removes
the app and retains preferences. Building from source with `just install` uses
`~/Applications` instead.

## Shell and working directory

Terminal starts `$SHELL`, falling back to `/bin/zsh`, with its normal login
configuration. Set a starting folder in **Settings → Startup → Directory**.
Use `~/code` to start new windows there. An empty field or `~` uses your home
folder; a saved folder that disappears also falls back to home.

The setting applies to new shells. A split inherits the active pane's reported
local working directory. Bundled zsh, Bash (non-login) and fish prompt hooks
report that directory while preserving your startup files. Shells without directory reporting use the
configured starting folder.

Override the folder for a development launch with:

```sh
just dev --working-directory /tmp
```

Closing the last window quits the app and shuts down its terminal sessions.

## Pane titles and focus

The window title follows the active pane. Background programs can update their
own pane titles without changing the window title.

Split panes show a thin title header. Right-click it, or click its color button,
to choose one of 18 muted colors or enter a custom hex value. Click outside the
palette to dismiss it. A color chosen this way belongs to the open pane and is
forgotten when it closes.

**Settings → Panes** can hide the headers, set inactive dimming to Off, 5%,
10%, 20% or 50%, and choose the default header color from the same palette.
Dimming defaults to 5%; the focused pane and any hovered pane stay fully
visible. The default color is the darkest gray (`#18191C`); panes without
their own color follow it, including panes that are already open.

## Keyboard

| Action | Shortcut |
| --- | --- |
| New window | ⌘N |
| New tab | ⌘T |
| Split right | ⌘D |
| Split below | ⇧⌘D |
| Close focused pane | ⌘W |
| Quit | ⌘Q |
| Copy selection | ⌘C |
| Paste | ⌘V |
| Select visible output | ⌘A |
| Find in scrollback | ⌘F |
| Next / previous match | Return / ⇧Return, or ⌘G / ⇧⌘G |
| Close the find bar | Esc |
| Increase / decrease font size | ⌘+ / ⌘− |
| Start / end of shell line | ⌘← / ⌘→ |
| Previous / next word | ⌥← / ⌥→ |
| Clear input line | ⌘Backspace |
| Clear screen and scrollback | ⌘K |

With the configured zsh end-of-line binding, ⌘→ accepts an autosuggestion.
Application and shell bindings can affect line editing.

⌘K clears the primary screen's scrollback and redraws a marked shell prompt.
Alternate-screen applications keep their screen contents.

## Selection, history, and links

Drag to select characters, double-click for a word, triple-click for a line,
or hold Option while dragging for a rectangle. Hold Shift to select locally
when an application has enabled mouse tracking. **Settings → Text → Word
characters** controls the extra punctuation included in word selection.

Selection follows its text as output scrolls and panes resize. Overwritten or
evicted selections clear with a brief notice. Scrolling back keeps your reading
position as new output arrives; typing returns to the live screen when
**Scroll to bottom when typing** is enabled. Returning from an alternate-screen
program restores the primary screen's scroll position.

Hold Cmd over an HTTP, HTTPS, or mailto URL to underline it, then Cmd-click to
open it. Plain URLs and OSC 8 hyperlinks use the same link actions. Dropping
files into a pane pastes their quoted paths.

## Crash recovery

After an unclean exit, the next launch restores windows, tab groups, split
panes, working directories and the latest plain-text history checkpoint. The
history is faint and ends with a dated `Restored` marker. Each pane starts a
fresh login shell; processes are not reattached. Quitting normally, closing the
last window, and an orderly logout or restart discard saved sessions.

A recognised program has a `Resume` and `Dismiss` strip. `Shell > Resume All`
accepts every current offer. Nothing runs until one of these actions is used.
An offer without an exact session ID says `most recent in this directory`;
two programs sharing a directory can select the same conversation with this
fallback. A previous broad-permissions flag is labelled on the strip and is
not copied into the resume command.

Installed copies under `/Applications` or `~/Applications` keep state in
`~/Library/Application Support/no.helgesverre.terminal/Sessions`. Other copies
write no recovery state unless launched with `--state-directory <directory>`.
State is readable by this user only. It contains printed history, pane titles,
directories and session IDs in plain text; it does not contain the environment
or unechoed input. History is bounded by the existing scrollback setting and
the 16 MiB copy limit per pane. Idle panes schedule no checkpoint work.

For an exact agent session ID, an optional agent `SessionStart` hook can write
to the pane-specific `HELGE_TERMINAL_RESUME_FILE` path. Configure this command
through the agent's hook mechanism; the terminal does not edit its settings:

```sh
[ -n "${HELGE_TERMINAL_RESUME_FILE:-}" ] || exit 0
jq -c '{rule: "claude-code", session: .session_id}' > "$HELGE_TERMINAL_RESUME_FILE.tmp" \
  && chmod 600 "$HELGE_TERMINAL_RESUME_FILE.tmp" \
  && mv "$HELGE_TERMINAL_RESUME_FILE.tmp" "$HELGE_TERMINAL_RESUME_FILE"
```

For Codex, replace `claude-code` with `codex`. A hook can name only a shipped
rule and a validated session ID. It cannot supply a command. The terminal
offers the record only when that rule also matched the pane's foreground
program at its last sample. Agent-specific hook inheritance and real-agent
resume behavior are tracked separately in the [recovery plan](session-recovery-plan.md).

## Text and settings

Settings > Text has a font menu. Obel Mono is the default; JetBrains Mono,
Fira Code, Hack and IBM Plex Mono also come with the app, and the fixed-pitch
fonts installed on the Mac are listed under them. Symbols Nerd Font Mono
supplies missing icon glyphs for every font. "Join ligatures" draws `->`,
`!=` and the like joined in fonts that have ligatures (JetBrains Mono and
Fira Code among the bundled ones). "Join emoji sequences" is on by default;
turn it off if zsh overwrites its prompt while you edit a line holding an
emoji with a skin tone, a flag or a joined emoji. Sources and licenses are in the
[font directory](../Sources/TerminalUI/Resources/Fonts/README.md).

The font-size number field accepts 8–40 pt. Use its stepper or press Up/Down to
adjust the value. Settings also controls scrollback, following output on input,
and whether Option sends an Escape prefix. Option-arrow word movement remains
available in either Option mode. Per-side Option, cursor style, visual bell,
shell profiles, shortcuts and themes are in [desktop controls](desktop-controls.md);
find options are in [search](search.md).

Programs honor an inherited `NO_COLOR`. If an automation shell sets it
implicitly, open the app with:

```sh
env -u NO_COLOR just open
```

## Protocols and automation

Shells receive `TERM=xterm-256color`, `COLORTERM=truecolor`, and
`TERM_PROGRAM=HelgeTerminal`. The [terminfo guide](terminfo.md) explains that
compatibility choice and the bundled capability description.

Three image protocols are shown, all within one 64 MiB budget and up to
4096 pixels a side:

- Kitty graphics: RGB, RGBA, PNG and palette-indexed data, zlib compression, chunking, data in the
  escape code, a file, a temporary file or shared memory, image numbers,
  placement, layering, image/placement deletion, and Unicode placeholders, as
  tmux and Neovim image plugins use, placements relative to another
  placement, and animation: frames built on a base frame, composition, and
  playback that stops, waits on the last frame or loops a set number of
  times. Up to 1,000 frames an image, within the same budget.
- Sixel, which the terminal reports in its device attributes, with background,
  aspect ratio, palette registers and display modes.
- iTerm2 inline images (`OSC 1337 ; File=…;inline=1`) in any format macOS
  decodes, sized in cells, pixels or percent. Animated GIFs play and multipart
  transfers are accepted. A file sent without `inline=1` is offered in the
  pane as a download: nothing is written until you choose Save and a
  destination. Files that arrive while one is offered wait their turn in
  that pane; Dismiss refuses all of them.

Support is bounded rather than complete. The [protocol coverage audit](protocol-coverage.md)
records the tests and the limits: indexed animation edits, budgets and client
combinations that are not yet qualified.

OSC 52 clipboard writes are allowed without asking and have payload limits;
clipboard reads are denied. See the [clipboard policy](osc52-clipboard.md).

Accessibility exposes pane text, ranges, selections, and link actions.
AppleScript provides explicit commands for sending text, reading screens,
managing windows and panes, and updating validated settings. The
[automation guide](automation.md) documents the commands and bounds.

### Switching tabs

Press Cmd+1 through Cmd+8 to select a tab by its position. Cmd+9 selects the
last tab. Cmd+Option+Left and Cmd+Option+Right select the previous or next tab,
wrapping at the ends. These shortcuts apply to the current window's tab group.
A shortcut for a tab that does not exist does nothing.
