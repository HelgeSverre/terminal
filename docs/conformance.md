# Conformance and fuzzing

Two checks run in CI on every push to `main`, besides the test suite.
The [protocol coverage audit](protocol-coverage.md) maps image, input and related
protocol features to implementation, regression tests and known limitations.

## esctest

[esctest2](https://github.com/ThomasDickey/esctest2), Thomas Dickey's
conformance suite for xterm-compatible terminals, runs against the emulator
with `just esctest`. esctest runs on a PTY whose other end is the emulator;
it reads the screen back through DECRQCRA, one cell at a time. It is
GPL-2.0, so it is not kept in this repository: the recipe fetches it at a
fixed commit (`esctest_commit` in the `justfile`) into `target/esctest2`.

`Tests/Conformance/esctest-known-good.txt` lists the cases that pass. The run
fails when one of them stops passing, and names cases that newly pass;
`just esctest-update` rewrites the list after an improvement.

| Measured | Value (cases) |
| --- | --- |
| Run | 567 |
| Pass | 460 |
| Reported failures | 68 |
| Marked by esctest as known xterm deviations | 39 |

Measured on 2026-11-17 at source `556aa51`, esctest2 `2798f12`, with
`--expected-terminal=xterm --xterm-checksum=334 --xterm-reverse-wrap=383`.
These are now the harness defaults; the modern reverse-wrap profile matches
the implemented mode 45/1045 behavior. No previously passing case regressed.
The known-good gate now protects all 460 passes. The run at `b945624` earlier
the same day passed 447; the thirteen added cases are the DECDSR reports for
absent hardware, DECID, DECNKM and the DECSASD/DECSSDT status strings.

The 68 reported failures include two correct ISO-protection results that
upstream's known-bug decorators reject as unexpected passes. The remainder
are unsupported color spellings (21), DECRQM modes that are not recognized
(22), window changes that are intentionally prohibited (9), xterm identity
expectations for DA and DA2 (4), status strings outside the bounded subset
(4), and conformance-level and 80/132-column switching (3 each). See the exact
[protocol dispositions](protocol-discovery.md) and
[VT dispositions](gap-vt-conformance.md). A run writes each case to
`reports/esctest.json`, which is not kept in the repository.
The earlier 2026-11-15 baseline was 320 passes, 206 failures and 41 known
xterm deviations with the legacy reverse-wrap profile.

## Fuzzing

`Tests/TerminalTests/TerminalFuzzer.swift` makes seeded cases from the
escape-code grammar: text in every script, CSI with odd parameters, private
modes, OSC, Sixel and other DCS, Kitty graphics, repeats and damaged bytes,
with resizes, snapshots and history limits between them. After each step
the emulator's invariants must hold and the step must make progress.

| Where | What runs |
| --- | --- |
| The test suite | 150 fixed cases |
| CI | Two minutes of random cases |
| `just fuzz SECONDS` | Random cases for as long as asked |

`just fuzz` builds the emulator with Address Sanitizer and exclusivity
checks. A failure prints its seed; `just fuzz-replay SEED` runs it again and
writes its bytes to `reports/fuzz-SEED.bin`. A crash leaves the seed in
`reports/fuzz-current-seed`.

The first ten-minute run, on 2026-11-15, passed 3,834 cases and 22 MiB of
input.
