# Version 0.2.1

Runtime source: `b9d3a81`, version 0.2.1/build 6. CI passes at `25dc31e`;
the follow-up changes only the Session cancellation test and its report.
The signed app and PKG are accepted by Apple, stapled and accepted by Gatekeeper.
`../distribution-0.2.1.json` records hashes, signatures, CI and installation state.
The complete frozen build remains at the artifact directory in that receipt.

Both the ad-hoc and signed app pass normal, editing, final-window-close and
Command-Q fixtures. Every owned child exits/reaps. The signed app also exposes
the actual Vite URL as an AX link: agent-desktop AXPress opens the exact URL in
Chrome, its owned tab is closed, and the fixture exits naturally.

## Full SQL stress

The unchanged runner reads the same local 8,162,501,113-byte regular file in
each run; no SQL content is stored. Both complete regular runs drain all PTY
bytes and reap their children, with empty cleanup lists.

| Runtime | Wall time | Parsed PTY throughput | Peak physical footprint |
|---|---:|---:|---:|
| Swift 0.2.1 | 165.99 s | 47.0196 MiB/s | 210,521,216 B |
| Frozen Rust `9cc6f92` | 114.75 s | 68.0108 MiB/s | 109,366,208 B |

Swift/Rust throughput is **69.1355%**, below the 70% target for this workload.
This is one sequential development pair, Swift then Rust, with two scheduled
resizes per runtime; it is not a statistical or parser-only benchmark. The
runner and frozen Rust binary hashes match the previous comparison. Swift's
throughput is essentially unchanged from runtime 34's 47.0932 MiB/s; the changed
ratio does not establish a sustained-output optimization.

The separate Swift figure-eight run continuously changes width and periodically
height. It completes in 190.08 s at 41.0610 MiB/s with 11,402 motion ticks,
149,261,184 B peak footprint and main-queue delay p95 4.65 ms. All source output
drains, the child is reaped, and the app exits naturally. There are zero Metal
command errors, drawable/present dimension mismatches and dropped quad buffers.
This is programmatic NSWindow movement, not physical-pointer or complete
compositor-frame proof. Rust's frozen fixture has no motion mode, so no matched
Rust figure-eight comparison is claimed.

The first launch accidentally omitted the motion flag. It was interrupted and
cleaned up with no survivors; its false receipt is retained as
`aborted-resize-only.json` and excluded from acceptance.

## Cancellation fixture correction

CI `42549643929` failed because the earlier 10 ms timer/main-queue callbacks
could admit close after resize had already committed. The product correctly
sent WINCH in that ordering. Test-only `25dc31e` posts admission and close marker
from one owner turn, guaranteeing begin → pending → close before continuation.
It removes the timer and large-workload assumption. Four local runs and full
CI `42551103822` pass, with all 17 children reaped. The separately tested
50k-history commit still yields to owner probes; the rapid shrink/restore test
confirms later input sees the restored width. The signed runtime is unchanged.

Notarization credentials are unchanged and were already backed up and verified
in Personal 1Password; see `../signing-backup.json`. Full v1 completion, broad
display/IME/VoiceOver coverage and the sustained-SQL performance gap remain
separate work.
