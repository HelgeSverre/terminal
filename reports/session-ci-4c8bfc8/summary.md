# Swift Session CI evidence — `swift-candidate-4c8bfc8`

The Swift candidate snapshot `4c8bfc8cebbc0a0a189253316e89a22c7f787eb5`
ran the isolated, headless `just _session-test` successfully on 2026-11-08.
The process exited `0`; its fresh UUID is
`9DFFC7B9-BF5C-49E4-B584-5950032CAB0E`.

All 25 checks passed, including the deterministic resumable-REP boundary
contract, real PTY receipt of bracketed paste, logical split-CWD inheritance,
and close/reap verification. The latter sampled all seven owned sessions after
close: each explicitly reported `child_reaped: true`; no PID remained
unreaped.

The earlier CI run `42525367796` on `88aa5ef` failed for a test-fixture timing
assumption, not a split-CWD or product-session failure. Its uploaded structured
report was fresh (its SHA-256 differed from the tracked pre-run report) and had
exactly one false check: `input_before_mode_suffix`. That check inferred parser
ordering from a coalesced UI snapshot after a 500,000-count REP. Coalescing may
legitimately deliver only after the bracketed-paste suffix has been processed.
The replacement checks the resumable C-ABI boundary directly (unbracketed before
the suffix is accepted; bracketed after) and retains the real PTY receipt
assertion.

`session-tests.json` is the structured source evidence, `exit.txt` records the
observed process result, and `source.sha256` records the exact Swift-candidate
inputs used by the successful run. These files archive evidence from the Swift
candidate workspace; they do not claim that this Main checkout ran that binary.
