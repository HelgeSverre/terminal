# Swift layout and cleanup

## Scope and baseline

Baseline: `df4a04df0ff636b896511271a595ae6f11577317` (2026-11-09).
This cleanup covers startup geometry, pane presentation/preferences, build-source
ownership and benchmark-process lifecycle, followed by a conventional Swift
source/test layout. Parser, row storage, text semantics, renderer scheduling and
PTY protocols are preserved; their internals are outside the refactoring scope.
Historical `reports/` and archived Rust evidence keep their original paths/hashes.

Existing task work: the Ghostty comparison recipe/runner and research reports
were already being prepared. `/private/tmp/terminal-cleanup-baseline.patch`
preserves the tracked diff. An investigator supplied the one Canvas metric
extraction before the formal rounds; its SHA-256 is
`c029eb575656424c5445bf10fc8ae11bad9bf2544b66123cc58dd9827e724ae6`.
The coordinator owns integration and this document; reviewers are read-only.

## Validation matrix

| Gate | Configuration / artifact | Current evidence |
| --- | --- | --- |
| G1: baseline full native suite | CI development app, `ce285ff`; production inputs unchanged at baseline | [Passed](https://github.com/HelgeSverre/terminal/actions/runs/42657698748); hosted Metal exception remains distinct from local real-GPU coverage |
| G2: startup grid | Actual app, explicit 100×30/Obel 14, 1× display | Pre-fix release and development both reject 100×27; proposed fix development passes 100×30 (900×630 pixels) |
| G3: build/source ownership | Development and WMO release | Baseline release compile succeeded; final migration checks pending |
| G4: lifecycle / GPU viewport | Owned native pane fixture | Baseline passed; affected final artifact pending |
| G5: comparison | Same driver and grid, two opposite launch orders | Initial run refused wrong grid; corrected release baseline pending |
| G6: final integration | `just test`, current native artifact and CI head | Pending |

## State machines and invariants

| ID | Owner / representation | Invariant / disposition |
| --- | --- | --- |
| M1 | Canvas: window attachment, bounds, font/backing metrics, PTY grid | I1: requested grid uses actual font metrics even before layout. Confirmed issue A1; inspected/changed, verification pending |
| M2 | Window: active pane, title cache, presentation map, split tree | I2: active title and leaf minima derive from owned pane state. Existing tests retained; inspect during rounds |
| M3 | Preferences: persisted defaults, validated edits, UI/automation consumers | I3: edits preserve independent preferences and migration stays owned. Inspect during rounds |
| M4 | Build graph: source groups, C/Metal/resources, incremental outputs | I4: every shipped/test input resolves once and no retired source root remains active. Migration pending |
| M5 | Comparison runner: frozen bundles, owned PIDs, reports and cleanup | I5: valid complete results require matching contract and all owned processes reaped. New task-owned interface; inspect before publication |

| From | Event / guard | Owner effects / next state | Failure, retry, cancellation | Evidence |
| --- | --- | --- | --- | --- |
| M1: attached but unlaid-out | Request grid size | Derive font/backing metrics before calculating points; no PTY resize as a sizing-query side effect | Zero bounds cannot select placeholder metrics | A1, G2 |
| M1: valid bounds | Layout/backing/font change | Refresh metrics and drawable, publish ordered PTY resize | Session owns rejection/cancellation; unchanged | G4, retained Session tests |
| M2: pane active/background | Title/focus/exit | Cache per-pane state; publish active title; derive header | Duplicate titles are no-op; removed panes cannot update window | Existing lifecycle regression; round review pending |
| M3: loaded | Settings/automation edit | Validate all independent values then persist/apply | Reject invalid values without partial save | Preferences/automation tests; round review pending |
| M5: idle | Start trial | Copy bundles, record hashes, launch exactly one owned app | Any failed/incomplete report is failure; cleanup owns only launched tree | G5 |
| M5: running | Driver/app exits | Validate owner, grid, corpus, samples, natural exit, then accept | Timeout/signal/nonzero/missing report must clean up and remain failed | G5 |

## Issues

| ID | Impact / reachable trace | Fix and acceptance criteria | Current status |
| --- | --- | --- | --- |
| A1 | Explicit 30-row startup uses seed 19px height before first layout; actual font is 21px, yielding 27 PTY rows | Metrics independent of bounds; real CLI regression red on baseline and green in development/release | Fixed in working candidate; three development fonts pass; release pending |
| A2 | Ghostty serves its PTY from an owned descendant rather than the launcher PID | Validate report PID against retained observed-owned membership; keep natural exit and no-survivor checks | Fixed candidate; process unit test and both-order tiny comparison pass |
| A3 | Different native cell metrics rejected despite matching PTY grid/configured font/OPOST | Require matching cell geometry/mode; retain positive pixel dimensions as provenance, no pixel-matched FPS claim | Fixed candidate; both-order tiny comparison passes |
| A4 | Failed comparison lacked a reason/stage; nonzero app status hid the driver marker | Persist stage/failure and prioritize driver diagnostics | Fixed candidate; interruption evidence and nonzero-marker regression pass |
| A5 | Interrupt after spawn, including unwinding the constructor log block, could leak a launched app before the caller receives it | Initialize ownership state before spawn, store PID inside the log block, and reap on constructor unwind; arm caller cleanup before construction | Constructor regression now passes (5 process tests, 32 assertions); pre-fix constructor fails the same real-child fault injection |
| A6 | Wrong report label or two missing mode fields could satisfy comparison | Validate exact label and Boolean OPOST per app | Fixed candidate; corruption regressions pass |
| A7 | Source hash alone did not identify the executed frozen copy | Hash measured executable and reject source/copy mismatch | Fixed candidate; actual-copy verification pending |

## Module decisions

| Cluster / consumers | Ownership and deletion test | Interface / compatibility | Disposition |
| --- | --- | --- | --- |
| Canvas metrics / startup window | Layout metrics earn an owner; deleting it would move font/backing calculations into callers | Keep `contentSize(columns:rows:)`; hide metric readiness inside Canvas | Deepen for A1 |
| Pane presentation / window tree | Header geometry/colors/dimming belong together; window owns topology/focus | Existing pane identifiers/settings/AppleScript remain compatible | Retain; review minor redundant interfaces only |
| Preferences / Settings / automation | Validation and derived defaults belong to Preferences | Persisted keys and script arguments are existing contracts | Retain; examine avoidable caller flags |
| Build graph / just / tools | Source group resolution belongs to build graph | Source filesystem layout is task-authorized to change; recipes remain supported | Migrate `native/` to conventional source/test ownership |
| Emulation, Text, Session, Rendering | Existing concepts retain behavior and dependencies | No hot-path redesign or protocol contract changes | Retained; mechanical path migration only |
| Benchmark runner / recipes | Workload validation and process cleanup belong to runner | Newly introduced in this task; no compatibility shell required | Inspect/deepen |

## Round log

Three read-only reviewers per round; the coordinator integrates changes.

- Sweep A Discover: three read-only lenses (terminal_coverage lifecycle, ghostty_features retry/concurrency, cleanup_consumers callers/coverage). M1–M5 inspected; confirmed A1–A4, no additional pane/preference defect. Evidence: pre-fix grid rejection; actual development 8/14/20pt passes; observed-owned process tests; 1-byte comparison in both orders; explicit interruption cleans up. Pixel geometry is intentionally provenance, not equality for this PTY-only comparison.
- Sweep A Challenge: three rotated lenses on `7f40e98`. Confirmed launch-before-ensure gap (A5), lost nonzero driver reason (A4), missing report label/OPOST validation (A6), and copied-executable provenance gap (A7). Candidate now arms cleanup before launch, retains `.failed` reasons, validates label/Boolean mode, and hashes the measured copy. Four targeted tests pass (10 assertions); the same tests against pre-fix `7f40e98` produce three failures. Frozen compiled app inputs are unchanged. Font equality means configured family/size, not independently proven resolved-font identity.
- Sweep A Verify: three rotated reviews at `af41ca8`; two found no further delta defect, lifecycle reviewer confirmed the remaining constructor acquisition window in A5. Coordinator repaired it at the process owner; exact pre-fix reproduction fails and current test reaps the real child. A scoped three-reviewer Verify repeat is required before moving to Sweep B. Repeated-signal/SIGKILL behavior is not claimed as exhaustively tested.
- Sweep B Discover: pending, after correctness verification and baseline measurement.
- Sweep B Challenge: pending.
- Sweep B Verify: pending.

## Remaining limits

This is a scoped correctness/module cleanup, not a claim of complete VT, IME,
VoiceOver, multi-display or concurrency conformance. Performance comparisons
measure PTY processing/barriers, not displayed FPS or input-to-photon latency.
CI verification will be recorded against its actual tested commit; an older
passing run is not a final-head pass.
