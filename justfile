# Native macOS terminal.
set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

export TERMINAL_PROJECT_ROOT := justfile_directory()

[private]
default:
    @just --list --unsorted

# ── build ─────────────────────────────────────────────────────────────

# Build the development app bundle.
[group('build')]
@build: icons (_assemble-bundle "development")

# Build the optimized bundle used by install and release.
[group('build')]
@release-build: icons (_assemble-bundle "release")

# Remove build outputs (target/, dist/) and stray compiler module files.
[group('build')]
clean:
    rm -rf target dist
    rm -f Terminal-*.abi.json Terminal-*.swiftdoc Terminal-*.swiftmodule Terminal-*.swiftsourceinfo

# Regenerate app icons from assets/AppIcon.png.
[group('build')]
@icons:
    #!/usr/bin/env bash
    set -euo pipefail
    ICONSET=target/native/Terminal.iconset
    if [[ target/native/Terminal.icns -nt assets/AppIcon.png ]]; then exit 0; fi
    mkdir -p "$ICONSET"
    for SIZE in 16 32 128 256 512; do
      sips -z "$SIZE" "$SIZE" assets/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
      DOUBLE=$((SIZE * 2))
      sips -z "$DOUBLE" "$DOUBLE" assets/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o target/native/Terminal.icns

# ── run ───────────────────────────────────────────────────────────────

# Launch a separate dev instance; extra args go to the app.
[group('run')]
@dev *args: build
    open -n "$TERMINAL_PROJECT_ROOT/dist/Terminal.app" --args "$@"

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
lint: _dev
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    target/native/dev sources check

# Full local gate: tests plus the GUI smokes.
[group('check')]
check: test smoke pane-lifecycle-smoke startup-grid-smoke close-smoke selection-smoke

# Validate the bundle plist, terminfo and signature.
[group('check')]
verify: build
    plutil -lint dist/Terminal.app/Contents/Info.plist
    /usr/bin/infocmp -x -A dist/Terminal.app/Contents/Resources/terminfo helge-terminal >/dev/null
    TERMINFO="$PWD/dist/Terminal.app/Contents/Resources/terminfo" /usr/bin/tput -T helge-terminal colors | grep -qx 256
    codesign --verify --strict --deep dist/Terminal.app

# Clean rebuild, then require an incremental no-op.
[group('check')]
swift-build-test:
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swift tools/SwiftIncrementalBuild.swift --clean
    output="$(xcrun swift tools/SwiftIncrementalBuild.swift)"; [[ "$output" == "Swift incremental no-op;"* ]]

# ── test ──────────────────────────────────────────────────────────────

# Run every headless test suite.
[group('test')]
@test: lint build
    just workflow-tests
    just settings-window-test
    just visible-links-test
    just _terminfo-test
    just _clipboard-access-tests
    just _shell-editing-test
    dist/Terminal.app/Contents/MacOS/Terminal --font-catalog "$PWD/reports/font-glyphs.txt"
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    just emulator-test
    just terminal-document-ownership
    just terminal-document-oracle
    just terminal-viewport-oracle
    just history-search-test
    just terminal-reflow-semantics
    just terminal-selection
    just terminal-presented-content
    just terminal-prompt-clear-oracle
    just terminal-scheduler-oracle
    just terminal-semantic-regression
    just terminal-boundary-regression
    just terminal-graphics-oracle
    just terminal-palette
    just unicode18-corpus
    just unicode-decoder
    just unicode-lowercase
    just terminal-width
    just input-encoder
    just window-stress-motion-test
    just tab-navigation-test
    just osc52-protocol
    xcrun clang -Wall -Wextra -Werror -I Sources/Terminal/Interop -c Tests/TerminalTests/pty.c -o target/native/swift-pty-tests.o
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print pty) target/native/swift-pty-tests.o target/native/Spawn.o -framework Foundation -framework CoreGraphics -framework ImageIO -framework CoreFoundation -framework Security -liconv -o target/native/pty-tests
    target/native/pty-tests "$PWD/dist/Terminal.app/Contents/MacOS/TerminalLauncher"
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print transport) -o target/native/transport-tests
    target/native/transport-tests
    just session-io-test
    just _session-test
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print geometry) -o target/native/geometry-tests
    target/native/geometry-tests
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print statistics) -o target/native/statistics-tests
    target/native/statistics-tests
    just _glyph-rendering-tests
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print preferences) -framework AppKit -o target/native/preferences-tests
    target/native/preferences-tests
    xcrun swiftc -D SNAPSHOT_ABI_DIAGNOSTICS -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print snapshot_bridge) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/snapshot-bridge-tests
    target/native/snapshot-bridge-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print keymap) -framework AppKit -framework CoreText -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/keymap-tests
    target/native/keymap-tests

# Tooling tests; no app launch or GPU.
[group('test')]
workflow-tests: _dev
    mkdir -p target/native
    target/native/dev self-test
    xcrun swiftc -parse-as-library -O tools/tui_stress/Driver.swift -o target/native/tui-stress-driver-tests
    target/native/tui-stress-driver-tests --self-test
    xcrun clang -Wall -Wextra -Werror -O2 Benchmarks/TerminalBench/terminal-bench-clock-test.c -o target/native/terminal-bench-clock-test
    target/native/terminal-bench-clock-test
    xcrun swiftc -D DISTRIBUTION_TESTING -parse-as-library tools/Distribution.swift tools/DistributionTests.swift -o target/native/distribution-tests
    target/native/distribution-tests
    mkdir -p target/native/automation-dictionary
    xcrun sdp -fs -o target/native/automation-dictionary Resources/Terminal/Terminal.sdef

[group('test')]
session-test: build _session-test

[group('test')]
session-io-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print session_ingress) -o target/native/session-ingress-tests
    target/native/session-ingress-tests
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print pty_descriptor_lifetime) -o target/native/pty-descriptor-lifetime-tests
    target/native/pty-descriptor-lifetime-tests
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print pty_read_broker) -o target/native/pty-read-broker-tests
    target/native/pty-read-broker-tests
    xcrun swiftc -D SESSION_IO_TESTING -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print pty_read_endpoint) -o target/native/pty-read-endpoint-tests
    target/native/pty-read-endpoint-tests
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print pty_admission) -o target/native/pty-admission-tests
    target/native/pty-admission-tests

# Interactive zsh editing through a real PTY.
[group('test')]
shell-editing-test: build _shell-editing-test

[group('test')]
settings-window-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 $(xcrun swift tools/SwiftIncrementalBuild.swift --print settings_window) -framework AppKit -framework CoreText -o target/native/settings-window-tests
    target/native/settings-window-tests

[group('test')]
emulator-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print emulator) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/emulator-tests
    target/native/emulator-tests

[group('test')]
history-search-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print history_search) -framework Foundation -o target/native/history-search-tests
    target/native/history-search-tests

[group('test')]
terminal-graphics-oracle:
    mkdir -p target/native
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_graphics_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-graphics-oracle-tests
    target/native/terminal-graphics-oracle-tests

[group('test')]
terminal-palette:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_palette) -framework Foundation -o target/native/terminal-palette-tests
    target/native/terminal-palette-tests

[group('test')]
terminal-prompt-clear-oracle:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_prompt_clear_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-prompt-clear-oracle
    target/native/terminal-prompt-clear-oracle

[group('test')]
terminal-scheduler-oracle:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_scheduler_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-scheduler-oracle
    target/native/terminal-scheduler-oracle

[group('test')]
terminal-document-oracle:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_document_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-document-oracle-tests
    target/native/terminal-document-oracle-tests

[group('test')]
terminal-document-ownership:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_document_ownership) -framework Foundation -o target/native/terminal-document-ownership-tests
    target/native/terminal-document-ownership-tests

[group('test')]
terminal-viewport-oracle:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_viewport_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-viewport-oracle-tests
    target/native/terminal-viewport-oracle-tests

[group('test')]
terminal-reflow-semantics:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_reflow_semantics) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-reflow-semantics-tests
    target/native/terminal-reflow-semantics-tests

[group('test')]
terminal-semantic-regression:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_semantic_regression) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-semantic-regression
    target/native/terminal-semantic-regression

[group('test')]
terminal-boundary-regression:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_boundary_regression) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-boundary-regression
    target/native/terminal-boundary-regression

[group('test')]
terminal-selection:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_selection) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-selection-tests
    target/native/terminal-selection-tests

[group('test')]
terminal-presented-content:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print presented_content) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/presented-content-tests
    target/native/presented-content-tests

[group('test')]
visible-links-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print visible_links) -framework Foundation -framework AppKit -framework CoreText -o target/native/visible-links-tests
    target/native/visible-links-tests

[group('test')]
unicode18-corpus:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print unicode18_corpus) -framework Foundation -o target/native/unicode18-corpus
    target/native/unicode18-corpus "$PWD" --strict

[group('test')]
unicode-decoder:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print unicode_decoder) -framework Foundation -o target/native/unicode-decoder-tests
    target/native/unicode-decoder-tests

[group('test')]
unicode-lowercase:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print unicode_lowercase) -framework Foundation -o target/native/unicode-lowercase-tests
    target/native/unicode-lowercase-tests

[group('test')]
terminal-width:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_width) -framework Foundation -o target/native/terminal-width-tests
    target/native/terminal-width-tests

[group('test')]
input-encoder:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print input_encoder) -framework Foundation -o target/native/input-encoder-tests
    target/native/input-encoder-tests

[group('test')]
osc52-protocol:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print osc52_protocol) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/osc52-protocol-tests
    target/native/osc52-protocol-tests

[group('test')]
terminfo-test: build _terminfo-test

[group('test')]
clipboard-access-test: build _clipboard-access-tests

[group('test')]
tab-navigation-test:
    mkdir -p target/native
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print tab_navigation) -framework AppKit -o target/native/tab-navigation-tests
    target/native/tab-navigation-tests

[group('test')]
window-stress-motion-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print window_stress_motion) -framework AppKit -framework Foundation -framework CoreGraphics -o target/native/window-stress-motion-tests
    target/native/window-stress-motion-tests

# Glyph raster and residency tests; needs a real GPU.
[group('test')]
glyph-rendering-tests: build _glyph-rendering-tests

[group('test')]
metal-upload-probe:
    mkdir -p target/native
    xcrun swiftc -parse-as-library $(xcrun swift tools/SwiftIncrementalBuild.swift --print metal_upload_probe) -framework Metal -o target/native/metal-upload-probe
    target/native/metal-upload-probe

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

# PTY throughput: just benchmark terminal|ghostty|kitty [output].
[group('bench')]
@benchmark terminal output="reports/comparison":
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT_DIR="$TERMINAL_PROJECT_ROOT"
    TERMINAL_NAME="${1:-}"
    case "$TERMINAL_NAME" in terminal|ghostty|kitty) ;; *) echo "usage: $0 terminal|ghostty|kitty [output-directory]" >&2; exit 2 ;; esac
    REPORT_DIR="${2:-$ROOT_DIR/reports/comparison}"
    mkdir -p "$REPORT_DIR" target/native
    REPORT_DIR="$(cd "$REPORT_DIR" && pwd)"
    BYTES="${BENCH_BYTES:-16777216}"
    RUNS="${BENCH_RUNS:-5}"
    xcrun clang -Wall -Wextra -Werror -O2 Benchmarks/TerminalBench/terminal-bench.c -o target/native/terminal-bench
    DRIVER="$ROOT_DIR/target/native/terminal-bench"
    REPORT="$REPORT_DIR/$TERMINAL_NAME.json"
    if [[ -e "$REPORT" ]]; then echo "Refusing to overwrite $REPORT; choose a new output directory." >&2; exit 2; fi
    ARGS=(--output "$REPORT" --terminal "$TERMINAL_NAME" --bytes "$BYTES" --runs "$RUNS" --columns 100 --rows 30)
    case "$TERMINAL_NAME" in
      terminal)
        APP="$ROOT_DIR/dist/Terminal.app"
        if [[ ! -x "$APP/Contents/MacOS/Terminal" ]]; then just build; fi
        "$APP/Contents/MacOS/Terminal" --columns 100 --rows 30 --font-size 14 --history-limit 10000 --exit-after-command --execute "$DRIVER" "${ARGS[@]}" > "$REPORT_DIR/terminal-launch.log" 2>&1 &
        ;;
      ghostty)
        APP=/Applications/Ghostty.app
        "$APP/Contents/MacOS/ghostty" +version > "$REPORT_DIR/ghostty-version.txt"
        cat > "$REPORT_DIR/ghostty.conf" <<'CONFIG'
    config-default-files = false
    font-family = Obel Mono
    font-size = 14
    cursor-style-blink = false
    background-opacity = 1
    window-width = 100
    window-height = 30
    window-padding-x = 8
    window-padding-y = 8
    scrollback-limit-lines = 10000
    scrollback-limit-bytes = 67108864
    shell-integration = none
    confirm-close-surface = false
    quit-after-last-window-closed = true
    window-save-state = never
    CONFIG
        open -na "$APP" --args --config-default-files=false --config-file="$REPORT_DIR/ghostty.conf" -e "$DRIVER" "${ARGS[@]}"
        ;;
      kitty)
        APP=/Applications/kitty.app
        "$APP/Contents/MacOS/kitty" --version > "$REPORT_DIR/kitty-version.txt"
        open -na "$APP" --args -c NONE -o 'font_family=Obel Mono' -o font_size=14 -o initial_window_width=100c -o initial_window_height=30c -o remember_window_size=no -o cursor_blink_interval=0 -o scrollback_lines=10000 -o background_opacity=1 -o shell_integration=disabled -o window_padding_width=8 "$DRIVER" "${ARGS[@]}"
        ;;
    esac
    sw_vers > "$REPORT_DIR/os-version.txt"
    shasum -a 256 "$DRIVER" "$APP/Contents/MacOS/$( [[ "$TERMINAL_NAME" == terminal ]] && echo Terminal || echo "$TERMINAL_NAME" )" > "$REPORT_DIR/$TERMINAL_NAME-binaries.sha256"
    for ((attempt = 0; attempt < 600; attempt++)); do
      if [[ -e "$REPORT" ]]; then
        jq '{terminal,columns,rows,idle_cpu_percent_one_core,idle_physical_bytes,workloads:[.workloads[]|{name,mib_per_second}],dsr_roundtrip_ms}' "$REPORT"
        BENCH_APP_PID="$(jq -r '.terminal_pid' "$REPORT")"
        BENCH_APP_COMMAND="$(ps -p "$BENCH_APP_PID" -o command= || true)"
        case "$BENCH_APP_COMMAND" in
          "$APP/Contents/MacOS/"*"$DRIVER"*"$REPORT"*) kill -TERM "$BENCH_APP_PID" 2>/dev/null || true ;;
        esac
        exit 0
      fi
      if [[ -e "$REPORT.failed" ]]; then cat "$REPORT.failed" >&2; exit 1; fi
      sleep 1
    done
    echo "No complete report after 600 seconds. Inspect the separate benchmark window for errors." >&2
    exit 1

# Compare the optimized app, Ghostty and Kitty in both orders.
[group('bench')]
@benchmark-terminals output="reports/terminal-comparison": release-build _dev
    target/native/dev compare-terminals "$1"

# Compare warm startup time with Ghostty, Kitty, iTerm2 and Apple Terminal.
[group('bench')]
@benchmark-startup output="reports/startup-comparison" rounds="10": release-build _dev
    target/native/dev compare-startup dist/Terminal.app "$1" "$2"

# Compare launch to a visible window and to the shell's first output on screen.
[group('bench')]
@benchmark-visible-startup output="reports/visible-startup-comparison" rounds="10": release-build _dev
    target/native/dev compare-visible-startup dist/Terminal.app "$1" "$2"

# Compare key-to-program latency, idle and under an output flood.
[group('bench')]
@benchmark-input-latency output="reports/input-latency-comparison" keys="100": release-build _dev
    target/native/dev compare-input-latency dist/Terminal.app "$1" "$2"

# Compare quit time with Ghostty, Kitty, iTerm2 and Apple Terminal.
[group('bench')]
@benchmark-shutdown output="reports/shutdown-comparison" rounds="5": release-build _dev
    target/native/dev compare-shutdown dist/Terminal.app "$1" "$2"

[group('bench')]
@benchmark-apps rust_app swift_app output="reports/app-comparison": _dev
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

[group('diagnose')]
@compare-swift-rows baseline candidate output: _dev
    target/native/dev compare-swift-rows "$1" "$2" "$3"

# Run the CSI corpus against two frozen Swift refs.
[group('diagnose')]
compare-csi baseline candidate output: _dev
    target/native/dev compare-csi-dispatch "$1" "$2" "$3"

# Keyboard isolation in copied smoke fixtures.
[group('diagnose')]
editing-input-isolation app output: _dev
    target/native/dev editing-input-isolation "$1" "$2"

# ── release ───────────────────────────────────────────────────────────

# Build the Developer ID signed app, ZIP and PKG.
[group('release')]
package: release-build
    just _distribution package

# Sign, notarize, staple and validate the app and PKG.
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
@_assemble-bundle configuration:
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT_DIR="$TERMINAL_PROJECT_ROOT"
    BUILD_DIR="$ROOT_DIR/target/native"
    APP_BUNDLE="$ROOT_DIR/dist/Terminal.app"
    case "$1" in development) CONFIGURATION=development; OUTPUT_DIRECTORY=swift-incremental ;; release) CONFIGURATION=release; OUTPUT_DIRECTORY=swift-release ;; *) echo "Unknown build configuration: $1" >&2; exit 2 ;; esac
    mkdir -p "$BUILD_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
    xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 Sources/TerminalLauncher/Launcher.c -o "$APP_BUNDLE/Contents/MacOS/TerminalLauncher"
    xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 -c Sources/Terminal/Interop/Spawn.c -o "$BUILD_DIR/Spawn.o"
    xcrun -sdk macosx metal -c Resources/Terminal/Terminal.metal -o "$BUILD_DIR/Terminal.air"
    xcrun -sdk macosx metallib "$BUILD_DIR/Terminal.air" -o "$APP_BUNDLE/Contents/Resources/Terminal.metallib"
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swift tools/SwiftIncrementalBuild.swift --configuration "$CONFIGURATION"
    cp "$ROOT_DIR/target/$OUTPUT_DIRECTORY/Terminal" "$APP_BUNDLE/Contents/MacOS/Terminal"
    cp Resources/Terminal/Info.plist "$APP_BUNDLE/Contents/Info.plist"
    cp Resources/Terminal/Terminal.sdef "$APP_BUNDLE/Contents/Resources/Terminal.sdef"
    /usr/bin/tic -x -o "$APP_BUNDLE/Contents/Resources/terminfo" Resources/Terminal/Terminal.terminfo
    cp target/native/Terminal.icns "$APP_BUNDLE/Contents/Resources/Terminal.icns"
    ditto Resources/Terminal/ShellIntegration "$APP_BUNDLE/Contents/Resources/ShellIntegration"
    ditto assets/fonts "$APP_BUNDLE/Contents/Resources/Fonts"
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/TerminalLauncher"
    codesign --force --sign - "$APP_BUNDLE"

[private]
@_native-smoke mode: _dev
    target/native/dev native-smoke "$1"

[private]
@_distribution operation:
    mkdir -p target/native
    xcrun swiftc -parse-as-library tools/Distribution.swift -o target/native/distribute
    target/native/distribute "$1"

[private]
_session-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print session) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/session-tests
    target/native/session-tests "$PWD"

[private]
_shell-editing-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print shell_editing) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/shell-editing-tests
    env -u LANG -u LC_ALL -u LC_CTYPE -u NO_COLOR -u CLICOLOR -u CLICOLOR_FORCE -u FORCE_COLOR target/native/shell-editing-tests "$PWD"

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
    xcrun swiftc -parse-as-library $(xcrun swift tools/SwiftIncrementalBuild.swift --print metal_upload_probe) -framework Metal -o target/native/metal-upload-probe
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
_glyph-raster-tests:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print glyph_raster_worker) -framework AppKit -framework CoreText -o target/native/glyph-raster-worker-tests
    target/native/glyph-raster-worker-tests

[private]
_glyph-residency-tests:
    mkdir -p target/native
    xcrun swiftc -D GLYPH_RESIDENCY_TESTING $(xcrun swift tools/SwiftIncrementalBuild.swift --print glyph_residency) -framework AppKit -framework CoreText -framework Metal -o target/native/glyph-residency-tests
    target/native/glyph-residency-tests

[private]
_terminfo-test: _terminfo-probe _dev
    target/native/dev terminfo-smoke

[private]
_terminfo-probe:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify >&2
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminfo_probe) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminfo-probe

[private]
_clipboard-access-tests:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header Sources/Terminal/Interop/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print clipboard_access) target/native/Spawn.o -framework AppKit -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/clipboard-access-tests
    target/native/clipboard-access-tests "$PWD"
