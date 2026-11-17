# Terminal discovery and color state

XTVERSION (`CSI > q` or an explicit zero parameter) replies with
`DCS > | HelgeTerminal VERSION ST`. The macOS application supplies its bundle
release version through `TerminalSessionConfiguration.identity`. The engine
and default headless/embedding sessions report `HelgeTerminal` with no version
until the host supplies one. `TerminalIdentity(name:version:)` accepts bounded
printable ASCII tokens; a reset retains the implementation identity. This
does not change the remote-compatible `TERM=xterm-256color` child default or
reinterpret the legacy DA2 firmware field as an application version.

XTGETTCAP accepts at most 4 KiB of payload and 32 hexadecimal capability
names. It supports `TN`/`name` (the bundled `helge-terminal` description),
`Co`/`colors` (256), direct-color flags, and ordinary navigation/function-key
capabilities from the project terminfo. Cursor-key values reflect application
cursor mode. It does not claim arbitrary xterm extensions or read a system
terminfo database. Supported pairs share a reply in input order; an unknown
or malformed name produces a negative reply and stops the list.

DECRQSS supports SGR, vertical/horizontal margins, cursor style and character
protection. SGR replies describe the current pen, including indexed/truecolor
foreground, background and underline color, underline style and flags. Unknown
settings receive a negative reply. Oversized DCS strings are discarded through
their terminator, rather than being printed or allocating an unbounded buffer.
The framing follows the [xterm control-sequence specification](https://github.com/ThomasDickey/xterm-snapshots/blob/master/ctlseqs.txt).

OSC 10/11/12 can set or query foreground, background and cursor color, including
chained values. OSC 110/111/112 deliberately reset them to the latest host
scheme. Palette resets use OSC 104. Explicit child overrides survive host
theme changes even when the override equals the previous scheme's color.
Colors accept `rgb:` components, the four XParseColor hexadecimal widths and
a small basic-name set. CIE/TekHVC and the complete X11 name database remain
unsupported. Channels are stored at eight-bit precision.

OSC 5 (or OSC 4 indices 256–260) sets/query special bold, underline, blink,
reverse and italic colors. OSC 6/106 enables the corresponding attribute modes;
they start disabled. Explicit SGR colors take precedence unless attribute-color
override mode 5 is enabled. OSC 105 restores special colors. These colors are
resolved at snapshot publication so changes affect retained output too.
The foreground precedence is blink, bold, underline, then italic; the selected
attribute is displayed in color instead of its usual visual effect. `colorUL`
colors the characters, while SGR 58 independently sets an underline's line color.

`CSI ? 996 n` reports whether the configured host background is dark or light
using weighted RGB brightness. Mode 2031 subscribes to host scheme changes;
each change sends the same report. A child changing OSC colors does not change
the reported user preference or trigger a notification. The behavior follows
[Contour's palette notification protocol](https://contour-terminal.org/vt-extensions/color-palette-update-notifications/).

Title/icon queries 20/21 and title stack operations 22/23 are supported without
enabling child window movement or resizing. The stack retains the newest 16
bounded entries; indexed stack access is unsupported. Title text removes Cc
controls plus bidi overrides, isolates and directional marks, which otherwise
can visually disguise a host/path. ZWJ and WORD JOINER remain valid. Titles
remain cell-ordered text; this is not a general bidi rendering implementation.

The [isolated Snacks fixture](../Tests/Fixtures/Snacks/README.md) contains the
Helge-specific upstream patch and default-image startup configuration. It
requires runtime validation in a frozen app; upstream recognition is a separate
dependency. Source regressions are in `TerminalProtocolDiscoveryTests`,
`TerminalPaletteTests`, `TransportTests` and `SnapshotBridgeTests`.
