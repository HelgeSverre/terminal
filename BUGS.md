# Known bugs

Current source status is tracked in [docs/status.md](docs/status.md); hardware
and external qualification gates are tracked in
[docs/qualification.md](docs/qualification.md). Historical gap audits and
plans live in [docs/archive/](docs/archive/README.md)
([gap inventory](docs/archive/gap-inventory.md),
[gap implementation status](docs/archive/gap-implementation-status.md),
[implementation plan](docs/archive/gap-implementation-plan.md)).

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
