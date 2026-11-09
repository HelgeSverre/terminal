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

# Compile and self-test the isolated real-workload pane-stress helpers. This
# preparation recipe deliberately performs no GUI actions.
[group('check')]
tui-stress-prepare:
    ruby tools/tui_stress/run.rb --prepare

# Run one isolated real Files or Codex stress pass against the installed app.
# The runner resolves matching local notarized provenance and copies the app to
# a fresh /tmp report before launch; it never uses a live window.
[group('check')]
tui-stress workload="files":
    ruby tools/tui_stress/run.rb --installed --workload "$1"

# Build then capture one untouched public-fixture README image from a copied app.
[group('check')]
gallery-overview: build
    ruby tools/gallery/run.rb overview

[group('check')]
gallery-panes: build
    ruby tools/gallery/run.rb panes

# Close the last window; require both the app and its HUP-resistant child to exit
[group('check')]
close-smoke: build
    ruby tools/close_smoke.rb

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

# Build and install a whole-module-optimized copy in ~/Applications/Helge Terminal.app
[group('build')]
install: release-build
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

# Format hand-written Swift; generated Unicode tables retain reproducible bytes.
[group('check')]
fmt:
    ruby -e 'files=Dir.glob("{native,tools}/**/*.swift").reject { |f| File.foreach(f).first.to_s.start_with?("// Generated") }; exec("xcrun", "swift-format", "format", "--in-place", *files)'

# Verify graph completeness and syntax without imposing a mass-format migration.
[group('check')]
lint:
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    ruby -e 'Dir.glob("{native,tools}/**/*.swift").sort.each { |f| abort("Swift syntax failed: #{f}") unless system("xcrun", "swiftc", "-frontend", "-parse", f) }'
    ruby -e 'Dir.glob("tools/**/*.rb").sort.each { |f| abort("Ruby syntax failed: #{f}") unless system("ruby", "-c", f, out: File::NULL) }'

# Run the complete Swift native transport/session/bridge test suite.
[group('check')]
@test: lint build
    just workflow-tests
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
    just osc52-protocol
    xcrun clang -Wall -Wextra -Werror -I native -c native/tests/pty.c -o target/native/swift-pty-tests.o
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print pty) target/native/swift-pty-tests.o target/native/Spawn.o -framework Foundation -framework CoreGraphics -framework ImageIO -framework CoreFoundation -framework Security -liconv -o target/native/pty-tests
    target/native/pty-tests "$PWD/dist/Terminal.app/Contents/MacOS/TerminalLauncher"
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print transport) -o target/native/transport-tests
    target/native/transport-tests
    just _session-test
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print geometry) -o target/native/geometry-tests
    target/native/geometry-tests
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print statistics) -o target/native/statistics-tests
    target/native/statistics-tests
    just _glyph-rendering-tests
    xcrun swiftc $(xcrun swift tools/SwiftIncrementalBuild.swift --print preferences) -framework AppKit -o target/native/preferences-tests
    target/native/preferences-tests
    xcrun swiftc -D SNAPSHOT_ABI_DIAGNOSTICS -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print snapshot_bridge) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/snapshot-bridge-tests
    target/native/snapshot-bridge-tests
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print keymap) -framework AppKit -framework CoreText -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/keymap-tests
    target/native/keymap-tests

# Compile and exercise Session against the assembled development bundle.
# Kept separate so CI can diagnose its PTY contract without duplicating commands.
[group('check')]
session-test: build _session-test

[private]
_session-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print session) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/session-tests
    target/native/session-tests "$PWD"

# Exercise a clean interactive zsh through Session's PTY, with macOS-style
# missing locale variables. This is separate from the broader Session suite so
# Unicode prompt and completion redraw failures have a short, focused signal.
[group('check')]
shell-editing-test: build _shell-editing-test

[private]
_shell-editing-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print shell_editing) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/shell-editing-tests
    env -u LANG -u LC_ALL -u LC_CTYPE -u NO_COLOR -u CLICOLOR -u CLICOLOR_FORCE -u FORCE_COLOR target/native/shell-editing-tests "$PWD"

# Swift terminal-state smoke; historical Rust oracles live in the archived branch.
[group('check')]
emulator-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print emulator) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/emulator-tests
    target/native/emulator-tests

# Immutable search pages, cancellation, adjacency and revision proofs.
[group('check')]
history-search-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print history_search) -framework Foundation -o target/native/history-search-tests
    target/native/history-search-tests

# Public graphics protocol, resource lifetime and document-anchor regressions.
[group('check')]
terminal-graphics-oracle:
    mkdir -p target/native
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_graphics_oracle) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-graphics-oracle-tests
    target/native/terminal-graphics-oracle-tests

# Direct OSC palette grammar and reset semantics, independent of the parser.
[group('check')]
terminal-palette:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_palette) -framework Foundation -o target/native/terminal-palette-tests
    target/native/terminal-palette-tests

[group('check')]
window-stress-motion-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print window_stress_motion) -framework AppKit -framework Foundation -framework CoreGraphics -o target/native/window-stress-motion-tests
    target/native/window-stress-motion-tests

[group('check')]
metal-upload-probe:
    mkdir -p target/native
    xcrun swiftc -parse-as-library $(xcrun swift tools/SwiftIncrementalBuild.swift --print metal_upload_probe) -framework Metal -o target/native/metal-upload-probe
    target/native/metal-upload-probe

# Headless residency/worker checks; run after build for the production Metal library.
[group('check')]
glyph-rendering-tests: build _glyph-rendering-tests

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
unicode18-corpus:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print unicode18_corpus) -framework Foundation -o target/native/unicode18-corpus
    target/native/unicode18-corpus "$PWD" --strict

[group('check')]
unicode-decoder:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print unicode_decoder) -framework Foundation -o target/native/unicode-decoder-tests
    target/native/unicode-decoder-tests

[group('check')]
input-encoder:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print input_encoder) -framework Foundation -o target/native/input-encoder-tests
    target/native/input-encoder-tests

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

# Verify owner-validated selection, captured copy and mutation handling.
[group('check')]
terminal-selection:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminal_selection) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminal-selection-tests
    target/native/terminal-selection-tests

# Verify owner validation of the text presented by link gestures.
[group('check')]
terminal-presented-content:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print presented_content) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/presented-content-tests
    target/native/presented-content-tests

# Verify plain/OSC 8 links, cell/UTF-16 mapping and stale accessibility actions.
[group('check')]
visible-links-test:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O $(xcrun swift tools/SwiftIncrementalBuild.swift --print visible_links) -framework Foundation -framework AppKit -framework CoreText -o target/native/visible-links-tests
    target/native/visible-links-tests

# Exercise the real native app, PTY, IME, split panes and Metal, then quit it
[group('check')]
smoke: build (_native-smoke "normal")

# Reproduce native cd/autosuggestion/Backspace editing against the actual ZLE buffer
[group('check')]
editing-smoke: build (_native-smoke "editing")

# Nested pane promotion, minimum-size subdivision, and attached view geometry.
[group('check')]
pane-lifecycle-smoke: build (_native-smoke "pane-lifecycle")

# Measure a visible pane at idle for 60 seconds, then quit the test instance
[group('check')]
idle: build (_native-smoke "idle")

# Full local gate, including the GUI smoke
[group('check')]
check: test smoke pane-lifecycle-smoke startup-grid-smoke

# Check requested startup grids before the first canvas layout, with owned fixtures.
[group('check')]
startup-grid-smoke: build
    ruby tools/startup_grid_smoke.rb dist/Terminal.app reports/startup-grid.json

# Compare the optimized app with Ghostty in both launch orders; preserve raw samples.
[group('bench')]
@benchmark-ghostty output="reports/ghostty-comparison": release-build
    ruby tools/compare_ghostty.rb "$1"

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
    TERMINFO="$PWD/dist/Terminal.app/Contents/Resources/terminfo" /usr/bin/tput -T helge-terminal colors | grep -qx 256
    codesign --verify --strict --deep dist/Terminal.app

# Build a Developer ID signed application, ZIP and PKG installer
[group('release')]
package: release-build
    just _distribution package

# Sign, notarize, staple and validate both the application and PKG installer
[group('release')]
release: release-build
    just _distribution release

# Verify local Developer ID identities and notarization credentials
[group('release')]
release-status:
    just _distribution status

[private]
@_native-smoke mode:
    ruby tools/native_smoke.rb "$1"

[group('check')]
atlas-smoke: build (_native-smoke "atlas")

[group('check')]
atlas-budget-smoke: build (_native-smoke "atlas-budget")

[group('check')]
automation-smoke: build
    ruby tools/applescript_smoke.rb

[group('check')]
automation-consent: build
    TERMINAL_AUTOMATION_REQUEST_CONSENT=1 TERMINAL_AUTOMATION_PREFLIGHT_ONLY=1 ruby tools/applescript_smoke.rb

[group('check')]
accessibility-smoke: build
    ruby tools/accessibility_smoke.rb

# Exercise real owned AppKit mouse gestures and private-pasteboard copying.
[group('check')]
selection-smoke: build
    ruby tools/selection_smoke.rb

[group('check')]
resize-smoke: build
    #!/usr/bin/env ruby
    require 'json'
    require File.join(Dir.pwd, 'tools/native_smoke')
    report_path = File.join(Dir.pwd, 'reports', 'resize-smoke.json')
    File.delete(report_path) if File.exist?(report_path)
    app = File.join(Dir.pwd, 'dist/Terminal.app/Contents/MacOS/Terminal')
    process = NativeSmokeProcess.new([app, '--resize-smoke', report_path, out: File::NULL, err: File::NULL])
    begin
      status = process.wait(90)
      raise 'Resize smoke timed out' unless status
      raise "Resize smoke exited with #{status}" unless status.success?
      raise "Resize smoke left children: #{process.live_pids.join(', ')}" unless process.live_pids.empty?
      report = JSON.parse(File.read(report_path))
      abort "Resize smoke failed: #{report}" unless report.fetch('passed')
      puts JSON.pretty_generate(report)
    ensure
      remaining = process.cleanup
      raise "Resize smoke processes survived cleanup: #{remaining.join(', ')}" unless remaining.empty?
    end

[group('bench')]
@benchmark-apps rust_app swift_app output="reports/app-comparison":
    ruby tools/compare_terminal_apps.rb "$3" "$1" "$2"

[group('bench')]
@stress-cat app file output:
    ruby tools/cat_stress.rb "$1" "$2" "$3"

[group('bench')]
@stress-cat-motion app file output:
    ruby tools/cat_stress.rb "$1" "$2" "$3" motion

[group('check')]
@compare-swift-rows baseline candidate output:
    ruby tools/compare_swift_rows.rb "$1" "$2" "$3"

[group('bench')]
@profile-app app output workload="all":
    ruby tools/profile_terminal.rb "$1" "$2" "$3"

[private]
@_distribution operation:
    mkdir -p target/native
    xcrun swiftc -parse-as-library tools/Distribution.swift -o target/native/distribute
    target/native/distribute "$1"

# Headless tooling regression tests; no app launch or GPU required.
[group('check')]
workflow-tests:
    mkdir -p target/native
    ruby tools/release_signing_test.rb
    ruby tools/release_publisher_test.rb
    ruby tools/tui_stress/run.rb --self-test
    ruby tools/tui_stress/fixture.rb --self-test
    ruby tools/tui_stress/FixtureTests.rb
    ruby tools/tui_stress/provider.rb --self-test
    xcrun swiftc -parse-as-library -O tools/tui_stress/Driver.swift -o target/native/tui-stress-driver-tests
    target/native/tui-stress-driver-tests --self-test
    ruby tools/glyph_policy_test.rb
    ruby tools/native_smoke_test.rb
    ruby tools/compare_terminal_apps_test.rb
    ruby tools/profile_terminal_test.rb
    ruby tools/close_smoke_test.rb
    ruby tools/applescript_smoke_test.rb
    xcrun clang -Wall -Wextra -Werror -O2 native/benchmarks/terminal-bench-clock-test.c -o target/native/terminal-bench-clock-test
    target/native/terminal-bench-clock-test
    xcrun swiftc -D DISTRIBUTION_TESTING -parse-as-library tools/Distribution.swift tools/DistributionTests.swift -o target/native/distribution-tests
    target/native/distribution-tests
    mkdir -p target/native/automation-dictionary
    xcrun sdp -fs -o target/native/automation-dictionary native/Terminal.sdef

[group('check')]
terminfo-test: build _terminfo-test

[private]
_terminfo-test: _terminfo-probe
    ruby tools/terminfo_smoke.rb

[private]
_terminfo-probe:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify >&2
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print terminfo_probe) -framework Foundation -framework CoreGraphics -framework ImageIO -o target/native/terminfo-probe

# Replay stdin through the real Swift emulator and write JSON; replies go to stderr.
[group('check')]
@replay columns="80" rows="24": _terminfo-probe
    target/native/terminfo-probe "$1" "$2"

[group('check')]
clipboard-access-test: build _clipboard-access-tests

[private]
_clipboard-access-tests:
    mkdir -p target/native
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print clipboard_access) target/native/Spawn.o -framework AppKit -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/clipboard-access-tests
    target/native/clipboard-access-tests "$PWD"

# Rebuild once, then require a true no-op without launching the executable.
[group('check')]
swift-build-test:
    xcrun swift tools/SwiftIncrementalBuild.swift --verify
    xcrun swift tools/SwiftIncrementalBuild.swift --clean
    output="$(xcrun swift tools/SwiftIncrementalBuild.swift)"; [[ "$output" == "Swift incremental no-op;"* ]]
