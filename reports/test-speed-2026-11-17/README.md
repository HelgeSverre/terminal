# Test speed, 2026-11-17

The headless gate now compiles the app, developer tool, suites and existing
integration probes in one optimized SwiftPM graph. It retains serial suite
execution, real PTY tests, tooling checks and GPU coverage. Protocol conformance
and the 120-second address-sanitizer fuzzer run as independent CI jobs; the
original required check aggregates all three results. Release signing still
builds independently on a fresh runner without test artifacts.

## Baseline

- [Artifact-only release candidate](https://github.com/HelgeSverre/terminal/actions/runs/43977693224)
  at `9a6265145d80824cf913d795e918eddb6777afe9`: headless gate 11m07s.
  Most time was repeated compilation: test graph 3m06s, development bundle
  about 2m, and standalone emulator probes about 2m16s.
- [Normal CI with an exact cache hit](https://github.com/HelgeSverre/terminal/actions/runs/43980716905)
  at `c26d1670469855f4d99916a04a720d857f149152`: headless step 12m38s,
  job 18m16s. Fresh checkout timestamps still caused source recompilation.

## Local verification

Tested source `4dde102` in the isolated `terminal-test-speed` worktree:

| Measurement | Result |
| --- | ---: |
| `just clean`, then `/usr/bin/time -p just test` | **251.62s (4m12s)** |
| SwiftPM clean build within that gate | 126.96s |
| Developer tests, including process startup | 43.76s |
| Application tests, including process startup | 51.27s |
| Syntax check, three processes maximum | 5.47s |
| Test bundle assembly | 4.60s |
| Other tooling checks | 10.18s |
| Terminfo / font catalog / GPU / PTY phases combined | 7.65s |

All 120 developer tests, 362 application tests, one raster test and 12 residency
tests passed, plus the existing standalone tooling and PTY checks. This machine
has a real GPU; no GPU coverage was skipped. The checkout's build outputs were
removed before timing; the machine's global dependency download cache was warm.

Artifact SHA-256 from that clean run:

- `dist/Terminal.app/Contents/MacOS/Terminal`:
  `363cac69777b7613719717b7c8cbeb570406a31dc169379ae6c72df816ae0799`
- `target/swiftpm/testing/debug/dev`:
  `2eb466f1ebb0b070f68bea657d4eb8fead9a4653b76b6e2e0550942261972abf`

Controlled cache experiment at the same workspace path:

- Touching 304 tracked inputs without changing content and rebuilding without
  timestamp restoration took **113.98s**.
- Restoring the same pre-experiment build cache and using `just _test-build`
  took **3.33s**; all 304 verified timestamps restored, no source recompilation.
- A real one-file comment edit restored only the other 303 inputs and rebuilt
  the changed TerminalUI source in **2.91s**. The probe edit was removed.
- Cache tests cover edited/new/removed files, exact nanosecond timestamps,
  symlinks, malformed receipts and mismatched workspace paths.

Follow-up commits preserve the original required CI check and route suite
execution through `just unit-test --skip-build`. `actionlint`, Swift parsing,
recipe expansion, whitespace checks and six aggregate-check pass/fail/skip
scenarios passed. Cache reuse is limited to an identical workspace path and
platform/toolchain; it does not claim relocatable SwiftPM build products.

## Hosted verification

Source `695a094c0318ddb6976b6964c554f611a0a8bf31`:

- [Cold run](https://github.com/HelgeSverre/terminal/actions/runs/44055498953):
  all four jobs passed. The headless test step took **6m04s**, including a
  180.25-second clean SwiftPM build. Developer tests took 48.92s and app tests
  78.74s including process startup. The cache was absent and then saved.
  Headless job: 7m15s; complete workflow including queue and aggregate: 7m31s.
- Hosted testing passed 120 developer, 362 app and one raster test. The existing
  Apple Paravirtual policy skipped residency tests; those passed on the local
  real GPU above. The assembled app passed bundle verification.
- The conformance job succeeded with its existing non-strict policy: 320 passed,
  206 failed, 41 known bugs out of 567 cases. This change does not repair those
  existing emulator gaps or claim every conformance case passes.
- The full 120-second address-sanitizer fuzz run passed.
- [Cached repeat](https://github.com/HelgeSverre/terminal/actions/runs/44056722791):
  headless test step **3m04s**, complete headless job **4m08s**, including setup,
  cache restore, bundle verification and artifact upload. All 304 unchanged
  inputs had timestamps restored; SwiftPM completed in 13.29s. Developer/app
  phases were 43.77s/76.27s. Test counts and the GPU policy matched the cold run.
- The repeat's fuzz job hit `seed 1794908162713`, `step 25: over 10 seconds`.
  The aggregate correctly failed even though headless and conformance passed.
  The emulator and fuzzer source are unchanged from `c26d167`. Local
  `just fuzz-replay 1794908162713` passed under Address Sanitizer; a second replay
  of the already-built binary passed in **3.43s**. The budget in the existing
  harness applies to the entire case, not an individual step. A successful
  local replay does not establish why the hosted case exceeded its budget.
  Local replay executable SHA-256:
  `4d9655c3811cbca06c26769c77db27acda0f91821fdd5df43a2fc91c699ba612`.
  The failed jobs were retried. The full 120-second fuzz retry passed 520 cases
  (3,060 KiB), without changing the timeout or fuzzer. The first failed attempt
  remains recorded here; retry success is not evidence that its cause is fixed.

The five-minute target is met for the cached hosted headless job and the clean
local gate. A fully cold hosted build still exceeds it. No suite or fuzz budget
was reduced to obtain these timings.
