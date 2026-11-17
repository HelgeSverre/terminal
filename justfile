# Native macOS terminal.
set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

export TERMINAL_PROJECT_ROOT := justfile_directory()

# The test suites run optimized, with testing enabled so they can reach
# internal declarations, and one at a time: several hold process-wide state.
swift_test := "TERMINAL_TEST_HOOKS=1 swift test --scratch-path target/swiftpm/testing -c debug -Xswiftc -O --jobs 3 --no-parallel --disable-xctest"

# The emulator's sources, for the few programs still compiled directly.
emulator_sources := "-package-name terminal -I Sources/TerminalInterop/include Sources/TerminalEngine/Text/*.swift Sources/TerminalEngine/Emulation/*.swift"
esctest_commit := "2798f12"
spawn_object := "xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=14.0 -I Sources/TerminalInterop/include -c Sources/TerminalInterop/Spawn.c -o target/native/Spawn.o"

[private]
default:
    @just --list --unsorted

# ── build ─────────────────────────────────────────────────────────────

# Build the development app bundle.
[group('build')]
@build: _dev
    target/native/dev bundle development

# Build the optimized bundle used by install and release.
[group('build')]
@release-build: _dev
    target/native/dev bundle release

# Build with release optimization and diagnostic entry points for benchmarks.
[group('build')]
@diagnostic-build: _dev
    target/native/dev bundle diagnostic

# Remove build outputs (target/, dist/) and stray compiler module files.
[group('build')]
clean:
    rm -rf target dist .build
    rm -f Terminal-*.abi.json Terminal-*.swiftdoc Terminal-*.swiftmodule Terminal-*.swiftsourceinfo

# ── run ───────────────────────────────────────────────────────────────

# Launch a separate dev instance; extra args go to the app.
[group('run')]
@dev *args: build
    open -n "$TERMINAL_PROJECT_ROOT/dist/Terminal.app" --args "$@"

# Preview the current version’s changelog in Sparkle; no update is installed.
[group('run')]
@update-preview: _dev
    target/native/dev update-preview

# Run the dev build under LLDB.
[group('run')]
@debug: build
    lldb -- "$TERMINAL_PROJECT_ROOT/dist/Terminal.app/Contents/MacOS/Terminal"

# Stream the app's log messages.
[group('run')]
logs:
    /usr/bin/log stream --info --style compact --predicate 'process == "Terminal"'

# Open a window printing every supported Nerd Font glyph.
[group('run')]
glyphs: build
    dist/Terminal.app/Contents/MacOS/Terminal --font-catalog "$PWD/reports/font-glyphs.txt"
    open -n "$PWD/dist/Terminal.app" --args --execute /bin/cat "$PWD/reports/font-glyphs.txt"

# ── install ───────────────────────────────────────────────────────────

# Install an optimized build to ~/Applications/Helge Terminal.app.
[group('install')]
install: release-build
    just _distribution install

# Remove the installed app; settings are kept.
[group('install')]
uninstall:
    just _distribution uninstall

# Rebuild and replace the installed app.
[group('install')]
reinstall: install

# Open the installed app.
[group('install')]
@open:
    open "$HOME/Applications/Helge Terminal.app"

# ── check ─────────────────────────────────────────────────────────────

# Format hand-written Swift; generated tables are skipped.
[group('check')]
fmt: _dev
    target/native/dev sources format

# Verify the source graph and Swift syntax.
[group('check')]
@lint: _dev
    target/native/dev sources check

# Full local gate: tests plus the GUI smokes.
[group('check')]
check: test smoke pane-lifecycle-smoke startup-grid-smoke close-smoke selection-smoke resize-smoke intense-resize-smoke

# Validate the bundle plist, terminfo and signature.
[group('check')]
verify: build
    plutil -lint dist/Terminal.app/Contents/Info.plist
    /usr/bin/infocmp -x -A dist/Terminal.app/Contents/Resources/terminfo helge-terminal >/dev/null
    TERMINFO="$PWD/dist/Terminal.app/Contents/Resources/terminfo" /usr/bin/tput -T helge-terminal colors | grep -qx 256
    codesign --verify --strict --deep dist/Terminal.app

# ── test ──────────────────────────────────────────────────────────────

# Check Launch Services discovery and command-file delivery in an isolated app.
[group('test')]
@terminal-file-smoke: build
    target/native/dev terminal-file-smoke

# Run every headless test suite.
[group('test')]
@test: _test-build
    target/swiftpm/testing/debug/dev test

[private]
@_test-build:
    TERMINAL_TEST_HOOKS=1 swift build --build-tests --scratch-path target/swiftpm/testing -c debug -Xswiftc -O --jobs 3

# Arguments go to `swift test`: `just unit-test --filter SessionTests`.
# Run the Swift Testing suites.
[group('test')]
@unit-test *arguments:
    {{swift_test}} {{arguments}}

# Tooling tests; no app launch or GPU.
[group('test')]
@workflow-tests: _test-build
    {{swift_test}} --filter DevTests
    TERMINAL_TEST_PRODUCTS="$PWD/target/swiftpm/testing/debug" just _workflow-tools

[private]
@_workflow-tools:
    mkdir -p target/native
    "$TERMINAL_TEST_PRODUCTS/dev" tui-stress --prepare
    "$TERMINAL_TEST_PRODUCTS/dev" rendering-proof --prepare
    "$TERMINAL_TEST_PRODUCTS/TUIStressDriver" --self-test
    xcrun clang -Wall -Wextra -Werror -O2 Benchmarks/TerminalBench/terminal-bench-clock-test.c -o target/native/terminal-bench-clock-test
    target/native/terminal-bench-clock-test
    xcrun swiftc -D DISTRIBUTION_TESTING -parse-as-library tools/Distribution.swift tools/DistributionTests.swift -o target/native/distribution-tests
    target/native/distribution-tests
    mkdir -p target/native/automation-dictionary
    xcrun sdp -fs -o target/native/automation-dictionary Resources/Terminal/Terminal.sdef

[group('test')]
terminfo-test: build _terminfo-test

# Glyph raster and residency tests; needs a real GPU.
[group('test')]
glyph-rendering-tests: build _glyph-rendering-tests

# ── smoke ─────────────────────────────────────────────────────────────

# Drive the real app: PTY, IME, split panes and Metal.
[group('smoke')]
smoke: build (_native-smoke "normal")

# zsh cd, autosuggestion and Backspace editing in the real app.
[group('smoke')]
editing-smoke: build (_native-smoke "editing")

# Split, close, resize and click-to-focus panes.
[group('smoke')]
pane-lifecycle-smoke: build (_native-smoke "pane-lifecycle")

# Mouse selection gestures and private-pasteboard copy.
[group('smoke')]
selection-smoke: build _dev
    target/native/dev selection-smoke

# Requested startup grid before the first layout.
[group('smoke')]
startup-grid-smoke: build _dev
    target/native/dev startup-grid-smoke dist/Terminal.app reports/startup-grid.json

[group('smoke')]
resize-smoke: build _dev
    target/native/dev native-smoke resize

# Seeded divider and window resizes, in both directions, over streaming panes.
[group('smoke')]
intense-resize-smoke: build _dev
    target/native/dev native-smoke intense-resize

# Closing the last window must exit the app and its children.
[group('smoke')]
close-smoke: build _dev
    target/native/dev close-smoke

[group('smoke')]
accessibility-smoke: build _dev
    target/native/dev accessibility-smoke

[group('smoke')]
automation-smoke: build _dev
    target/native/dev applescript-smoke

# Only request Automation consent.
[group('smoke')]
automation-consent: build _dev
    TERMINAL_AUTOMATION_REQUEST_CONSENT=1 TERMINAL_AUTOMATION_PREFLIGHT_ONLY=1 target/native/dev applescript-smoke

# Every Nerd Font glyph through PTY, grid, rasterizer and Metal.
[group('smoke')]
glyph-smoke: build (_native-smoke "glyph")
    dist/Terminal.app/Contents/MacOS/Terminal --font-catalog "$PWD/reports/font-glyphs.txt"

[group('smoke')]
atlas-smoke: build (_native-smoke "atlas")

[group('smoke')]
atlas-budget-smoke: build (_native-smoke "atlas-budget")

# Measure an idle pane for 60 seconds.
[group('smoke')]
idle: build (_native-smoke "idle")

# Self-test the TUI stress helpers; no GUI.
[group('smoke')]
tui-stress-prepare: _dev
    target/native/dev tui-stress --prepare

# Stress a copy of the installed app with Files or Codex.
[group('smoke')]
tui-stress workload="files": _dev
    target/native/dev tui-stress --installed --workload "$1"

# Capture the README overview screenshot.
[group('smoke')]
gallery-overview: build _dev
    target/native/dev gallery overview

# Capture the README panes screenshot.
[group('smoke')]
gallery-panes: build _dev
    target/native/dev gallery panes

# ── bench ─────────────────────────────────────────────────────────────

# Compare the optimized app, Ghostty and Kitty in both orders.
[group('bench')]
@benchmark-terminals output="reports/terminal-comparison": diagnostic-build _dev
    target/native/dev compare-terminals "$1"

# Compare warm startup time with Ghostty, Kitty, iTerm2 and Apple Terminal.
[group('bench')]
@benchmark-startup output="reports/startup-comparison" rounds="10": diagnostic-build _dev
    target/native/dev compare-startup dist/Terminal.app "$1" "$2"

# Compare launch to a visible window and to the shell's first output on screen.
[group('bench')]
@benchmark-visible-startup output="reports/visible-startup-comparison" rounds="10": diagnostic-build _dev
    target/native/dev compare-visible-startup dist/Terminal.app "$1" "$2"

# Compare key-to-program latency, idle and under an output flood.
[group('bench')]
@benchmark-input-latency output="reports/input-latency-comparison" keys="100": diagnostic-build _dev
    target/native/dev compare-input-latency dist/Terminal.app "$1" "$2"

# Compare quit time with Ghostty, Kitty, iTerm2 and Apple Terminal.
[group('bench')]
@benchmark-shutdown output="reports/shutdown-comparison" rounds="5": diagnostic-build _dev
    target/native/dev compare-shutdown dist/Terminal.app "$1" "$2"

[group('bench')]
@benchmark-apps baseline candidate output="reports/app-comparison": _dev
    target/native/dev compare-terminal-apps "$3" "$1" "$2"

[group('bench')]
@stress-cat app file output: _dev
    target/native/dev cat-stress "$1" "$2" "$3"

[group('bench')]
@stress-cat-motion app file output: _dev
    target/native/dev cat-stress "$1" "$2" "$3" motion

[group('bench')]
@profile-app app output workload="all": _dev
    target/native/dev profile-terminal "$1" "$2" "$3"

# Short-ASCII PTY flow with owner counters; not an acceptance test.
[group('bench')]
@diagnose-stream app output bytes: _dev
    target/native/dev diagnose-stream "$1" "$2" "$3"

# ── diagnose ──────────────────────────────────────────────────────────

# Replay stdin through the emulator; JSON on stdout, replies on stderr.
[group('diagnose')]
@replay columns="80" rows="24": _terminfo-probe
    target/native/terminfo-probe "$1" "$2"

# ── release ───────────────────────────────────────────────────────────

# Build the Developer ID signed app and ZIP.
[group('release')]
package: release-build
    just _distribution package

# Sign, notarize, staple and validate the app and ZIP.
[group('release')]
release: release-build
    just _distribution release

# Check signing identities and notarization credentials.
[group('release')]
release-status:
    just _distribution status

# ── helpers ───────────────────────────────────────────────────────────

# Build the developer tool (tools/Dev) when its sources are newer. Sources are
# given by absolute path: the tool finds the repository from where it was built.
[private]
@_dev:
    mkdir -p target/native
    if [[ ! -x target/native/dev || -n "$(find tools/Dev -newer target/native/dev -print -quit)" ]]; then xcrun swiftc -O "$PWD"/tools/Dev/*.swift -o target/native/dev; fi

[private]
@_native-smoke mode: _dev
    target/native/dev native-smoke "$1"

[private]
@_distribution operation:
    mkdir -p target/native
    xcrun swiftc -parse-as-library tools/Distribution.swift -o target/native/distribute
    target/native/distribute "$1"

[private]
_glyph-rendering-tests:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p reports/gpu-policy target/native
    rm -f reports/gpu-policy/glyph-residency.json
    just _glyph-raster-tests
    if [[ "${TERMINAL_CI_GPU_POLICY:-}" != "paravirtual" ]]; then
      just _glyph-residency-tests
      exit 0
    fi
    xcrun swiftc -parse-as-library Tests/Programs/MetalUploadProbe.swift -framework Metal -o target/native/metal-upload-probe
    set +e
    target/native/metal-upload-probe 2>&1 | tee reports/gpu-policy/metal-upload-probe.log
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    probe_status="${pipeline_status[0]}"
    if [[ "${pipeline_status[1]}" != "0" ]]; then exit "${pipeline_status[1]}"; fi
    if [[ "$probe_status" == "139" ]] && grep -q 'METAL_UPLOAD_DEVICE=name=Apple Paravirtual' reports/gpu-policy/metal-upload-probe.log && grep -q 'METAL_UPLOAD_PROBE=after_shared_texture_replace' reports/gpu-policy/metal-upload-probe.log && grep -q 'METAL_UPLOAD_PROBE=before_shared_heap_texture_replace' reports/gpu-policy/metal-upload-probe.log && ! grep -q 'METAL_UPLOAD_PROBE=after_shared_heap_texture_replace' reports/gpu-policy/metal-upload-probe.log; then
    printf '%s\n' '{"status":"skipped","reason":"Apple Paravirtual SIGSEGV on shared heap texture replace after standalone upload passed","local_real_gpu_required":true}' > reports/gpu-policy/glyph-residency.json
    echo 'SKIPPED glyph residency: hosted Apple Paravirtual shared-heap upload driver fault; local real-GPU gate remains required'
    elif [[ "$probe_status" == "0" ]]; then
    just _glyph-residency-tests
    else
    exit "$probe_status"
    fi

[private]
@_glyph-raster-tests:
    {{swift_test}} --filter GlyphRasterWorkerTests

[private]
@_glyph-residency-tests:
    {{swift_test}} --filter GlyphResidency

# Standalone Metal texture upload check, as the hosted-runner policy runs it.
[group('test')]
metal-upload-probe:
    mkdir -p target/native
    xcrun swiftc -parse-as-library Tests/Programs/MetalUploadProbe.swift -framework Metal -o target/native/metal-upload-probe
    target/native/metal-upload-probe

[private]
_terminfo-test: _terminfo-probe _dev
    target/native/dev terminfo-smoke

# Run esctest2 against the emulator and compare with the known-good list.
[group('test')]
esctest *options: _esctest-build
    target/native/esctest target/esctest2 Tests/Conformance/esctest-known-good.txt reports/esctest.json {{options}}

# Run esctest2 and make the known-good list the cases that pass now.
[group('test')]
esctest-update: _esctest-build
    target/native/esctest target/esctest2 Tests/Conformance/esctest-known-good.txt reports/esctest.json --update

# esctest2 is GPL-2.0 and not kept here: it is fetched at a fixed commit.
[private]
@_esctest-build:
    mkdir -p target/native reports Tests/Conformance
    if [[ ! -d target/esctest2/.git ]]; then git clone -q https://github.com/ThomasDickey/esctest2.git target/esctest2; fi
    git -C target/esctest2 checkout -q {{esctest_commit}} 2>/dev/null || (git -C target/esctest2 fetch -q && git -C target/esctest2 checkout -q {{esctest_commit}})
    xcrun swiftc -swift-version 5 -O {{emulator_sources}} Tests/Programs/EscTest.swift -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/esctest

# Run the terminal view on the iOS simulator: Examples/iOSCheck.
[group('test')]
ios-check device="iPhone 16":
    cd Examples/iOSCheck && xcodebuild test -quiet -scheme iOSCheck-Package -destination "platform=iOS Simulator,name={{device}}" -derivedDataPath .build-xc

# Fuzz the emulator for a number of seconds, with Address Sanitizer and
# exclusivity checks. Heavy: one at a time, like the test suite.
[group('test')]
fuzz seconds="60" seed="": _fuzz-build
    target/native/fuzz {{seconds}} {{seed}}

# Run one fuzz case again and keep its bytes in reports/.
[group('test')]
fuzz-replay seed: _fuzz-build
    target/native/fuzz replay {{seed}}

[private]
@_fuzz-build:
    mkdir -p target/native
    xcrun swiftc -swift-version 5 -O -g -sanitize=address -enforce-exclusivity=checked -D FUZZ_PROGRAM {{emulator_sources}} Tests/TerminalTests/TerminalFuzzer.swift Tests/Programs/Fuzz.swift -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/fuzz

[private]
@_terminfo-probe:
    mkdir -p target/native
    xcrun swiftc -swift-version 5 -O {{emulator_sources}} Tests/Programs/TerminfoProbe.swift -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminfo-probe
