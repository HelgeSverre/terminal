# Kitty graphics repairs and real-client validation

Source: `a9aa3e574b3de9daefe8ef864abdae80bb9161e7`, pushed to main.
macOS 15.6 arm64, Swift 6.2.4. G3–G7 from the protocol inventory are fixed;
real-client testing additionally found and fixed G8 (current Kitty transport).
This is targeted compatibility evidence, not complete protocol conformance.

## Automated checks

`just test` passed on the exact committed source: 120 developer tests,
379 terminal tests, 13 GPU tests, plus tooling, terminfo, font and PTY gates.
The PTY corpus includes Bash, Fish, Neovim, tmux and fzf. The focused graphics
coverage now comprises 56 tests across KittyGraphicsExtensionTests,
TerminalGraphicsOracleTests and TerminalImageTests.

Earlier attempts hit two clipboard timeouts and one unrelated Codex fixture
shutdown timeout. Clipboard isolation and subsequent complete gates passed.
The fixture timeout occurred during substantial concurrent machine load;
the final complete run passed without changing that fixture or its timeout.

Regression cases cover frame promotion/deletion and accounting; elapsed time
and loops across edits; relative children of ordinary/virtual parents;
active-screen changes, history eviction and positional deletion; supported
query keys; invalid identity combinations; pending-upload preservation;
128 KiB transport chunks, raw base64 and matching-action continuation.
Initial targeted red runs exposed 27 assertions, then seven additional edge
assertions; these passed after repair. The real Kitty PNG was blank before G8
and visible after it.

The 20,000-row history regression reports 100 snapshots in 4.81 ms and 100
snapshots with live edits in 4.86 ms on the final run. This is a diagnostic
test measurement, not a release throughput benchmark. Cache storage is at
most 256 extrema pairs plus a tail ID, with incremental history scanning.
Test executable SHA-256:
`8de36e28d8332f8adc6e85a362f99cded6c487e18561221d40687ab578d2d18c`.

Two read-only reviews covered specification and repository standards separately.
Spec: no remaining finding after query identity and transport corrections.
Standards: no material finding after eliminating repeated whole-history scans;
bounded graphics-parent lookups are distinct from viewport FollowTail anchoring.
`gitleaks git --log-opts=c79e56d..a9aa3e5 --redact --no-banner`: no leaks.

## Frozen app and native checks

The optimized debug/test bundle from `dev bundle testing` was copied, given
the isolated identifier `no.helgesverre.terminal.kitty-validation-final`, and
ad-hoc signed before use. Frozen executable SHA-256:
`7da6a88f631ca86806ebdf42669b207bf3b7c85d9a4ccca74c04c32053716cb3`.
No installed app was replaced or driven. Each test owned its app/processes.

Using `target/swiftpm/testing/debug/dev` with the frozen bundle:

- `native-smoke normal`, `editing`, `pane-lifecycle`, `resize`: passed,
  including clean termination and 360 resize events.
- `selection-smoke APP`: passed mouse gestures, private-pasteboard copy,
  reflow, mouse routing and close cleanup.
- `accessibility-smoke APP`: passed external attributed-text reads,
  styles/link checks, read-only AXValue and cleanup; no permission prompt.

The native runner used `TERMINAL_NATIVE_SMOKE_EXECUTABLE` and
`TERMINAL_NATIVE_SMOKE_REPORT_DIRECTORY`; the other runners used their
selection/accessibility report-directory overrides.

## Actual applications, visually inspected

Input PNG was this repository's `assets/AppIcon.png`. The animated GIF was
three 160×100 solid red/green/blue frames with 100-centisecond delays and an
infinite loop. Screenshots were inspected through the native desktop tool.

| Client | Exercise and result |
| --- | --- |
| kitten icat 0.45.0 | `--transfer-mode stream --place 35x18@2x2 --hold PNG`: PNG visible after G8; Enter exits directly |
| kitten icat 0.45.0 | GIF with `--transfer-mode stream --hold`: red and blue frames observed at different times |
| tmux 3.7c + icat | Private `-L` server, `-f /dev/null`, pane `allow-passthrough all`, `--passthrough tmux`: large Unicode-placeholder image visible; hold-to-exit input issue below |
| Neovim 0.12.5 + Snacks | PNG opened using a minimal isolated config, inside private tmux; image and `:vsplit` resizing both visible; `:qa!` and shell exit restored the outer screen |
| Chafa 1.18.3 | `--format kitty --size 25x10 PNG`: image visible on the final build |

Snacks was pinned to `882c996cf28183f4d63640de0b4c02ec886d01f2` from
`folke/snacks.nvim`. Config only appended that clone to runtimepath, enabled
`image`, disabled swap/shada and suppressed Neovim's intro screen.
Final successful runs used `SNACKS_KITTY=true`; user configuration was not changed.

## Remaining compatibility work

- Snacks' default terminal-name allowlist does not recognize Helge Terminal.
  The default attempt displayed its unsupported-terminal message; the documented
  `SNACKS_KITTY=true` override works, including images through tmux.
- With tmux's default `extended-keys off`, `kitten icat --hold` displayed its
  image but ignored native Enter, Escape and Ctrl-C, including after explicitly
  focusing the pane. The owned viewer was terminated by PID; Neovim input and
  exit subsequently worked in the same tmux session. Cause has not been isolated
  between the client, tmux configuration and terminal key negotiation. Do not
  count this as a complete interactive-icat pass.
- Physical CJK input-method switching, VoiceOver speech/navigation, mixed-DPI
  display moves, Intel/iOS runtime behavior and exhaustive animation/crop/alpha/
  z-order pixel oracles were not tested. The AX check is not a VoiceOver test.

Raw logs, client clone, fixtures and temporary app copies were local validation
artifacts. This compact summary retains the conclusions and provenance.
