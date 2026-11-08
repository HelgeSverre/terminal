# Automation

Helge Terminal exposes a small AppleScript dictionary for deliberate terminal
automation. It is not UI scripting: screen output remains a read-only
accessibility projection, and scripts never fabricate keyboard events or write
`AXValue`.

Every command uses the last terminal pane that actually received focus when a
pane ID is omitted. This remains reliable while Settings is key or the app is
inactive; if no terminal pane has been focused, the command fails instead of
guessing. Commands that create or split a pane return its stable accessibility identifier, for example
`no.helgesverre.terminal.pane.<uuid>`. Pass that identifier back with the
command's pane parameter to avoid retargeting after focus or layout changes.

```applescript
tell application id "no.helgesverre.terminal"
  set paneID to send text ("printf 'hello\\n'" & return)
  set output to read screen from pane paneID max characters 4096
  set rightPane to split right pane id paneID
  focus pane pane id rightPane
  clear screen in pane rightPane
end tell
```

The commands are `send text`, `read screen`, `clear screen`, `focus pane`,
`split right`, `split below`, `close pane`, `new window`, `new tab`, `list
panes`, and `show settings`. `list panes` is the discovery path when a script
was not the creator of a pane. `read screen` returns at most 32,768 characters by default and
accepts a `max characters` limit up to 262,144. It returns the most recent
part of the same bounded UTF-16 grid projection that accessibility exposes. It
is a current snapshot, not a wait operation; poll it when waiting for output.

To change preferences without UI scripting, use `configure preferences`. It
accepts any subset of `font size`, `scrollback rows`, `option sends escape`,
`follows tail on input`, and `starting directory`. The command fills omitted
values from the current settings, then calls Terminal's normal validation,
save, and live-apply path as one validated update. It returns a short summary of the saved
values.

```applescript
tell application id "no.helgesverre.terminal"
  configure preferences font size 15.0 scrollback rows 10000 ¬
    option sends escape true follows tail on input true ¬
    starting directory "/Users/helge/code"
end tell
```

Invalid pane IDs, a closed/busy input session, invalid read bounds, and invalid
preferences return AppleScript errors. `send text` is ordered through the same
PTY input queue as committed terminal text; it does not press Return for you.

AppleScript controls the running app directly and does not require
Accessibility consent. Accessibility permission is instead required by the
*controlling* UI-automation client (for example agent-desktop) when it reads
the normal AppKit accessibility tree. The terminal's screen `AXValue` and
selected text remain deliberately non-writable.

The terminal text area also supplies `AXAttributedStringForRange` and
`AXStyleRangeForIndex`. The same bounded UTF-16 projection supplies plain text,
character geometry and style runs, including fonts, foreground/background
colors, underline and strikethrough attributes. OSC 8 links expose AX link
elements with a URL, frame and Press action. Press revalidates the link against
the current screen before opening an HTTP, HTTPS or mailto URL. Synthetic line
separators carry no cell styling. Historical text beyond the displayed viewport
and real VoiceOver behavior still need validation.

These use AppKit's [accessibility attributed-string interface](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilityattributedstring%28for%3A%29)
and [AX text attributes](https://developer.apple.com/documentation/appkit/text-attributed-string-attributes-and-constants),
including AX font dictionaries, CGColor values and link element references.

`just accessibility-smoke` checks these attributes from a separate AX client
against a private copied app and controlled Unicode/SGR/OSC 8 output. It verifies
the exported link's URL, frame and Press action without opening the URL, then
reaps the app and PTY child. It requires Accessibility permission for the client
and never requests that permission automatically. This exercises the external
AX interface; it does not replace a VoiceOver reading/selection check.

## Fixture check

Run `just automation-smoke`. It builds the app and creates a signed disposable
`Terminal Automation Fixture`, using the Developer ID application identity in
`~/.config/terminal/release.json` or `APPLE_APPLICATION_SIGNING_IDENTITY`.
The fixture keeps a stable bundle identity so macOS can remember your Automation
decision. It uses controlled PTY children, invokes real `osascript`, and waits
for the fixture application and its children to exit. It never targets the
installed app or its preferences, and concurrent fixture runs are rejected.

The check first performs a non-prompting permission query. If macOS requires
consent, run `just automation-consent` and approve the standard dialog, then
rerun the smoke test. A denied permission is reported separately from missing
consent. These commands do not reset or bypass TCC.
