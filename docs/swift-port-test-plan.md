# Swift-core differential test plan

`native/tests/SwiftCoreTests.swift` is intentionally a narrow ABI smoke test.
It covers behavior the current Swift implementation owns: basic grid updates,
SGR snapshots, alternate-screen isolation, PTY input bytes, bracketed paste,
terminal replies, and safe byte-at-a-time feeding.

It is not evidence of feature parity. Before the experiment can replace the
Rust baseline, add or replay the following independent oracles:

1. The existing 41 semantic cases under arbitrary byte partitioning, including
   maximal-subpart invalid UTF-8 and pinned Unicode 18 grapheme segmentation.
2. Margins, rectangular operations, resize/reflow, and viewport anchor cases.
3. Search cancellation/order/resource limits and all keyboard/keypad variants.
4. Kitty graphics with direct RGBA, PNG/zlib, chunking, deletion, and the
   dmscene double-buffer transcript.
5. Native PTY application corpus (shells, nvim, tmux and fzf) plus the real
   app's controlled self-terminating smoke.

Each translated/replayed case must compare snapshot, replies, input bytes and
observable resource behavior against the Rust oracle. Platform Unicode APIs are
not a substitute for the version-pinned tables used by that oracle.
