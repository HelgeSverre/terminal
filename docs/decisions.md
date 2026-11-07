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

## Rust core and AppKit host

Helge subsequently confirmed keeping Rust for now. A versioned C bridge confines
opaque terminal handles to a serial owner; Swift receives owned immutable values.
Cells cross a typed, row-major C callback buffer with length-delimited text/links,
packed symbolic colors and style flags. Small cursor/mode/palette/image metadata
still uses JSON. Swift copies the borrowed views on the owner before the callback
returns; no Rust row pointer escapes its lifetime. The original full JSON API
remains for headless tools and exact equivalence tests. Retained row handles and
revision-based row reuse remain future optimizations. The terminal core builds
and tests without AppKit or Metal.

Each session currently has a serial Dispatch queue combining PTY readiness and
terminal mutation. Dispatch sources use the native kernel readiness mechanism;
no dedicated OS thread is created per session. This preserves single ownership
but does not yet implement the original shared-reactor/owner-lane separation.
Each pane currently owns a Metal layer/render queue; a window-level compositor
and shared glyph service remain a planned consolidation.

## Unicode and resource identity

Width uses pinned unicode-width 0.2.3 (Unicode 18). Segmentation is vendored at
upstream commit 4444c95cf31f3bae48aa98b9f96b66332a8836fd, whose generated tables
are Unicode 18. Upstream generator, licenses, and table source are retained.
Tests assert both Unicode versions. Cells are 16 bytes with inline scalar text;
only multi-scalar clusters use row-local resource storage. Row resource IDs are
scoped to their immutable resource maps, so snapshot copies cannot alias a later
reused local ID.

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
