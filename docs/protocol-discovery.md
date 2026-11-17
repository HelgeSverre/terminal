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

Title stack operations 22/23 are supported without enabling child window
movement or resizing. Title/icon reports 20/21 are not answered: a title is
set by output, so reporting it would let output place text in the input
stream. The stack retains the newest 16
bounded entries; indexed stack access is unsupported. Title text removes Cc
controls plus bidi overrides, isolates and directional marks, which otherwise
can visually disguise a host/path. ZWJ and WORD JOINER remain valid. Titles
remain cell-ordered text; this is not a general bidi rendering implementation.

The [isolated Snacks fixture](../Tests/Fixtures/Snacks/README.md) contains the
Helge-specific upstream patch and default-image startup configuration.
Upstream recognition is a separate
dependency. It passed direct runtime validation on the frozen `306a592` app;
tmux and SSH paths are not qualified. Source regressions are in `TerminalProtocolDiscoveryTests`,
`TerminalPaletteTests`, `TransportTests` and `SnapshotBridgeTests`.

OSC 8 retains its colon-separated `id` parameter separately from the URI.
IDs are at most 256 UTF-8 bytes and exclude control characters; missing,
empty or invalid IDs use the existing adjacent-same-URI heuristic. Unknown
parameters are ignored. IDs survive wide/combining cells, repeats, save/restore,
history and reflow, and their bytes count toward storage admission. The Swift
cell APIs expose `linkID`; the layout-compatible C snapshot carries a sparse
`link_ids` metadata dictionary keyed by flattened grid index. The actual link
string and opened URI are unchanged.

Hover occurrences group visible pieces with the same URI and nonempty ID,
including disjoint pieces and hard-line breaks, while distinct IDs remain
separate. Labels remain bounded and activations retain owner-validated row
identity/revision proofs. An ID-only rewrite invalidates the prior activation.
This follows the [OSC 8 identity semantics](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda).

## Recorded conformance disposition — 2026-11-17

The coordinator's `e0f79b3` run recorded 440 passes, 88 failures and 39 known
bugs with esctest2 `2798f12`, using its xterm/VT-level-5 expectations. This is
the disposition of that recorded run, not a claim that the following changes
have been rerun. The implemented SGR/margin/cursor/protection DECRQSS subset,
practical hex/`rgb:` color forms, special-color reset paths and nine other
title query/stack cases passed.

Two reruns followed. At `b945624`, 447 cases passed with 81 failures: the
first two rows below are fixed, and five of the ten VT cases pass. At
`556aa51`, 460 passed with 68 failures: the `DECID` row and the nine `DECDSR`
cases are implemented and pass, `DECNKM` leaves the DECRQM row, and `DECSASD`
and `DECSSDT` leave the DECRQSS row. At `25d3add`, 473 passed with 55
failures: thirteen DECRQM modes answer permanently reset. At `c9b2eca`, 460
passed with 66 failures: the title reports were removed, so thirteen cases
that read a title back no longer pass. The table keeps the `e0f79b3` counts.

| Recorded failures | Count | Disposition |
| --- | ---: | --- |
| `XtermWinops_PushIconThenWindowThenPopBoth` | 1 | Implemented-feature defect: a partial stack frame must inherit missing fields from an older frame. Fixed with a focused regression. |
| `ResetSpecialColor_Dynamic` | 1 | Harness defaults mismatch: upstream forces black/white before each case, while OSC 110 correctly restores the host's configured foreground. The esctest host now configures black/white resource defaults; the app's reset behavior is unchanged. |
| `ChangeColor`, `ChangeDynamicColor`, `ChangeSpecialColor`: `CIELab`, `CIELuv`, `CIEXYZ`, `CIEuvY`, `CIExyY`, `RGBI`, `TekHVC` | 21 | Unsupported X11 color-space syntaxes. The implemented parser deliberately covers hex, `rgb:` and basic names; it does not silently approximate these formats. |
| `DA_0`, `DA_NoParameter`, `DA2_0`, `DA2_NoParameter` | 4 | Xterm-specific identity expectations: VT525/full xterm feature advertisement and xterm firmware range. Helge keeps its conservative VT220-class DA replies and supplies its actual implementation/version through XTVERSION. |
| `DECID_Basic` | 1 | Implemented since: ESC Z answers as primary device attributes. |
| Nine `DECDSR` cases listed below | 9 | Implemented since: each report answers with the value for absent hardware or nothing to report. |
| 23 `DECRQM` modes listed below | 23 | Thirteen modes this terminal can never enter answer status 4 (permanently reset) since. The other unsupported modes return status 0 (not recognized); xterm's toggling behavior is not claimed. |
| `DECRQSS_DECSACE`, `DECSASD`, `DECSCL`, `DECSLPP`, `DECSNLS`, `DECSSDT` | 6 | Outside the bounded status subset: attribute-change extent, status display/type, conformance switching and child-controlled page/screen geometry are not implemented. Negative replies remain truthful. |
| Three `DECSCL` level-switching cases | 3 | Unsupported virtual VT conformance-level switching/gating. Available extensions do not imply an emulated VT100–VT525 mode hierarchy. |
| Nine window-changing cases listed below | 9 | Intentional exclusion: child-controlled resize, move and iconify remain disabled. No window mutation is enabled to improve conformance counts. |
| Ten VT semantics cases | 10 | Owned by the VT package: CUB after nonwrapping inline output, DECALN margins, DECSED/DECSEL ISO-protection interaction, three DECSET cases, ED 0, NEL outside horizontal margins and RIS/DECCOLM. Dispositioned individually in [VT dispositions](gap-vt-conformance.md). |

The DECDSR suffixes, now answered, are `DECCKSR`, `DECMSR`,
`DSRDECLocatorStatus`, `DSRDataIntegrity`, `DSRKeyboard`,
`DSRMultipleSessionStatus`, `DSRPrinterPort`, `DSRUDKLocked` and `LocatorType`.

The DECRQM ANSI modes are `EBM`, `FEAM`, `FETM`, `GATM`, `HEM`,
`KAM`, `MATM`, `PUM`, `SATM`, `SRM`, `SRTM`, `TSM`, `TTM` and `VEM`.
The DEC modes are `DECBKM`, `DECCOLM`, `DECHCCM`, `DECHEBM`, `DECNRCM`,
`DECPEX`, `DECPFF` and `DECSCLM`; `DECNKM` is implemented since. All but
`KAM`, `SRM` and the DEC modes other than `DECHCCM` now answer status 4;
those nine stay unrecognized because xterm expects them to toggle.

The excluded window cases are `DECSLPP`, `IconifyDeiconfiy`, `MoveToXY`,
`MoveToXY_Defaults`, and `ResizePixels` with `BothParameters`,
`OmittedHeight`, `OmittedWidth`, `ZeroHeight` and `ZeroWidth`. The three
DECSCL cases test level 2 disabling DECRQM, level 3 allowing DECRQM but not
DECSLRM, and level 4 allowing DECSLRM but not DECNCSM.
