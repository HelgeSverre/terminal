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
local working directory. Bundled zsh prompt hooks report that directory while
preserving your startup files. Shells without directory reporting use the
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

## Text and settings

Obel Mono is bundled in regular, bold, and italic faces. Symbols Nerd Font Mono
supplies missing icon glyphs. Sources and licenses are in the
[font directory](../assets/fonts/README.md).

The font-size number field accepts 8–40 pt. Use its stepper or press Up/Down to
adjust the value. Settings also controls scrollback, following output on input,
and whether Option sends an Escape prefix. Option-arrow word movement remains
available in either Option mode.

Programs honor an inherited `NO_COLOR`. If an automation shell sets it
implicitly, open the app with:

```sh
env -u NO_COLOR just open
```

## Protocols and automation

Shells receive `TERM=xterm-256color`, `COLORTERM=truecolor`, and
`TERM_PROGRAM=HelgeTerminal`. The [terminfo guide](terminfo.md) explains that
compatibility choice and the bundled capability description.

Kitty direct graphics accepts bounded RGB, RGBA, and PNG uploads, including
zlib compression, chunking, placement, layering, and common deletion actions.
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
