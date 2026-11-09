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
| G2: startup grid | Actual app, explicit 100×30/Obel 14, 1× display | Pre-fix release/development reject 100×27; corrected development and WMO release pass 8/14/20pt cases (`reports/ghostty-swift-2026-11-09/grid-{development,release}.json`) |
| G3: build/source ownership | Development and WMO release | Both builds pass with canonical source paths and compiler module `Terminal`; source graph positive/negative checks pass |
| G4: lifecycle / GPU viewport | Owned native pane fixture | Current development and WMO fixtures pass; explicit grids at 8/14/20pt and clean app/child exit pass |
| G5: comparison | Same driver and grid, two opposite launch orders | Strict copied-executable comparison passes both launch orders (`before-layout-cleanup-verified/comparison.json`); current-layout rerun pending |
| G6: final integration | `just test`, current native artifact and CI head | Pending |

## State machines and invariants

| ID | Owner / representation | Invariant / disposition |
| --- | --- | --- |
| M1 | Canvas: window attachment, bounds, font/backing metrics, PTY grid | I1: requested grid uses actual font metrics even before layout. A1 verified in development and WMO release at 8/14/20pt on the current 1× display |
| M2 | Window: active pane, title cache, presentation map, split tree | I2: active title and leaf minima derive from owned pane state. Inspected and retained; current development/WMO pane lifecycle and viewport checks pass |
| M3 | Preferences: persisted defaults, validated edits, UI/automation consumers | I3: edits preserve independent preferences and migration stays owned. Inspected and retained; preference and script contracts pass |
| M4 | Build graph: source groups, C/Metal/resources, incremental outputs | I4: every shipped/test input resolves once and no retired source root remains active. Migrated and verified; remaining CI gate recorded below |
| M5 | Comparison runner: frozen bundles, owned PIDs, reports and cleanup | I5: valid complete results require matching contract and all owned processes reaped. Verified by process/failure regressions and strict two-order baseline |

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
| A1 | Explicit 30-row startup uses seed 19px height before first layout; actual font is 21px, yielding 27 PTY rows | Metrics independent of bounds; real CLI regression red on baseline and green in development/release | Fixed at `7f40e98`; three development and release font/grid cases pass |
| A2 | Ghostty serves its PTY from an owned descendant rather than the launcher PID | Validate report PID against retained observed-owned membership; keep natural exit and no-survivor checks | Fixed candidate; process unit test and both-order tiny comparison pass |
| A3 | Different native cell metrics rejected despite matching PTY grid/configured font/OPOST | Require matching cell geometry/mode; retain positive pixel dimensions as provenance, no pixel-matched FPS claim | Fixed candidate; both-order tiny comparison passes |
| A4 | Failed comparison lacked a reason/stage; nonzero app status hid the driver marker | Persist stage/failure and prioritize driver diagnostics | Fixed candidate; interruption evidence and nonzero-marker regression pass |
| A5 | Interrupt after spawn, including unwinding the constructor log block, could leak a launched app before the caller receives it | Initialize ownership state before spawn, store PID inside the log block, and reap on constructor unwind; arm caller cleanup before construction | Constructor regression now passes (5 process tests, 32 assertions); pre-fix constructor fails the same real-child fault injection |
| A6 | Wrong report label or two missing mode fields could satisfy comparison | Validate exact label and Boolean OPOST per app | Fixed candidate; corruption regressions pass |
| A7 | Source hash alone did not identify the executed frozen copy | Hash measured executable and reject source/copy mismatch | Fixed at `af41ca8`; full two-order comparison verifies source/copy executable hashes and clean exit |

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
- Sweep A Verify: three rotated reviews at `af41ca8`; two found no further delta defect, lifecycle reviewer confirmed the remaining constructor acquisition window in A5. Coordinator repaired it at the process owner; exact pre-fix reproduction fails and current test reaps the real child. The repeat at `c05d1bb` completed with all three reviewers reporting no further scoped finding. Sweep A is verified for that revision. Repeated-signal/SIGKILL behavior is not claimed as exhaustively tested.
- Sweep B Discover: three read-only lenses at `c05d1bb`: build/source ownership (terminal_coverage), preference/presentation interfaces (ghostty_features), benchmark contracts/consumers (cleanup_consumers). Conventional physical roots and canonical manifest paths replace implicit native prefixes. Preferences own app-only legacy migration; Canvas receives one validated value per apply. Removed the private header-title forwarding alias. Separate benchmark tools are retained because their contracts differ; their precise failure markers now precede generic exit checks. Tab navigation is a new task-owned AppKit menu owner, outside the PTY key encoder.
- Sweep B Challenge: three rotated reviewers on staged tree `900dcae`. Runtime preference/tab ownership and public contracts were intact. Build review found missing sdef/terminfo/icon verification plus stale current-guide links; these are repaired. Added real failing-driver regressions to `compare_terminal_apps`, `profile_terminal`, and `session_stream_diagnostic` (the newer Ghostty regression test retains its explicitly mocked process fixture); profile also checks the marker before its early-exit error. Optional native tab tests are separate from default headless tests. A root optimized native run selected the right tab but lost foreground; the test now asserts tab-group selection independently and explicitly skips event routing if foreground is unavailable. This is not evidence of a production selection defect. The private oracle ledger remains frozen evidence at its recorded oracle commit; its historical paths are intentionally preserved.
- Sweep B Verify: three rotated reviewers at staged tree `7c75192` found no further scoped production defect. `just verify` is only a plist/terminfo/signature gate, not independent proof of every bundled resource. A test-only follow-up replaces whole-test key counters with exact synthetic-event identities: unrelated real desktop input must not contaminate the no-fallthrough assertion. The ordinary synthetic key must reach its responder exactly once. Root optimized native run passes all selection and routing checks with no skip and no surviving test process; headless mode also passes. A scoped three-reviewer repeat covers this test delta.

## Remaining limits

This is a scoped correctness/module cleanup, not a claim of complete VT, IME,
VoiceOver, multi-display or concurrency conformance. Performance comparisons
measure PTY processing/barriers, not displayed FPS or input-to-photon latency.
CI verification will be recorded against its actual tested commit; an older
passing run is not a final-head pass.

## Sweep B integration batch

- Physical ownership: `Sources/Terminal` (one compiler module named `Terminal`),
  `Sources/Terminal/Interop`, `Sources/TerminalLauncher`, `Tests/TerminalTests`,
  `Resources/Terminal`, and `Benchmarks/TerminalBench`. Bundle names and resource
  destinations remain the existing runtime contract. `target/native` remains a
  build-output directory; archived reports keep historical paths.
- The manifest now contains canonical repository-relative paths. The builder
  resolves, verifies and prints them directly; every live recipe, generator,
  release input, cache key and current source guide migrates with it. The frozen
  revision comparison adapter explicitly accepts either manifest layout.
- Removed task-private `PaneTitle.headerTitle` (identical to `windowTitle`) and
  the old migration-control flag. `load()` owns production migration, while
  `load(from:)` retains isolated defaults injection. Saved keys and AppleScript
  parameters are policy-protected and unchanged.
- Canvas initialization reads one preference value. AppDelegate forwards its
  validated value to `applyPreferences(_:)`, keeping font/session settings in
  one update rather than independently rereading global defaults.
- Added native tab navigation through menu key equivalents: Cmd1–8 indexed,
  Cmd9 last, CmdOptionLeft/Right wrap. Missing indices are consumed no-ops.
  AppKit owns displayed order and first-responder restoration. Terminal key
  parsing is unchanged. Headless dispatch passes; optional native-window tests
  exercise selection, reorder, separate groups, singleton and field-editor
  restoration plus responder-routing positive/negative controls.
- During mechanical integration, a build overlapped file rewrites and correctly
  rejected changing inputs/PCH mtimes. That is an unfrozen integration attempt,
  not a baseline or final-artifact result. The frozen retry is tracked separately.

Sweep B Challenge repairs are integrated; final Verify repeat and integration validation are pending. Development app builds; WMO release compilation passes with module `Terminal` and app-source hash `a66945cd90f32548c98ebed50d5c33845f990ff61cce2b36e3628df0af8a2e67`. The full native suite is still running. Targeted failing-driver regressions pass: comparison 8 tests/12 assertions, profile 3/24, session diagnostic 1/8. Each owns a real short-lived fixture process and verifies empty cleanup survivors.

The first complete local `just test` attempt passed its Swift/protocol suites
through OSC 52, then failed compiling the moved C PTY test: its relative
`../Bridge.h` include still assumed the old layout. It now uses `Bridge.h` via
the explicit Interop include path. This was a migration regression, not a
baseline failure; the affected PTY/host checks and final CI must pass.

All three scoped reviewers verified the C include repair. The recompiled PTY
regression passes: locale variants, final-output drain, exec/cwd errors, bash,
fish, Neovim, tmux and fzf; children are reaped. Remaining host checks continue
from the interrupted suite. Exact-event native tab routing passes on the final
optimized test executable without its foreground skip.

## Release preflight follow-up

The native host checks interrupted by the C include repair were resumed. A
concurrent bundle rebuild then changed `target/native/Spawn.o` during the bridge
compile; that local validation attempt was invalid. After build output stopped
changing, the standalone snapshot-bridge and keymap checks passed. Local build
and test invocations sharing output directories must be serialized.

The full required checks have passed as local components (including real-GPU
residency), rather than one uninterrupted final `just test` invocation. CI run
[42684436222](https://github.com/HelgeSverre/terminal/actions/runs/42684436222)
at `45c8f7f` failed in the word-selection test's 100,000-turn polling limit.
It is a failed gate, not a verified final head. A controlled paused-word-worker
reproduction produces that exact error; releasing and draining the worker allows
completion. The test now synchronizes with the real asynchronous word queue
using a five-second timeout, retaining its owner-work bound and checking exact
Unicode selection across soft wraps. Production worker execution is unchanged.
The log did not identify the exact word action that failed on CI; attribution
to a particular call is not claimed.

Fresh Starship editing failures were separately traced to unowned desktop
keystrokes entering the smoke window before scripted input. Controlled two-event
injection reproduces 4→6→4; filtering only the smoke window restores 2→4→2.
The fixture permits its exact synthetic events through the existing AppKit
route and removes its monitor on completion/timeout. Strict cursor and ZLE
assertions remain. The portable `editing-input-isolation` recipe compiles
private variants, isolates other desktop input in both, and requires a red
baseline and green candidate with exactly two controlled probe rejections.
It stores only numeric editing evidence; no history suggestions are recorded.
No production prompt, shell hook, parser or normal input path changes.

These release-preflight fixes receive their own scoped review and validation;
CI and signed publication are pending on the next source commit. Installed live
sessions are outside the fixtures and remain untouched.

Release-preflight review: three read-only reviewers found no further issue in
staged tree `cfccb12`. Root's controlled portable regression passes (red baseline,
green candidate, stable input hashes, no survivors); the optimized complete
selection suite and clean development/WMO editing checks pass. Both release
startup grids and the earlier pane lifecycle checks pass. Final CI/publication
remain gated on the next source commit. Evidence is retained under
`reports/editing-input-isolation-2026-11-09` and
`reports/selection-word-worker-2026-11-09`.
