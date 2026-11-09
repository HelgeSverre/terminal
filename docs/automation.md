# Automation

Use AppleScript or `osascript` to open windows and tabs, split panes, send shell
commands, read visible output, and save preferences. Target Helge Terminal by
its bundle ID to distinguish it from Apple's Terminal:

```shell
osascript -e 'tell application id "no.helgesverre.terminal" to list panes'
```

The [scripting dictionary](../Resources/Terminal/Terminal.sdef) exposes the
commands below. It does not expose scriptable window, tab, or pane collections,
a current-directory property, or writable preference properties. Discover panes
with `list panes`, target them by ID, and change settings with `configure
preferences`.

## Commands

Parameters marked **optional** may be omitted. Pane-targeted commands use the
focused or last-focused terminal pane when their pane parameter is omitted.

| Scope | Command | Parameters | Result |
| --- | --- | --- | --- |
| App | `list panes` | None | List of pane ID strings across all open terminal windows and tabs |
| App | `show settings` | None | `true` after presenting Settings |
| App | `configure preferences` | Any subset of the settings in the next table; all optional | Text summary of saved font size, scrollback rows, starting directory, and word characters |
| Window | `new window` | None | First pane ID in the new window |
| Tab | `new tab` | None | First pane ID in the new tab |
| Pane | `send text` | Required direct text; optional `to pane` ID | ID of the pane that accepted the text |
| Pane | `read screen` | Optional `from pane` ID; optional integer `max characters` | Most recent part of the displayed text projection |
| Pane | `clear screen` | Optional `in pane` ID | Target pane ID after requesting a display clear |
| Pane | `focus pane` | Optional `pane id` | Target pane ID after making its window key and the pane its first responder |
| Pane | `split right` | Optional `pane id` | New pane ID; the new pane receives focus |
| Pane | `split below` | Optional `pane id` | New pane ID; the new pane receives focus |
| Pane | `close pane` | Optional `pane id` | `true` when the close operation is accepted; closing the last pane closes its window/tab |

`new tab` uses the key terminal window, or the remembered terminal pane's window
when Settings or another window is key. Without either, it creates a terminal
window. To choose a tab's parent explicitly, first use `focus pane` with a pane
in that window.

### Preference parameters

These are named parameters to `configure preferences`, not properties used with
AppleScript's `set` command. Omitted values retain their current settings.

| Parameter | Type and accepted values | Effect |
| --- | --- | --- |
| `font size` | Real number, 8–40 points | Updates open panes and the saved default |
| `scrollback rows` | Integer, 0–50,000 | Updates session history limits and the saved default |
| `option sends escape` | Boolean | Controls Option-key input encoding |
| `follows tail on input` | Boolean | Controls whether terminal input returns the viewport to live output |
| `starting directory` | Existing absolute directory; `~` expands; empty text uses the home directory | Sets the default for newly launched sessions; existing shells keep their working directory |
| `word characters` | Up to 64 Unicode scalars and 256 UTF-8 bytes, without whitespace or controls | Adds characters to Unicode word selection; empty text uses Unicode boundaries alone |

Word characters are saved sorted and deduplicated. `configure preferences`
validates the complete update before saving and applying it through the same
path as Settings' **Apply** button. Saved preferences persist across relaunches;
no relaunch is needed to apply the exposed settings. Session configuration is
queued through each session owner. Settings-only controls, such as pane titles
and inactive-pane dimming, retain their current values when this command runs.

## Keep a pane ID

A returned ID looks like `no.helgesverre.terminal.pane.<uuid>` and remains stable
for that pane's lifetime. The command handlers also accept the UUID suffix, but
using the returned full ID avoids unnecessary conversion. IDs are not persistent
across closing a pane or relaunching the app.

Without an ID, the target is the terminal pane that actually received focus most
recently. This still works when Settings is key or Terminal is inactive. If no
live focused pane is remembered, the command fails instead of choosing another
pane. `list panes` discovers IDs; its list order is not a focus indicator.

```applescript
tell application id "no.helgesverre.terminal"
  set availablePanes to list panes
  if (count of availablePanes) is 0 then
    set targetPane to new window
  else
    set targetPane to item 1 of availablePanes
  end if
  focus pane pane id targetPane
  send text ("pwd" & return) to pane targetPane
end tell
```

`send text` requires nonempty text and queues it through the same PTY input path
as committed terminal text. Append `return` to submit a shell command. Acceptance
means the input was queued, not that the shell command finished. It does not
change focus; `focus pane`, splitting, and closing explicitly focus their target.
Pane focus is separate from selecting terminal text: the dictionary has no text
selection command.

## Create tabs and splits

Save each returned ID so later commands keep their target even after focus
changes. This creates a new window, a right-hand split, and a tab in that window:

```applescript
tell application id "no.helgesverre.terminal"
  set leftPane to new window
  set rightPane to split right pane id leftPane
  send text ("pwd" & return) to pane rightPane
  focus pane pane id leftPane
  set tabPane to new tab
  set lowerPane to split below pane id tabPane
  send text ("printf 'ready\\n'" & return) to pane lowerPane
end tell
```

New windows and tabs use the configured starting directory. A split can inherit
its source session's last displayed, shell-reported directory (OSC 7), provided
it resolves to an existing local directory; otherwise it uses the configured
launch directory. To guarantee a particular working directory, send `cd` to the
pane. This shell example passes the path as an argument and lets AppleScript
quote it for the shell:

```shell
osascript - "$HOME/code" <<'APPLESCRIPT'
on run argv
  set projectDirectory to item 1 of argv
  tell application id "no.helgesverre.terminal"
    set projectPane to new tab
    send text ("cd " & quoted form of projectDirectory & " && pwd" & return) to pane projectPane
    return projectPane
  end tell
end run
APPLESCRIPT
```

To close a pane later, use `close pane pane id projectPane` in a script that has
retained that ID, or rediscover it with `list panes`.

## Read output and wait for a result

`read screen` reads the latest displayed snapshot, including a scrolled viewport;
it does not read all scrollback or wait for pending input. The default limit is
32,768 characters; `max characters` accepts 1–262,144. The result is a suffix
counted in Swift characters (whole grapheme clusters). Its underlying
accessibility projection is itself bounded to 262,144 UTF-16 code units, so a
larger requested limit does not expose hidden history.

Poll for a marker with a bounded wait when a script needs fresh output. The
marker below is assembled by `printf`, so the echoed command does not itself
contain the complete marker. The script returns the displayed output once the
shell prints it:

```shell
osascript <<'APPLESCRIPT'
tell application id "no.helgesverre.terminal"
  set targetPane to new window
  send text ("pwd; printf '\\nREADY:%s\\n' 'automation'" & return) to pane targetPane
  repeat 100 times
    set paneOutput to read screen from pane targetPane max characters 4096
    if paneOutput contains "READY:automation" then return paneOutput
    delay 0.1
  end repeat
  error "Timed out waiting for terminal output."
end tell
APPLESCRIPT
```

A display clear is also queued rather than a completion barrier:

```applescript
tell application id "no.helgesverre.terminal"
  set targetPane to focus pane
  clear screen in pane targetPane
  send text ("printf 'fresh output\\n'" & return) to pane targetPane
end tell
```

## Save settings

```shell
osascript <<'APPLESCRIPT'
tell application id "no.helgesverre.terminal"
  configure preferences font size 15.0 scrollback rows 10000 ¬
    option sends escape true follows tail on input true ¬
    starting directory "~" word characters "_-/.:~"
end tell
APPLESCRIPT
```

Use `show settings` to inspect or edit preferences interactively. **Apply** saves
valid changes and closes the window; **Cancel** closes it without applying the
edits. `configure preferences` saves directly and reloads an open Settings
window; it does not require a separate Apply command.

Invalid or closed pane IDs return AppleScript error `-1728`. Empty text, invalid
read bounds, and invalid preferences return `-1700`; rejected busy/closed input
returns `-1719`. Invalid preference updates leave the saved settings unchanged.

## Accessibility and fixture checks

AppleScript sends Apple Events directly and does not require Accessibility
consent. macOS may require Automation consent for the controlling client.
Accessibility permission is needed by a UI-automation client when it reads the
normal AppKit accessibility tree. Screen `AXValue` and selected text are
read-only; terminal input should use `send text`.

The text area exposes `AXAttributedStringForRange` and `AXStyleRangeForIndex`.
Its bounded UTF-16 projection supplies text, character geometry, fonts, colors,
underline, and strikethrough attributes. Visible links expose AX link elements
with a URL, frame, and Press action. Press revalidates the displayed content
before opening an HTTP, HTTPS, or mailto URL. Synthetic line separators carry no
cell styling. Real VoiceOver behavior still needs validation.

Run the separate-client accessibility check with:

```shell
just accessibility-smoke
```

It tests a private copied app with controlled Unicode/SGR/OSC 8 output, checks
link URL/frame/Press behavior without opening the URL, and reaps the app and PTY
child. It requires Accessibility permission for the client and does not request
that permission automatically.

For real AppleScript command coverage, use:

```shell
just automation-smoke
```

This builds a signed disposable `Terminal Automation Fixture`, uses controlled
PTY children, invokes real `osascript`, and waits for the fixture and its children
to exit. It never targets the installed app or its preferences. Signing setup is
documented in [Releasing](releasing.md). Concurrent fixture runs are rejected.

The check first performs a non-prompting permission query. If macOS requires
consent, run `just automation-consent`, approve the standard dialog, and rerun
the smoke test. Denied permission is reported separately from missing consent.
These commands do not reset or bypass TCC.
