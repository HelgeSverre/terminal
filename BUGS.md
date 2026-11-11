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
