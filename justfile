# Native macOS terminal. Run `just` to see common workflows.
set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

# Diagnose fixed short-ASCII PTY flow with opt-in owner counters (not acceptance).
[group('bench')]
@diagnose-stream app output bytes:
    ruby tools/session_stream_diagnostic.rb "$1" "$2" "$3"
export TERMINAL_PROJECT_ROOT := justfile_directory()

# Show available commands
@default:
    just --list --unsorted

# Print every supported Nerd Font glyph in a separate terminal window
[group('check')]
glyphs: build
    dist/Terminal.app/Contents/MacOS/Terminal --font-catalog "$PWD/reports/font-glyphs.txt"
    open -n "$PWD/dist/Terminal.app" --args --execute /bin/cat "$PWD/reports/font-glyphs.txt"

# Verify every Nerd Font glyph through the PTY, grid, rasterizer and Metal
[group('check')]
glyph-smoke: build (_native-smoke "glyph")
    dist/Terminal.app/Contents/MacOS/Terminal --font-catalog "$PWD/reports/font-glyphs.txt"

# Close the last window; require both the app and its HUP-resistant child to exit
[group('check')]
close-smoke: build
    #!/usr/bin/env ruby
    require 'json'
    require 'timeout'
    ['window', 'shortcut'].each do |mode|
      report_path = File.join(Dir.pwd, "reports/close-#{mode}-smoke.json")
      File.delete(report_path) if File.exist?(report_path)
      app = File.join(Dir.pwd, 'dist/Terminal.app/Contents/MacOS/Terminal')
      flags = mode == 'shortcut' ? ['--quit-shortcut'] : []
      pid = Process.spawn(app, '--close-smoke', report_path, *flags, '--execute', '/bin/sh', '-c', "trap '' HUP; printf CLOSE_SMOKE_READY; exec /bin/sleep 30", out: File::NULL, err: File::NULL)
      app_reaped = false
      child = nil
      gone = true
      begin
        Timeout.timeout(8) { Process.wait(pid) }
        app_reaped = true
        report = JSON.parse(File.read(report_path))
        child = report.fetch('child_pid')
        raise 'invalid child PID' unless child > 0
        begin; Process.kill(0, child); gone = false; rescue Errno::ESRCH; gone = true; end
        report['app_exited'] = true
        report['child_exited'] = gone
        report['passed'] = gone && report.fetch('trigger') == (mode == 'shortcut' ? 'cmd+q' : 'last-window-close')
        File.write(report_path, JSON.pretty_generate(report) + "\n")
        abort 'Child survived window closure' unless report['passed']
        puts "PASS #{mode} closure: application exited and PTY child reaped"
      ensure
        unless app_reaped
          begin; Process.kill('KILL', pid); Process.wait(pid); rescue Errno::ESRCH, Errno::ECHILD; end
        end
        if defined?(child) && child && child > 0 && defined?(gone) && !gone
          begin; Process.kill('KILL', child); rescue Errno::ESRCH; end
        end
      end
    end

# Build the incremental development bundle.
[group('build')]
@build: icons (_assemble-bundle "development")

# Build the whole-module-optimized bundle used for installation and distribution.
[group('build')]
@release-build: icons (_assemble-bundle "release")

[private]
@_assemble-bundle configuration:
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT_DIR="$TERMINAL_PROJECT_ROOT"
    BUILD_DIR="$ROOT_DIR/target/native"
    APP_BUNDLE="$ROOT_DIR/dist/Terminal.app"
    case "$1" in development) CONFIGURATION=development; OUTPUT_DIRECTORY=swift-incremental ;; release) CONFIGURATION=release; OUTPUT_DIRECTORY=swift-release ;; *) echo "Unknown build configuration: $1" >&2; exit 2 ;; esac
    mkdir -p "$BUILD_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
    xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 native/Launcher.c -o "$APP_BUNDLE/Contents/MacOS/TerminalLauncher"
    xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 -c native/Spawn.c -o "$BUILD_DIR/Spawn.o"
    xcrun -sdk macosx metal -c native/Terminal.metal -o "$BUILD_DIR/Terminal.air"
    xcrun -sdk macosx metallib "$BUILD_DIR/Terminal.air" -o "$APP_BUNDLE/Contents/Resources/Terminal.metallib"
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swift tools/SwiftIncrementalBuild.swift --configuration "$CONFIGURATION"
    cp "$ROOT_DIR/target/$OUTPUT_DIRECTORY/Terminal" "$APP_BUNDLE/Contents/MacOS/Terminal"
    cp native/Info.plist "$APP_BUNDLE/Contents/Info.plist"
    cp native/Terminal.sdef "$APP_BUNDLE/Contents/Resources/Terminal.sdef"
    cp target/native/Terminal.icns "$APP_BUNDLE/Contents/Resources/Terminal.icns"
    ditto native/ShellIntegration "$APP_BUNDLE/Contents/Resources/ShellIntegration"
    ditto assets/fonts "$APP_BUNDLE/Contents/Resources/Fonts"
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/TerminalLauncher"
    codesign --force --sign - "$APP_BUNDLE"

# Generate all macOS icon sizes from the original app icon
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

# Build and launch a separate development instance; pass app arguments after dev
[group('build')]
@dev *args: build
    open -n "$TERMINAL_PROJECT_ROOT/dist/Terminal.app" --args "$@"

# Build and install a whole-module-optimized copy in ~/Applications/Helge Terminal.app
[group('build')]
install: release-build
    xcrun swift tools/Distribution.swift install

# Remove only this app's installed bundle; preserve settings and project output
[group('build')]
uninstall:
    xcrun swift tools/Distribution.swift uninstall

# Build and replace the installed copy, keeping the previous copy if build fails
[group('build')]
reinstall: install

# Open the installed app
[group('build')]
@open:
    open "$HOME/Applications/Helge Terminal.app"

# Format sources retained only as the Rust behavioral baseline for differential replay.
[group('check')]
fmt:
    cargo fmt --all

# Check formatting and strict Rust lints
[group('check')]
lint:
    cargo fmt --all -- --check
    cargo clippy --locked --workspace --all-targets -- -D warnings

# Run the complete Rust and native transport/session/bridge test suite
[group('check')]
@test: build
    dist/Terminal.app/Contents/MacOS/Terminal --font-catalog "$PWD/reports/font-glyphs.txt"
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    just swift-core-test
    just terminal-document-ownership
    just terminal-document-oracle
    just terminal-viewport-oracle
    just terminal-reflow-semantics
    just terminal-prompt-clear-oracle
    just terminal-scheduler-oracle
    just terminal-semantic-regression
    just terminal-boundary-regression
    just swift-unicode18-corpus
    just unicode-lowercase
    just terminal-width
    just swift-input-encoder
    just window-stress-motion-test
    just osc52-protocol
    xcrun clang -Wall -Wextra -Werror -I native -c native/tests/pty.c -o target/native/swift-pty-tests.o
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print pty) target/native/swift-pty-tests.o target/native/Spawn.o -framework Foundation -framework CoreGraphics -framework ImageIO -framework CoreFoundation -framework Security -liconv -o target/native/pty-tests
    target/native/pty-tests "$PWD/dist/Terminal.app/Contents/MacOS/TerminalLauncher"
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print transport) -o target/native/transport-tests
    target/native/transport-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print session) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/session-tests
    target/native/session-tests "$PWD"
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print geometry) -o target/native/geometry-tests
    target/native/geometry-tests
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print statistics) -o target/native/statistics-tests
    target/native/statistics-tests
    just glyph-rendering-tests
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print preferences) -o target/native/preferences-tests
    target/native/preferences-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print snapshot_bridge) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/snapshot-bridge-tests
    target/native/snapshot-bridge-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print keymap) -framework AppKit -framework CoreText -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/keymap-tests
    target/native/keymap-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_document_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-document-oracle-tests
    target/native/terminal-document-oracle-tests

# Swift-only terminal-state smoke.  The original Rust suite remains an
# independent differential oracle under `just parity-baseline`.
[group('check')]
swift-core-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print swift_core) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/swift-core-tests
    target/native/swift-core-tests

[group('check')]
window-stress-motion-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print window_stress_motion) -framework AppKit -framework Foundation -framework CoreGraphics -o target/native/window-stress-motion-tests
    target/native/window-stress-motion-tests

# Headless residency/worker checks; run after build for the production Metal library.
[group('check')]
glyph-rendering-tests:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print glyph_raster_worker) -framework AppKit -framework CoreText -o target/native/glyph-raster-worker-tests
    target/native/glyph-raster-worker-tests
    xcrun swiftc -D GLYPH_RESIDENCY_TESTING $(xcrun swift tools/SwiftIncrementalBuild.swift --print glyph_residency) -framework AppKit -framework CoreText -framework Metal -o target/native/glyph-residency-tests
    target/native/glyph-residency-tests

[group('check')]
terminal-prompt-clear-oracle:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_prompt_clear_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-prompt-clear-oracle
    target/native/terminal-prompt-clear-oracle

[group('check')]
terminal-scheduler-oracle:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_scheduler_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-scheduler-oracle
    target/native/terminal-scheduler-oracle

[group('check')]
terminal-document-oracle:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_document_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-document-oracle-tests
    target/native/terminal-document-oracle-tests

[group('check')]
terminal-document-ownership:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_document_ownership) -framework Foundation -o target/native/terminal-document-ownership-tests
    target/native/terminal-document-ownership-tests

[group('check')]
terminal-viewport-oracle:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_viewport_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-viewport-oracle-tests
    target/native/terminal-viewport-oracle-tests

[group('check')]
terminal-reflow-semantics:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_reflow_semantics) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-reflow-semantics-tests
    target/native/terminal-reflow-semantics-tests

[group('check')]
terminal-semantic-regression:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_semantic_regression) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-semantic-regression
    target/native/terminal-semantic-regression

[group('check')]
terminal-boundary-regression:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_boundary_regression) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-boundary-regression
    target/native/terminal-boundary-regression

[group('check')]
swift-unicode18-corpus:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print swift_unicode18_corpus) -framework Foundation -o target/native/swift-unicode18-corpus
    target/native/swift-unicode18-corpus "$PWD" --strict

[group('check')]
swift-input-encoder:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print swift_input_encoder) -framework Foundation -o target/native/swift-input-encoder-tests
    target/native/swift-input-encoder-tests

[group('check')]
osc52-protocol:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print osc52_protocol) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/osc52-protocol-tests
    target/native/osc52-protocol-tests

[group('check')]
terminal-width:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_width) -framework Foundation -o target/native/terminal-width-tests
    target/native/terminal-width-tests

[group('check')]
unicode-lowercase:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print unicode_lowercase) -framework Foundation -o target/native/unicode-lowercase-tests
    target/native/unicode-lowercase-tests

# Exercise the real native app, PTY, IME, split panes and Metal, then quit it
[group('check')]
smoke: build (_native-smoke "normal")

# Reproduce native cd/autosuggestion/Backspace editing against the actual ZLE buffer
[group('check')]
editing-smoke: build (_native-smoke "editing")

# Measure a visible pane at idle for 60 seconds, then quit the test instance
[group('check')]
idle: build (_native-smoke "idle")

# Full local gate, including the GUI smoke
[group('check')]
check: test smoke

# Measure the headless core in release mode
[group('bench')]
benchmark-core:
    cargo run --release --locked -p terminal-tools --bin benchmark

# Compare PTY throughput: just benchmark terminal|ghostty|kitty [new-report-directory]
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
    xcrun clang -Wall -Wextra -Werror -O2 native/benchmarks/terminal-bench.c -o target/native/terminal-bench
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

# Build and run in LLDB
[group('debug')]
@debug: build
    lldb -- "$TERMINAL_PROJECT_ROOT/dist/Terminal.app/Contents/MacOS/Terminal"

# Stream this app's native log messages
[group('debug')]
logs:
    /usr/bin/log stream --info --style compact --predicate 'process == "Terminal"'

# Validate bundle metadata and its ad-hoc signature
[group('check')]
verify: build
    plutil -lint dist/Terminal.app/Contents/Info.plist
    codesign --verify --strict --deep dist/Terminal.app

# Build a Developer ID signed application, ZIP and PKG installer
[group('release')]
package: release-build
    xcrun swift tools/Distribution.swift package

# Sign, notarize, staple and validate both the application and PKG installer
[group('release')]
release: release-build
    xcrun swift tools/Distribution.swift release

# Verify local Developer ID identities and notarization credentials
[group('release')]
release-status:
    xcrun swift tools/Distribution.swift status

[private]
@_native-smoke mode:
    #!/usr/bin/env bash
    set -euo pipefail
    REPORT="$PWD/reports/native-smoke.json"
    LIMIT=80
    if [[ "$1" == idle ]]; then REPORT="$PWD/reports/native-idle.json"; LIMIT=360; fi
    ARGS=(--self-test "$REPORT")
    if [[ "$1" == editing ]]; then
      REPORT="$PWD/reports/editing-smoke.json"
      ARGS=(--editing-smoke "$REPORT")
    fi
    if [[ "$1" == glyph ]]; then
      REPORT="$PWD/reports/glyph-smoke.json"
      LIMIT=220
      ARGS=(--glyph-smoke "$REPORT" --columns 100 --rows 36 --font-size 14)
    fi
    if [[ "$1" == idle ]]; then ARGS+=(--idle-test); fi
    mkdir -p reports
    rm -f "$REPORT"
    open -n "$PWD/dist/Terminal.app" --args "${ARGS[@]}"
    for ((attempt=0; attempt<LIMIT; attempt++)); do
      if [[ -f "$REPORT" ]] && ! pgrep -f "^$PWD/dist/Terminal.app/Contents/MacOS/Terminal ${ARGS[0]} $REPORT" >/dev/null; then
        ruby -rjson -e 'r=JSON.parse(File.read(ARGV[0])); abort("Native smoke failed: #{r.fetch("checks", r.fetch("failures", []))}") unless r.fetch("passed"); puts "PASS #{ARGV[1]} smoke and app termination"' "$REPORT" "$1"
        exit 0
      fi
      sleep 0.25
    done
    echo "Native smoke timed out; inspect $REPORT and the app process." >&2
    exit 1
