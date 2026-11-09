# Terminal identity and terminfo

`Resources/Terminal/Terminal.terminfo` is the project-owned description of the output
sequences Terminal implements today. The build compiles it with `tic -x` into
`Terminal.app/Contents/Resources/terminfo`, and `just test` verifies the
compiled bundle, exact `tput` expansions, and a replay of representative
expanded strings through `terminal-tools`.

This source is intentionally standalone rather than `use=xterm-256color`.
ncurses terminfo entries are declarations of an emulator's programming
interface, and `use=` would silently inherit features such as OSC 52 clipboard,
cursor-style extensions, title stack, and dynamic colors that this application
does not claim. `tic` compiles source into the database read by terminfo clients
([`tic(1)`](https://invisible-island.net/ncurses/man/tic.1m.html));
[`infocmp(1)`](https://invisible-island.net/ncurses/man/infocmp.1m.html) is used
to inspect that compiled result.

## Advertised surface

| Capability group | Entry policy | Evidence in the emulator |
| --- | --- | --- |
| Cursor movement, tabs, margins, erase, character/line insert/delete and scroll | Advertised | `TerminalEmulator.swift` handles the CSI/ESC sequences emitted by the entry. |
| 256 indexed colors and advertised SGR styles (bold, dim, conceal, reverse, underline) | Advertised | `setaf`/`setab` use standard xterm-compatible ANSI/256-color SGR; `Renderer.swift` visibly applies each listed style. Blink is deliberately absent because the renderer retains, but does not animate, that style. |
| Alternate screen, application cursor/keypad | Advertised | `?1049`, `?1`, `ESC =`, and `ESC >` map to owned screen/input modes. |
| DEC line drawing and supported keys | Advertised | `acsc` matches the DEC graphics mapping; key strings match `TerminalInputEncoder.swift`. |
| Audible/visual bell, OSC 52, window operations, title-stack, dynamic color allocation, cursor-style extensions | Not advertised | The entry declares only tested capabilities. OSC 52 writes have a separate [permission policy](osc52-clipboard.md); reads are denied. |
| Direct-color terminfo extension | Not advertised as `RGB` | RGB SGR rendering works and `COLORTERM=truecolor` is exported, but `colors#256` remains the stable terminfo promise until direct-color ncurses behavior is tested across supported client versions. |

The SGR sequences use the same 256-color forms documented by
[xterm's control-sequence reference](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html).
The direct-color extension is intentionally separate: ncurses documents `RGB`
as an extension used for direct color ([terminfo source notes](https://invisible-island.net/xterm/terminfo-contents.html)), so it is not a safe synonym for
ordinary 256-color support.

## TERM decision

The spawned shell continues to receive `TERM=xterm-256color`,
`COLORTERM=truecolor`, and `TERM_PROGRAM=HelgeTerminal`. This is deliberate:
the compiled entry lives in the app bundle, but an SSH server receives `TERM`
and normally cannot see that bundle's `TERMINFO` directory. Publishing
`TERM=helge-terminal` now would make ordinary remote sessions fail unless users
install the entry remotely.

ncurses searches a `TERMINFO` location before standard database locations
([`tic(1)` search order](https://invisible-island.net/ncurses/man/tic.1m.html)).
Therefore a future custom-TERM switch requires all of the following:

1. Install the compiled entry in a discoverable local path and provide a clear,
   supported remote-install mechanism.
2. Exercise the entry with supported local and SSH clients, including ncurses
   versions that may not recognize extensions.
3. Re-audit every newly advertised sequence and add it to the expansion/replay
   test before changing `Spawn.c`.

Until then, `xterm-256color` is the explicit compatibility fallback from spec
section 8.4, while the bundled entry provides an honest, version-controlled
capability contract for packaging and future installation.
