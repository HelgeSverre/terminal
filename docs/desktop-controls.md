# Desktop controls

Settings applies changes to open panes and saves them for new panes. Existing
shells keep their running command and directory. Font family, size, ligatures,
emoji clustering, scrollback and word selection remain available in their
existing sections.

## Keyboard, cursor and bell

Keyboard has independent Left Option and Right Option choices. Each can follow
the original Option setting, compose native characters, or send Escape. Option
arrows continue moving by word. Physical keyboard/input-source qualification is
separate from these saved policy choices.

Appearance can follow the application's cursor requests, or choose a blinking
or steady block, underline or bar. Applications still control cursor visibility.
Visual bell briefly outlines the pane, at most once per 750 ms; hidden windows
do not animate and BEL does not play a sound.

## Profiles, shortcuts and colors

General → **Profiles, Shortcuts & Theme…** opens a native JSON editor. Its Add
buttons insert working examples. Use Configuration updates the Settings draft;
Apply saves it. Cancel discards the draft. Import accepts the same JSON format,
with a 128 KiB limit. Every key is optional; a profile needs `id`, `name` and
`executable`. Unknown keys are ignored. Saved data that no longer validates
falls back to defaults for the session and stays stored until a new
configuration is applied.

An example with a non-login Bash profile:

```json
{
  "profiles": [
    {
      "id": "bash",
      "name": "Bash",
      "executable": "/bin/bash",
      "arguments": [],
      "directory": "",
      "environment": {}
    }
  ],
  "defaultProfile": "bash",
  "shortcuts": [
    {"action": "zoomPane", "key": "z", "modifiers": ["command", "control"]}
  ],
  "visualBell": true
}
```

The Shell menu opens any saved profile in a new window. `defaultProfile` selects
the profile for ordinary new windows, tabs and split panes; omit it to use the
login shell. Profiles use an absolute executable and an argument array. The app
does not interpret shell syntax in arguments. To run a shell command deliberately,
choose a shell executable and its `-c` arguments. Empty `directory` uses the
normal starting-directory policy. A split inherits the directory the current
pane has reported through shell integration, and otherwise starts where the
profile does.
The executable and directory must exist when launched. A missing default profile
executable or directory falls back to the login shell.

Shortcut actions are `newWindow`, `newTab`, `splitRight`, `splitBelow`,
`focusLeft`, `focusRight`, `focusUp`, `focusDown`, `zoomPane`, and
`movePaneToWindow`. A shortcut needs one lowercase ASCII key and `command`,
optionally `shift`, `option` and `control`. Standard editing/window shortcuts
are reserved. Conflicting actions, including unchanged defaults, are rejected;
remap both actions when moving a key. Removing an override restores its default.
Command-1 through Command-9 remain assigned to numbered tab navigation.

Add Theme inserts all five terminal colors and sixteen ANSI colors. Edit them as
`#RRGGBB`. These colors become the terminal's reset defaults; applications can
still set their own colors with terminal protocols. Remove `theme` to restore
the built-in palette. `cursorStyle` can be null or 1–6, in the same order shown
by the Appearance menu. `leftOptionSendsEscape` and `rightOptionSendsEscape`
can be null (follow the original setting), false or true.

## Pane commands

The Shell menu provides directional focus, Zoom Pane and Move Pane to New
Window. Default shortcuts are Control-Command-H/J/K/L for left/down/up/right,
Control-Command-Z for zoom, and Control-Command-N to move the pane. Commands
act on the pane whose canvas or find bar has focus. Splitting, closing, moving
or focusing another pane ends a zoom first.

See [automation](automation.md) for script targeting and bounded reads.

## Downloads offered by terminal programs

A program can offer a bounded file download. A quiet strip at the bottom of its
pane offers **Save filename…** and **Dismiss**. Output alone never opens a dialog
or writes a file. Save opens the native Save panel with a sanitized basename;
the file is written only to the destination you choose. Cancel or Dismiss
releases the offered payload, as does closing its pane. The app accepts one
pending offer across all panes, at most once per second, with a 32 MiB payload
limit. Additional offers are discarded.
