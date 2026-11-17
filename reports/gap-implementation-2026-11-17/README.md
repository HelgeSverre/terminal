# Gap implementation validation — 2026-11-17

Integration baseline: `dfd25d8`. Machine: macOS 15.6, Apple Silicon,
12 logical CPUs; Xcode 26.3 (17C529). Local validation is complete;
these results qualify the stated revisions. Subsequent documentation-only
commits do not change the tested source.

## Automated checks

| Source | Command/configuration | Result |
| --- | --- | --- |
| `306a592` | `just test`, serial pipeline | PASS: 126 developer tests, 507 application tests, 16 GPU tests; tooling, terminfo, font and PTY checks passed. |
| `5d46b01` | `TERMINAL_TEST_SHARDS=2 just test` | PASS: 126 developer tests, 511 application tests, 16 GPU tests; tooling, terminfo, font and PTY checks passed. |
| `5d46b01` | `xcodebuild test -quiet -jobs 3 -parallel-testing-enabled NO -scheme iOSCheck-Package`, development/test-hook environment variables unset | PASS: 7 tests, zero failures or skips, iPhone 16 simulator with iOS 26.3.1. Disposable simulator removed afterward. |
| `b945624` | `just esctest`, modern reverse-wrap profile 383 | PASS regression gate: 447 passing, 81 reported failures, 39 known deviations, no regression. `224f8ae` promotes the 447 passes to the protected baseline. |
| `5da3cb5` | `target/swiftpm/testing/debug/dev embedding-check` | PASS: consumer graph excludes Sparkle/development targets; Swift 6 consumer hosts compile. |
| `129ca48` | `gitleaks git --redact --log-opts='dfd25d8..HEAD'` | PASS: 77 commits, no leaks. |

The serial post-build pipeline took 120.785 seconds; the two-lane pipeline took
73.254 seconds. Both exclude the initial build. The final incremental test build
reported 44.79 seconds. This is neither a controlled load comparison nor a
cold-build result or hosted CI percentile. Hosted timing remains pending.
The PTY corpus covers Bash, fish, Neovim, tmux and fzf.

An initial iOS simulator compilation failed because a find action selector
collided with `UIResponder.next`. The fix integrated at `3caff84` passed the
simulator rerun above. No physical-device result is claimed.

## Native runtime checks

Frozen `5d46b01` executable SHA-256 after private identity and ad-hoc signing:
`b705f3b9840c074046868be803419d555053e1b8bd793f6c5b12096e35f62c51`.
Bundle identity: `no.helgesverre.terminal.gap-validation`, version 0.6.2 (22).

- `dev native-smoke normal`, `editing`, and `pane-lifecycle` passed using
  `TERMINAL_NATIVE_SMOKE_EXECUTABLE` set to this frozen executable.
- `dev terminal-file-smoke` passed cold and warm Launch Services opening with
  a private fixture identity. Literal paths containing spaces, quotes and shell
  syntax executed on a PTY without command injection.
- Unattended launch with `--background --state-directory … --execute /bin/sh …`
  started the intended child and wrote both `RECOVERY_FINAL` markers without
  any startup dialog. After killing only the owned app, relaunch restored the
  same window/pane IDs, opened a fresh shell and exposed both markers through
  Read output history. Normal Cmd-Q exited cleanly and left the private state
  directory empty. The original child also exited; no test process survived.

Earlier evidence follows; the final checks above supersede its startup caveat.

Frozen `7f1c250` executable SHA-256:
`ed54e6d73d7147ee313f59979af04293f53dd3774f6b9de729a96260d08e494e`.
Normal, editing and pane-lifecycle smoke checks passed. Pane movement preserved
the session/title owner, and leaving zoom restored the layout.

Frozen `306a592` validation bundle executable SHA-256 after assigning its
private bundle identity and ad-hoc signing:
`a7e499b24bf2de96386c691d61b32b72676a23b99470c009fb6f6514041bf66c`.
Bundle identity: `no.helgesverre.terminal.gap-validation`, version 0.6.2 (22).

- Crash recovery: launched an owned child printing two markers, confirmed its
  checkpoint, killed only the owned app, and relaunched with its private state
  directory. The same pane/window IDs restored, a fresh shell started, and
  accessibility history exposed both markers plus the restoration marker.
  Normal Cmd-Q removed the private recovery state. Startup document error
  dialogs required dismissal in this run; `ac19dfd` and `129ca48` address the
  argument routing defect. Unattended confirmation on the fixed binary is pending.
- AppleScript: `dev applescript-smoke` with `TERMINAL_AUTOMATION_SOURCE` pointing
  at the frozen app passed all fixture scenarios, with existing automation
  consent and no surviving owned children. The raw receipt's revision defaulted
  to the checkout HEAD (`129ca48`); the tested binary is **306a592**, identified
  by the hash above. Future frozen-source runs must also set
  `TERMINAL_AUTOMATION_SOURCE_REVISION` explicitly.
- Snacks: Neovim 0.12.5, pinned Snacks
  `882c996cf28183f4d63640de0b4c02ec886d01f2` plus the repository fixture patch.
  All `SNACKS_KITTY/GHOSTTY/WEZTERM/HELGE` overrides were unset; force was false.
  The receipt reported identity `HelgeTerminal`, version `0.6.2`, environment
  `helge`, support/placeholders/image-buffer true, and passed true. Visual
  inspection confirmed the expected terminal icon. This is the direct native
  path; private tmux and SSH variants are not established by this run.

Raw logs, receipts and copied bundles remain ignored under
`reports/gap-implementation/`. No installed terminal was changed. Hardware,
external-client and release qualification is tracked in
[implementation status](../../docs/gap-implementation-status.md).
