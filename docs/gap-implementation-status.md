# Gap implementation status — 2026-11-17

This follows the [40-entry inventory](gap-inventory.md) and
[implementation plan](gap-implementation-plan.md). It separates implemented
behavior from qualification that needs external clients, hardware or releases.
The intentional exclusions in the inventory remain unchanged.

## Implemented behavior

| Inventory | Result |
| --- | --- |
| C01, C03 | Real terminal identity/version, bounded XTGETTCAP and DECRQSS replies for implemented capabilities. Unsupported requests receive truthful negative replies. |
| C02 | Pinned Snacks detection patch and isolated client fixture; upstream adoption is separate. Helge does not identify as Kitty. |
| C04, C08 | Cursor/special colors, practical color parsing and resets, theme reports, read-only title queries and bounded title stacks. Exotic X11 color spellings and child-controlled window changes remain unsupported. |
| C05 | Margin movement, erase/protection/reset/save semantics, rectangles, column edits, horizontal index, alternate screens, REP and modern reverse wrap. See the detailed conformance dispositions. |
| C06 | modifyOtherKeys, UTF-8/URXVT/pixel mouse encodings and per-side Option policies. Legacy highlight tracking (1001) remains unsupported. |
| C07, U12 | Bounded OSC 8 identity through cells, reflow, snapshots and hover; title bidi controls filtered. |
| G01, G02 | Graphics placements survive reflow/partial scrolling; palette-linked indexed images update with colors. |
| G03 | SIXEL background, aspect ratio, palette persistence and display modes. |
| G04 | Multipart images, GIF frame playback, cell/feature reports and bounded downloads requiring an explicit Save action and chosen destination. |
| G05 | Bounded asynchronous file/shared-memory transport, timeout/cancellation and correct Darwin shared-memory calling convention. |
| U01–U03 | Five underline styles, requested text/cursor blink with idle gating, and quiet coalesced visual bell. |
| U04, U05 | Attributed preedit, UTF-16-safe replacement and geometry; bounded asynchronous accessibility history. |
| U06, U07 | Fractional scrolling with a guard row and shared hit geometry; case/whole-word/bounded-regex search. |
| U08 | Bash/fish/zsh integration, bounded command records and navigation. True Bash login shells retain login semantics and require explicit hook sourcing. |
| U09 | Unclean-exit layout/text recovery with locked state, bounded checkpoints and fresh shells; data-driven agent offers execute only after Resume is clicked. Normal quit clears recovery state. |
| U10, U11, U13 | Validated settings/theme import, shell profiles, shortcuts, pane focus/zoom/moves, and scripting collections/preferences/directory/history/selection. |
| E01 | UIKit composition, selection, clipboard, links, find, hardware-key metadata and accessibility, including blank-screen focusability. |
| E02 | Public incremental headless selection, copy, search and navigation. Full emulator-state serialization is not provided. |
| E03, E04 | Explicit consumer package graph without app/updater/tooling dependencies, packaged shell resources and documented public API policy. Swift 6 consumer hosts compile; libraries remain in Swift 5 language mode. |
| V06 | GPU failure quiescence and existing bounded history/graphics/glyph/transport paths are tested. These are not a complete process-wide heap admission policy. |
| V09 | Two coordinated prebuilt CI test lanes, preserving conformance, fuzz and explicit real-GPU gates. Timing evidence distinguishes test execution from total CI feedback. |
| D01 | Living bug/status/protocol/embedding documentation reconciled; dated historical evidence retained. |

## Verification and remaining qualification

At source `5d46b01`, the full local gate passed: 126 developer tests,
511 application tests, 16 GPU tests and the tooling, terminfo, font and PTY
checks. The PTY corpus includes Bash, fish, Neovim, tmux and fzf. The two-lane
post-build pipeline took 73.25 seconds, versus 120.79 seconds for the earlier
serial run at `306a592`. These are local runs under different machine loads,
not a controlled benchmark, cold-build measurement or hosted CI percentile.
All seven iOS tests passed on an iPhone 16 simulator running iOS 26.3.1.

At `b945624`, conformance passed its regression gate with 447 passing cases,
81 reported failures and 39 known xterm deviations. The known-good list now
protects those 447 cases. Two reported failures are upstream known-bug
decorators rejecting correct ISO-protection behavior as unexpected passes;
the other dispositions are explicit in [conformance](conformance.md).

The frozen `306a592` app restored known text after an owned-process crash,
exposed it through accessibility history in a fresh shell, and removed its
private state on normal quit. This runtime exercise also found a startup
argument/document-routing bug, addressed separately with regression tests.

The same frozen app passed the real AppleScript fixture and direct Snacks
image detection with the pinned patch, all terminal overrides unset and
`image.force = false`. Neovim displayed the expected image. Private tmux/SSH
qualification of this new detection path remains outstanding.

The frozen `5d46b01` app passed normal, editing and pane-lifecycle smoke checks,
cold/warm command-file opening, and unattended crash recovery with accessible
saved text and cleanup on normal quit. The startup-routing and UIKit selector
fixes are now verified. Gitleaks found no secrets through `129ca48`; the final
documentation commit is scanned again before push.
The standalone ASan build required a source-list correction at `648a83c`;
the corrected binary passed a full 120-second fuzz run, and conformance
retained all 447 protected passes. The first hosted app-test job also passed;
its 7m14s overall workflow latency exceeded the target and its sanitizer-build
failure required this follow-up. A fresh hosted run verifies the correction.
See the [dated evidence](../reports/gap-implementation-2026-11-17/README.md)
for commands, artifact identities and the distinction between tested revisions.

Remaining qualification is explicit:

- V01: the `kitten icat --hold` legacy-exit issue was reproduced outside this
  terminal, directly and through a private tmux server. No terminal-wide forced
  keyboard encoding workaround was added.
- V02/V03: physical input methods/layouts and VoiceOver speech/navigation need
  human qualification. Composition/AX tests do not certify those workflows.
- V04/V05: representative image pixels and native lifecycle paths are covered;
  exhaustive animation combinations, mixed-DPI display moves, sleep/wake and
  long-running workloads remain broader qualification.
- V06: actual whole-process heap/OOM behavior is not promised by logical row
  accounting or per-subsystem budgets.
- V07/V08: clean-machine installation/update interruption, macOS 14, Intel,
  physical iOS devices and remote SSH/terminfo combinations are separate checks.
- E03: full Swift 6 strict-concurrency qualification of the libraries remains
  separate from Swift 6 consumer builds. No version tag or release is implied.
- C02/V09: upstream Snacks acceptance and repeated hosted cold/warm/p95 timing
  remain external evidence; a local patch or a single run does not establish them.

The supported regex subset and resource bounds are documented in
[search](search.md); unsupported constructs fail explicitly rather than using
an unbounded backtracking engine.
