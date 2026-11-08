# Native macOS terminal. Run `just` to see common workflows.
set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments
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

# Force a tiny glyph atlas through the real PTY/grid/Metal path; no glyph may vanish.
[group('check')]
atlas-smoke: build (_native-smoke "atlas")

# Exhaust the exact-fallback budget and require a visible substitute, never a blank glyph.
[group('check')]
atlas-budget-smoke: build (_native-smoke "atlas-budget")

# Exercise the AppleScript dictionary against a disposable bundle and raw cat PTY.
[group('check')]
automation-smoke: build
    ruby tools/applescript_smoke.rb

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

# Build the Rust core, native host, Metal shaders and signed development bundle
[group('build')]
@build: icons
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT_DIR="$TERMINAL_PROJECT_ROOT"
    BUILD_DIR="$ROOT_DIR/target/native"
    APP_BUNDLE="$ROOT_DIR/dist/Terminal.app"
    mkdir -p "$BUILD_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
    cargo build --release --locked -p terminal-core
    xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 native/Launcher.c -o "$APP_BUNDLE/Contents/MacOS/TerminalLauncher"
    xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 -c native/Spawn.c -o "$BUILD_DIR/Spawn.o"
    xcrun -sdk macosx metal -c native/Terminal.metal -o "$BUILD_DIR/Terminal.air"
    xcrun -sdk macosx metallib "$BUILD_DIR/Terminal.air" -o "$APP_BUNDLE/Contents/Resources/Terminal.metallib"
    xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 -import-objc-header native/Bridge.h native/Statistics.swift native/Geometry.swift native/Font.swift native/FontCatalog.swift native/Preferences.swift native/Transport.swift native/Session.swift native/ClipboardAccess.swift native/SnapshotBridge.swift native/AccessibilityProjection.swift native/Theme.swift native/Settings.swift native/Renderer.swift native/KeyMap.swift native/Canvas.swift native/Automation.swift native/Smoke.swift native/EditingSmoke.swift native/main.swift "$BUILD_DIR/Spawn.o" target/release/libterminal_core.a -framework AppKit -framework QuartzCore -framework Metal -framework CoreText -o "$APP_BUNDLE/Contents/MacOS/Terminal"
    cp native/Info.plist "$APP_BUNDLE/Contents/Info.plist"
    cp native/Terminal.sdef "$APP_BUNDLE/Contents/Resources/Terminal.sdef"
    /usr/bin/tic -x -o "$APP_BUNDLE/Contents/Resources/terminfo" native/Terminal.terminfo
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

# Build and install a copy in ~/Applications/Helge Terminal.app
[group('build')]
install: build
    just _distribution install

# Remove only this app's installed bundle; preserve settings and project output
[group('build')]
uninstall:
    just _distribution uninstall

# Build and replace the installed copy, keeping the previous copy if build fails
[group('build')]
reinstall: install

# Open the installed app
[group('build')]
@open:
    open "$HOME/Applications/Helge Terminal.app"

# Format Rust sources
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
@test: lint build
    ruby tools/native_smoke_test.rb
    xcrun swiftc -D DISTRIBUTION_TESTING -parse-as-library tools/Distribution.swift tools/DistributionTests.swift -o target/native/distribution-tests
    target/native/distribution-tests
    mkdir -p target/native/automation-dictionary
    xcrun sdp -fs -o target/native/automation-dictionary native/Terminal.sdef
    ruby tools/terminfo_smoke.rb
    dist/Terminal.app/Contents/MacOS/Terminal --font-catalog "$PWD/reports/font-glyphs.txt"
    cargo test --locked --workspace
    xcrun clang -Wall -Wextra -Werror -I native native/tests/pty.c native/Spawn.c target/release/libterminal_core.a -framework CoreFoundation -framework Security -liconv -o target/native/pty-tests
    target/native/pty-tests "$PWD/dist/Terminal.app/Contents/MacOS/TerminalLauncher"
    xcrun swiftc native/Transport.swift native/tests/TransportTests.swift -o target/native/transport-tests
    target/native/transport-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h native/Preferences.swift native/Transport.swift native/Session.swift native/SnapshotBridge.swift native/AccessibilityProjection.swift native/tests/SessionTests.swift target/native/Spawn.o target/release/libterminal_core.a -framework Foundation -framework CoreFoundation -framework Security -liconv -o target/native/session-tests
    target/native/session-tests "$PWD"
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h native/Preferences.swift native/Transport.swift native/Session.swift native/ClipboardAccess.swift native/SnapshotBridge.swift native/AccessibilityProjection.swift native/tests/ClipboardAccessTests.swift target/native/Spawn.o target/release/libterminal_core.a -framework AppKit -framework Foundation -framework CoreFoundation -framework Security -liconv -o target/native/clipboard-access-tests
    target/native/clipboard-access-tests "$PWD"
    xcrun swiftc native/Geometry.swift native/tests/GeometryTests.swift -o target/native/geometry-tests
    target/native/geometry-tests
    xcrun swiftc native/Statistics.swift native/tests/StatisticsTests.swift -o target/native/statistics-tests
    target/native/statistics-tests
    xcrun swiftc native/Preferences.swift native/tests/PreferencesTests.swift -o target/native/preferences-tests
    target/native/preferences-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h native/Preferences.swift native/Transport.swift native/Session.swift native/SnapshotBridge.swift native/AccessibilityProjection.swift native/tests/SnapshotBridgeTests.swift target/native/Spawn.o target/release/libterminal_core.a -framework Foundation -framework CoreFoundation -framework Security -liconv -o target/native/snapshot-bridge-tests
    target/native/snapshot-bridge-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h native/Preferences.swift native/KeyMap.swift native/tests/KeyMapTests.swift target/release/libterminal_core.a -framework AppKit -framework CoreText -framework Security -liconv -o target/native/keymap-tests
    target/native/keymap-tests

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
    /usr/bin/infocmp -x -A dist/Terminal.app/Contents/Resources/terminfo helge-terminal >/dev/null
    codesign --verify --strict --deep dist/Terminal.app

# Build a Developer ID signed application, ZIP and PKG installer
[group('release')]
package: build
    just _distribution package

# Sign, notarize, staple and validate both the application and PKG installer
[group('release')]
release: build
    just _distribution release

# Verify local Developer ID identities and notarization credentials
[group('release')]
release-status:
    just _distribution status

[private]
@_distribution operation:
    mkdir -p target/native
    xcrun swiftc -parse-as-library tools/Distribution.swift -o target/native/distribute
    target/native/distribute "$1"

[private]
@_native-smoke mode:
    ruby tools/native_smoke.rb "$1"
