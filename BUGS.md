# Known bugs

Current source disposition was checked on 2026-11-17.
[Gap implementation status](docs/gap-implementation-status.md) records the
revisions the gates ran at; hardware gates remain separate. The
[gap inventory](docs/gap-inventory.md) and [implementation plan](docs/gap-implementation-plan.md)
track the broader backlog and validation dependencies.

## Discovery queries from the 0.3.0 probe

The 2026-11-11 probe at `22b9f69` found no replies for XTVERSION (`CSI > q`),
XTGETTCAP, DECRQSS, XTWINOPS 14t/16t/18t/21t, OSC 12 query and `CSI ? 996 n`.
Source now implements those replies; they are no longer missing-feature entries.
`TerminalProtocolDiscoveryTests` adds discovery, color and title regressions.
Identity is host supplied and truthful. Query support does not authorize child
window movement/resizing or imply complete xterm conformance. See
[protocol coverage](docs/protocol-coverage.md).

## Shell line editing after emoji sequences

Found on 2026-11-14. zsh counts the width of a line one code point at a
time; the emulator lays out grapheme clusters. For an emoji with a skin-tone
modifier (`👩🏽`) zsh counts four columns and the emulator uses two, as tmux
does. When such text is on the edit line, for example as a
zsh-autosuggestions suggestion, zsh's cursor moves land to the left of where
it intends, and its next redraw overwrites the prompt: typing `a`, `s`,
Backspace, Backspace, `ls` left `asls` at column 0.

Mode 2027 chooses the layout. Set, which is how a session starts, a cluster
takes the cells of one character. Reset, every code point with a width takes
its own cells and one without joins the cell before, which is zsh's count;
the emoji is then drawn in pieces (woman, skin tone, laptop). A program
switches with `CSI ? 2027 h` and `l`; zsh does not.

The app's choice is Settings > Text > "Join emoji sequences", on unless
turned off. Turning it off gives the layout by code point.

`ShellWidthTests` runs the edit in a real zsh in both layouts: by code point
the line is right, and by cluster zsh still overwrites its prompt. The
default stays clustering by decision (2026-11-14): such emoji on a zsh
command line are rare, and the other layout draws them in parts everywhere.
