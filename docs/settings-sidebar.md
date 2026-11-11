# Native settings sidebar

The settings window is an AppKit extension of Terminal's existing charcoal and
yellow visual language. `Sources/Terminal/Settings.swift` owns the window, schema,
and shared field renderer; `Sources/Terminal/Theme.swift` owns its palette.
This document describes the local implementation, not a published release.

The five sections are General, Text, Scrollback, Panes, and Keyboard. The HTML
prototype supplies the sidebar and row structure. Its dynamic section demo and
SidePulse hardware controls are not part of this implementation. The font family
is read-only and reflects `TerminalFont.appKit`, rather than promising a chooser.

## Extending the schema

`Section` holds `id`, SF Symbol `icon`, `title`, `subtitle`, and ordered `fields`.
The `sections` array drives both navigation and panes. Add one section entry to
create both; keep its ID stable for accessibility clients.

`Field` supports `text`, `number`, `check`, `segment`, `readOnly`, and `note`.
`render(_:)` supplies the common label column, optional helper, separator, and
control layout. Reuse an existing field type by adding an entry to `fields`.
`Presentation` is the single owner of a control's accessibility ID, label,
tooltip, and optional width. A genuinely new field type needs one enum case and
renderer case. A new persisted preference also needs a retained control and
explicit integration with `reload()`, `value()`, and `TerminalPreferences`;
the schema does not create persistence or validation automatically.

Controls are created once and retained while their panes are hidden. They hold
the draft, so switching sections preserves edits. `showSection(_:)` ends field
editing before hiding the old pane and updates radio selection together with
pane visibility.

## Appearance

`TerminalTheme.accent` remains `#facc15`. Apply, selected segment fills, the
selected navigation icon, and input focus strokes use this existing yellow.
`TerminalTheme.Settings` scopes the prototype's charcoal neutrals: background
`#0d0d0f`, surface `#161619`, selected `#2a2a30`, border `#2e2e34`, text `#ececf1`,
secondary `#b4b4bd`, and muted `#8a8a94`. These do not replace terminal colors.

Native system typography serves the settings UI: 17 pt medium headings, 14 pt
labels and editors, 13 pt buttons and segments, and 12 pt supporting text.
Terminal content retains its separate Obel Mono font policy.
The fixed 760 × 460 pt content area has a 216 pt sidebar, a 132 pt label column,
and 24 pt pane side insets. Rows use 10 pt vertical insets and top separators.
Inputs are 32 pt high with 8 pt corners and a 2 pt yellow focus stroke; navigation
and segmented controls also use 8 pt corners. Action buttons use 7 pt corners.
Cancel and Apply stay at the lower right outside the panes.

## Validation and accessibility contract

`value()` reads every draft control through `TerminalPreferences.edited`.
Validation is global: an invalid value in a hidden pane keeps Apply disabled and
the shared error visible. Numeric editors preserve raw invalid input, including
`41` and `nan`, instead of silently coercing it with `NumberFormatter`.
Font size accepts 8–40 pt; scrollback accepts 0–50,000 rows. Font Up/Down commands
and the native stepper recover from nonfinite input to a finite bounded value.

Navigation exposes native radio roles, selected values, and an explicit
`accessibilityPerformPress()` implementation. Up/Down moves through sections.
IDs use `no.helgesverre.terminal.settings`, with `.section.<id>` for navigation
and stable field suffixes from `Presentation`. Keep native editing, selection,
keyboard commands, and accessibility behavior when changing custom drawing.

Blank startup directory means home. Choose opens the existing directory-only
`NSOpenPanel`. Cancel closes without applying; reopening reloads preferences.
Apply validates, invokes the supplied callback once, and closes. Persistence is
the caller's responsibility, not the settings window's.

## Local verification and limits

The implementation session reported a successful app build and native checks
covering invalid font and history edits across navigation, `nan` and infinities,
bounded arrow and stepper recovery, radio selection and keyboard navigation,
blank directory behavior, Apply callback count, and Cancel/reopen behavior.
An external accessibility client also exercised semantic sidebar activation.
The focused `just unit-test --filter SettingsWindowTests` is part of `just test` and CI. It drives
the native field editor and semantic section navigation, checking invalid drafts,
hidden-field validation, nonfinite recovery, font bounds, Apply, Cancel and no
preference persistence. Directory chooser interaction and external accessibility
client checks remain separate local verification. These checks do not establish
behavior for future sections that exceed the fixed window's available height.

Native captures in the session artifact directory
`terminal-settings-sidebar-yellow` record General, Text, Panes, and focused
General. The focused capture confirms the existing yellow accent and rounded
input treatment. Helge approved this design on 2026-11-09 and authorized the
SidePulse branch port. That branch keeps its hardware controls; the base app
does not gain hardware integration from this redesign. No release is claimed.
