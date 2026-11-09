# Implementation decisions

## macOS 15 and Metal

The original spec selected macOS 26/KosmicKrisp/Vulkan. The implementation host
runs macOS 15.6, Apple Silicon. During implementation Helge explicitly required
that the app work on this Mac and authorized lowering requirements or using an
alternative renderer. The implementation therefore targets macOS 15 and Metal.
The original spec remains preserved in `spec.md` for reference.

This removes the need to bundle Vulkan Loader/ICD libraries, query Vulkan WSI
maintenance extensions, or maintain Vulkan presentation tickets. Metal owns
its drawable/presentation lifecycle. Drawables and instance buffers are retained
by submitted command buffers; shared glyph-atlas mutation currently drains GPU
sampling before writes. That conservative implementation needs further profiling.

## Swift terminal emulator and AppKit host

The initial Rust implementation is preserved at `rust-before-swift-9190820`.
Helge authorized replacing it once the Swift experiment reached 70% of matched
Rust throughput, with 80% as a stretch goal. The final standard-workload pair
reached 86.9–92.2%; the separate full-SQL stress case reached 67.9% and remains
an optimization gap. Swift makes the executable smaller and removes the Rust
toolchain from active development, while the measured full-app build is slightly
slower. See [the cutover record](swift-cutover.md) for exact measurements and limits.

The terminal emulator and document now share one Swift compiler module with the
native host. Session queues retain exclusive mutation ownership; presentation
uses direct immutable snapshots. The versioned C and JSON APIs remain for
compatibility tests and headless tools, rather than the normal rendering path.
`Sources/Terminal/Emulation` owns interpretation, document/history, protocol input, search,
graphics state and snapshots; `Sources/Terminal/Text` owns streaming Unicode processing.

Each session currently has a serial Dispatch queue combining PTY readiness and
terminal mutation. Dispatch sources use the native kernel readiness mechanism;
no dedicated OS thread is created per session. This preserves single ownership
but does not yet implement the original shared-reactor/owner-lane separation.
Each pane owns a Metal layer. A shared rendering service owns glyph residency,
bounded raster work and the process-wide glyph budget; broader rendering and
resource-recovery gates remain open.

## Unicode and resource identity

Width and segmentation retain the pinned Unicode 18 behavior from the Rust
implementation. Neutral inputs, provenance, licenses and Swift generators live
under `tools/unicode`; regeneration requires no Cargo registry or Rust source.
The official 853-case grapheme corpus and targeted width fixtures are mandatory.

Rows retain stable identities and copy-on-write storage; scalar text lives in
inline slots while multi-scalar text and links use sparse row payloads. Swift's
physical slot layout differs from Rust's former 16-byte cell. Historical
retention charges remain a compatibility contract and must not be presented as
the actual allocation size or a complete process-memory budget.

## Launch

`openpty` plus `posix_spawn` starts a small C launcher. Only intended descriptors
survive the first exec. The launcher uses `login_tty`, sets cwd and signal state,
and marks its status descriptor close-on-exec for target exec. Structured stage
and errno failures cross the status pipe. Parent process readiness and PTY EOF
remain independent; waitpid reaping never substitutes for draining output.

## Visual direction

Helge identified the local Trace, Splash, Glue and Shepherd projects as the visual
references. Their shared pattern is graphite surfaces, hairline separators,
compact text, muted secondary labels and sparing signal-yellow accents. Source
references inspected: Splash `app/src/app.css` and committed UI screenshots;
Trace `resources/js/tokens/tokens.css` and screenshots; Glue's TUI theme roles;
Shepherd's design-system tokens, build rules and review-list screenshot.

The terminal adopts Trace/Splash's #0a0a0b ground, #e6e6e6 default text and
#facc15 accent, plus Splash's terminal ANSI palette. The extended 256-color cube
and application-specified truecolor remain unchanged. Cursor/selection/preedit
and split separators use the same quiet visual vocabulary. The grid uses an
8-point inset, resolved to backing pixels once for rendering, hit testing, IME,
accessibility and geometry. Obel Mono remains the terminal font; native controls
use macOS UI typography. Settings use a separate native utility window, explicit
field labels and inline validation. There is no persistent footer or status bar.

## Viewport ownership

The session owner stores FollowTail or a primary document/row anchor. Native
scroll events are relative gestures, and snapshots report the resolved offset;
the canvas does not maintain a competing numeric position. Incoming output
preserves the same top row. Reflow maps its leading boundary during the existing
transaction, and eviction clamps to surviving content with a clamp revision.
Alternate always shows its live grid and retains the primary view for return.
Ordinary input follows the selected screen's tail; focus and release events do
not. Live-tail publication avoids the retained-history anchor lookup entirely.

Document/history/screen epochs cross both snapshot paths. A stale frozen host
selection cannot suppress a new document, screen or geometry. Native composition
cancellation clears marked storage under a reentrancy guard before discarding
the input context's composition; an external unmark callback still commits once.
Viewport anchors are owner-confined, but full owner selection, fractional pixel
scrolling, unseen-output counts and indexed anchor resolution remain pending.

## Native screen clearing and shell integration

Command–K follows Ghostty 1.4's emulator-level clear action: primary history is
removed; at an OSC 133-marked prompt the owner clears the grid and requests a
Ctrl-L redraw; outside a prompt it removes only rows above the cursor. Alternate
screen state is untouched. This preserves a running TUI's coordinate model.
Reference: [Ghostty's implementation](https://github.com/ghostty-org/ghostty/blob/v1.4.0/src/termio/Termio.zig#L605).

The core owns clearing policy, identity changes, viewport/search invalidation and
graphics cleanup. AppKit submits one ordered action. A narrow bundled zsh startup
shim restores the original ZDOTDIR, sources user startup files at top level, then
adds prompt/ZLE hooks. It does not edit dotfiles or replace the prompt. Explicit
noninteractive commands use their existing startup path. Normal interactive
zsh is detected and configured by the spawn module; callers do not construct
integration environment variables. The obsolete spawn convenience entry point
was removed, leaving the argument-aware spawn path as the single interface.
