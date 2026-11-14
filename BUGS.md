# Known bugs

Found on 2026-11-11 by probing 0.3.0 (`22b9f69`) from a real window
(`--execute`) and headlessly through `target/native/terminfo-probe`.
Expected behaviour is xterm's unless noted. Each entry is removed when its
fix and regression test land.

## Not implemented (no reply)

Not bugs, listed so they are not rediscovered: XTVERSION (`CSI > q`),
XTGETTCAP, DECRQSS, XTWINOPS 14t/16t/18t/21t, OSC 12 query, `CSI ? 996 n`.
CSI parameters above 32 bits are treated as 0 (xterm clamps), which no real
program relies on.

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

The app starts sessions in the layout stored under `graphemeClustering`,
which has no control in Settings:

```shell
defaults write no.helgesverre.terminal graphemeClustering -bool false
```

`ShellWidthTests` runs the edit in a real zsh in both layouts: by code point
the line is right, and by cluster zsh still overwrites its prompt. The
default is unchanged, so this entry stays open until a default is chosen.
