# Known bugs

Found on 2026-11-11 by probing 0.3.0 (`22b9f69`) from a real window
(`--execute`) and headlessly through `target/native/terminfo-probe`.
Expected behaviour is xterm's unless noted. Each entry is removed when its
fix and regression test land.

## Parser

1. **DCS, SOS and PM strings print as text.** `ESC P`, `ESC X` and `ESC ^`
   have no case in `handleEscapedByte`, so the escape is dropped and the
   string body is printed. `ESC P+q544e ESC \` shows `+q544e`; chafa's sixel
   output fills the screen with sixel data; tmux passthrough
   (`ESC Ptmux;…`) and Neovim's XTGETTCAP/DECRQSS probes leak. The strings
   must be consumed up to ST (or CAN/SUB) and ignored.
2. **ESC, CAN and SUB do not abort a CSI.** The CSI loop appends every
   non-final byte to the parameters. `ESC[1;2` CAN `b` runs `CSI 1;2 b`
   (REP) and prints `aa`; `ESC[1;` `ESC[2C` prints `2C`. CAN and SUB must
   cancel the sequence; ESC must start a new one.
3. **C0 controls inside a CSI are swallowed.** `ESC[1` LF `2C` drops the LF.
   C0 controls must execute without ending the sequence.
4. **`ESC # 8` (DECALN) prints `8`.** `ESC #` has no case. DECALN fills the
   screen with `E`, resets margins and homes the cursor.

## Graphics

5. **A kitty image is dropped when a non-final chunk carries base64
   padding.** `KittyGraphics.consume` rejects `=` in any `m=1` chunk.
   chafa ends a transmission with an empty `m=0` chunk, so its last data
   chunk is `m=1` and padded, and `chafa -f kitty` shows nothing. kitty and
   Ghostty decode each chunk on its own and accept this.

## Environment

6. **`TERMINFO` is inherited from the launching terminal.** Started from a
   Ghostty shell, every child gets
   `TERMINFO=/Applications/Ghostty.app/Contents/Resources/terminfo` while
   `TERM=xterm-256color`. `names_another_terminal` in `Spawn.c` must drop it.

## Not implemented (no reply)

Not bugs, listed so they are not rediscovered: XTVERSION (`CSI > q`),
XTGETTCAP, DECRQSS, XTWINOPS 14t/16t/18t/21t, OSC 12 query, `CSI ? 996 n`.
CSI parameters above 32 bits are treated as 0 (xterm clamps), which no real
program relies on.
