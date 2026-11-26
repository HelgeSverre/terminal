# Distribution, platforms and CI qualification

These procedures cover inventory V07–V09. They define repeatable acceptance
work; a procedure's existence does not certify a platform or artifact. Record
the tested commit, exact commands, host/OS/architecture, results and skips in a
compact dated summary following [reports/README.md](../reports/README.md).

## CI latency

The target is **under 300 seconds for both the native test step and complete
feedback**. Complete feedback runs from the earliest CI job start through the
`macOS · Swift native tests` aggregate check's completion. It includes setup,
cache transfer, protocol conformance and aggregate
scheduling. Runner queue time before the first job starts is reported separately
when relevant; it is not silently substituted for this boundary.

Baseline run [44069317138](https://github.com/HelgeSverre/terminal/actions/runs/44069317138)
had a 285-second native test step, 340-second headless job and 363-second complete
feedback interval. Native build time was 131.46 seconds. Post-build phases were:

| Phase | Seconds |
| --- | ---: |
| Syntax | 8.78 |
| Bundle | 3.80 |
| Developer tests | 38.80 |
| Workflow tooling | 12.46 |
| Terminfo | 2.75 |
| Font catalog | 2.44 |
| App tests | 73.95 |
| Glyph policy and tests | 4.11 |
| PTY | 1.90 |

CI opts into `TERMINAL_TEST_SHARDS=2`. The build, syntax check, bundle and font
catalog finish first. One serial lane runs developer tests, tooling and terminfo;
the other runs the app tests. The selected Swift toolchain's
`swiftpm-testing-helper` loads the already-built test bundle directly, with
`--no-parallel`, distinct XML paths and the matching macOS test runtime paths.
It does not start a second SwiftPM invocation or contend for its workspace lock.
Each test process has its own globals; developer fixtures use temporary paths
and do not use the app tests' preferences. The coordinator joins both lanes,
including on failure, before running glyph tests/policy and PTY checks. Do not
edit sources, rebuild, run independent tests or mutate the products while this
pipeline runs. At most two lanes are active; syntax's three parser workers run
before the lanes. Local `just test` keeps its serial default.

At unchanged phase durations the overlap removes **54.01 seconds** from the
critical path: developer tests + tooling + terminfo fit inside app tests. This
is an estimate, not a measured improvement. It predicts about 231 seconds for
the native step, 286 for the headless job and 309 for complete feedback before
setup changes. Homebrew automatic metadata refresh/cleanup is disabled on fresh
CI runners; formulae are still installed normally and their dylibs are not
cached. The remaining complete-feedback gap and concurrent-process contention
need actual runs. Do not mark V09 complete from this estimate.

SwiftPM's [runner invocation](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/Commands/SwiftTestCommand.swift)
and [runtime environment](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/Commands/Utilities/TestingSupport.swift)
are the parity references. Validate helper operation whenever changing Xcode.

For a completed ordinary CI run, save all jobs (currently four) and summarize
them using the compiled developer tool:

```shell
mkdir -p reports/ci-timing
gh api 'repos/HelgeSverre/terminal/actions/runs/RUN_ID/jobs?per_page=100' > reports/ci-timing/jobs.json
target/swiftpm/testing/debug/dev ci-timing reports/ci-timing/jobs.json reports/ci-timing/receipt.json
```

The receipt records run ID, source commit, both boundaries, headless duration,
all-gates success and the under-five-minute result. Missing jobs/timestamps are
errors; fast failures cannot meet the target. Keep the run URL and cache-hit
state alongside the receipt. Compare serial and two-lane runs at one frozen
commit; compare XML test counts/suite names and failures, not just wall time.
Repeat at least five cold-cache and five warm-cache runs before quoting a
median; retain individual values and label the sample size. Five runs do not
establish a robust p95. A cold run must explicitly bypass/remove the relevant
GitHub Actions cache rather than merely use a new source hash with a restore
prefix. Run only one local heavy job at a time.

## Support matrix

The declared minimums are macOS 14 and iOS 17, Swift tools 6.0. The desktop app
uses AppKit/Metal and ships universal arm64/x86_64 releases. iOS embeds the
libraries over a transport and launches no local PTY. These are product/build
claims; the following rows require evidence at the candidate commit.

| Combination | Required evidence |
| --- | --- |
| Apple silicon, macOS 26 hosted CI (Xcode 26.3) | Full headless, known-good conformance and bundle checks; preserve the exact paravirtual GPU disposition |
| Apple silicon, macOS 14 minimum | Build and launch frozen bundle; local PTY/input/resize/close, real Metal raster/residency, ordinary shell configuration |
| Apple silicon, newest available macOS | Same native gates plus mixed-DPI/display changes, sleep/wake, IME and VoiceOver recipes from their owners |
| Intel, macOS 14 | Run universal app's x86_64 slice on actual Intel hardware; PTY/input/resize and discrete/shared-heap Metal checks; cross-compilation alone is insufficient |
| iOS 17 minimum and newest available simulator | Build/test the embedding example; transport/input/selection/find/accessibility; record simulator/runtime/toolchain |
| Physical iOS device | Same interaction checks on the device; simulator results do not certify device GPU, input or accessibility |
| Swift 6 embedding host | Both examples/consumer-package checks from [embedding](embedding.md); no accidental app/updater dependency |
| SSH to macOS and a representative Linux host | Default TERM and terminfo lookup, tmux, shell editing, full-screen Neovim, colors, resize and reconnect |

Use an isolated detached checkout and a copied/frozen bundle. On a free build
slot, the existing recipes are `just test`, `just esctest`, `just fuzz 120`,
`just glyph-rendering-tests` and `just check`. Run native smokes individually
when they need window focus. `just ios-check "DEVICE_NAME"` requires the named
installed simulator and is a separate heavy job. Do not download simulators or
SDKs without planning their disk/resource cost. Record unsupported/unavailable
rows as pending with the exact missing hardware/runtime.

For SSH, connect from the candidate terminal with its unmodified default
environment. On the remote host capture `printf '%s\n' "$TERM" "$COLORTERM"`
and `infocmp "$TERM"`; expect `TERM=xterm-256color`, the remote system's own
entry and working 256-color clients without copying the app's terminfo database.
Exercise Backspace/arrows, bracketed paste, tmux panes, Neovim, 80→132→80 resize
and disconnect/reconnect. Repeat with no remote `TERMINFO` override. A separate
opt-in custom-entry case can test `helge-terminal` only after installing that
entry; it cannot replace the default SSH case. See [terminfo](terminfo.md).

## Signed distribution lifecycle

Use a disposable clean Mac/VM and account, with no existing terminal data,
Homebrew test tools or signing credentials. Do not use Helge's installed app or
preferences. Use **existing** signed artifacts and their published checksums;
these steps neither build/sign a new release nor publish one.

1. Record the two artifact versions, source commits, archive SHA-256 values and
   release URLs. Download through a browser to preserve quarantine. Extract in
   Finder, record quarantine attributes and keep an untouched archive copy.
2. Before launching, verify the extracted app with
   `codesign --verify --strict --deep "PATH/Helge Terminal.app"`,
   `spctl --assess --type execute --verbose=4 "PATH/Helge Terminal.app"` and
   `xcrun stapler validate "PATH/Helge Terminal.app"` where developer tools are
   available. A truly clean machine may lack `xcrun`; record this and perform
   trust assessment without installing an SDK merely for the check. Record
   `lipo -archs "PATH/Helge Terminal.app/Contents/MacOS/Terminal"` and the
   executable's SHA-256 on the evidence host.
3. Move the copy to the disposable machine's Applications directory and launch
   it from Finder with no extra arguments. Exercise normal shell startup, a PTY,
   split/resize/close, bundled fonts/shaders and terminfo. Verify a launch after
   reboot while offline, including trust behavior when notarization service
   access is unavailable. A command-line direct executable launch is not a
   substitute for the first quarantined Launch Services launch.
4. With fresh TCC state in that account, try shell access to Downloads/Desktop,
   an ordinary unprotected folder and an intentionally denied protected folder.
   Record each prompt and whether denial leaves a usable terminal. Exercise
   Automation/Accessibility only for features that request them. Use the
   disposable account's settings to grant/revoke permission; do not reset TCC
   globally on the development machine.
5. Install the older signed version in the disposable machine. Start normally
   (no arguments), choose Check for Updates, accept the newer version and verify
   the version, signature and executable identity after relaunch. Check a
   subsequent up-to-date response and retained preferences. This requires two
   existing versions and a feed that offers the selected successor; record an
   unavailable version/feed as blocked evidence. The preview UI does not prove
   installation: it deliberately cannot install.
6. Restore the disposable machine's pre-update snapshot for each interruption
   case: disconnect networking during download; cancel the download; interrupt
   only the test-owned app during the update handoff; retry/relaunch. Verify an
   intact signed older or newer app, a working shell, retained settings and no
   endless update loop. Record the exact interruption point and observed
   outcome; do not imply a rollback guarantee from one successful interruption.
7. Delete the disposable installation, reinstall from the archive and verify the
   documented data-retention behavior. Preserve a compact evidence summary and
   restore/remove the test machine. No release credentials belong in artifacts.

Signature/feed validation unit tests and ad hoc development builds remain useful
but do not close the clean-machine, cross-version update or permission rows.
See [releasing](releasing.md) for the actual release pipeline and credentials.
