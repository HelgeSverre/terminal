# Conformance and fuzzing

Two checks run in CI on every push to `main`, besides the test suite.

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
| Pass | 320 |
| Fail | 206 |
| Marked by esctest as known xterm deviations | 41 |

Measured on 2026-11-15 at esctest2 `2798f12`, with
`--expected-terminal=xterm --xterm-checksum=334`. The failures are mostly
features the emulator does not have: rectangular area operations (DECCRA,
DECERA, DECFRA, DECSERA), DECIC and DECDC, DECBI and DECFI, DECRQSS, window
manipulation beyond the size reports, the special colors of OSC 5, and
several DECRQM modes. `reports/esctest.json` lists them after a run.

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
