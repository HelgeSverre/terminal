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

The emulator has no mode that lays text out by code point width. It answers a
query for mode 2027 with "permanently set", so a program that asks learns
which layout is in use; zsh does not ask.
A recorded byte stream that reproduces the overwrite is not in the tree yet.
