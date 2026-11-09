# Implementation status

The goal remains active. This is a working development milestone, not v1 completion.

Implemented and locally exercised:

- Native macOS 15 AppKit bundle, precompiled Metal shaders, ad-hoc signing, Run action.
- Swift-owned rows with stable identities, direct immutable snapshots, indexed
  history, symbolic styles and bounded history retention.
- Streaming VT/UTF-8, bounded CSI/OSC and constant-memory unsupported string discard.
- Deferred wrap, wide repair, SGR, cursor/margins, erase/insert/delete/scroll/tab/REP,
  DEC save/restore, normal/alternate screens, reset, replies, title/links/palette.
- Unicode 18 grapheme/width tables, incremental cluster extension, occupancy repair.
- Native Command–K with prompt-aware redraw, primary history/image cleanup and
  alternate-screen protection; bundled OSC 133 zsh prompt hooks preserve user
  startup files and autosuggestion bindings. Five focused core cases and the
  actual native Command–K path pass.
- Primary reflow and alternate crop/pad; inactive primary and saved cursors resize.
- Owner-confined primary viewport anchored by document/row identity, stable under
  new output, remapped through reflow, clamped on eviction, and retained while
  alternate is selected. Snapshots carry document/history/screen identity and
  the resolved viewport; focus reports and key releases do not follow the tail.
  Reset/history clear/screen or geometry changes invalidate frozen host selections;
  destructive screen/geometry changes cancel preedit without committing it.
- Bounded worker-based literal search over immutable rows with Unicode scalar
  lowercase matching, soft-wrap joining, cell decorations, query limits,
  latest-query cancellation, close cancellation and source-revision validation.
  The whole-transcript native search path has been removed.
- PTY launcher/status handshake, native readiness, ordered owner input/replies,
  partial writes, exit drain/reap, close escalation, write pressure limits.
- Metal glyph atlas/instanced quads, demand-only rendering, Retina metrics.
  Atlas pages grow lazily. Pressure uses bounded direct glyph textures, then a
  visible replacement after the exact-glyph budget is exhausted; oversized
  glyphs bypass atlas allocation. Global glyph residency accounting and the
  process-wide glyph budget are enforced across renderers.
- Explicitly redrawable OSC 133 prompts retain their row/column/pending-wrap
  boundary. Width reflow clears only the marked prompt suffix before the shell
  redraws, preserving earlier output; unmarked prompts and inactive primary
  contents remain intact. Command–K rebases the prompt boundary.
  Screen-local prompt phase distinguishes drawing (A) from input readiness (B),
  while preserving existing prompt-region semantics. Both snapshot paths expose
  the derived readiness value; missing legacy metadata remains unknown.
- AppKit text-input callbacks, selection/copy, paste, mouse/focus, local history,
  basic literal search, windows/tabs/nested splits and font size controls.
- Minimal pane-only content with Obel Mono; geometric block and common box glyphs.
- App icon, bundle identity `no.helgesverre.terminal`, Developer ID signing,
  notarized/stapled app and PKG distribution artifacts, private GitHub repository
  and a passing macOS CI test run. The matching notarized Swift app is installed
  in the user's personal Applications folder.
- Graphite/yellow visual style drawn from Helge's Trace/Splash/Glue/Shepherd
  projects, with backing-scale-aware 8-point insets, native dark window chrome,
  and a separate settings window with inline validation. Two visual rounds
  checked the actual windows and cancelled test input without saving preferences.
- Bounded Kitty direct RGB/RGBA/PNG graphics, zlib, chunks, placement/cropping,
  alpha/layers, query replies, generation-checked binary pixel bridge and Metal textures.
  Files/shared memory, image numbers, relative/Unicode placements and protocol
  animation are not supported. Primary width reflow clears placements; image
  anchor remapping and complete deletion/scroll-region semantics remain work.
- Direct immutable Swift snapshots carry screen, history, viewport and image
  state without the former binary-cell bridge; indexed history/anchor lookups
  keep retained-snapshot and viewport work inside the document owner.
- Bounded visible accessibility projection with UTF-16↔cluster/cell maps,
  line/range/selection lookup, screen-coordinate geometry and local selection
  changes. Attributed text reports fonts, colors, underlines, strikethrough and
  actionable hyperlink elements; style lookup uses an indexed run map. Direct
  arbitrary text replacement through AX is not exposed. In-process tests and an
  external AX client cover attributed-string serialization and UTF-16 queries;
  real VoiceOver validation remains separate.
- Plain http/https/mailto URLs and OSC 8 hyperlinks share one visible-link
  projection. Cmd-hover underlines the target, Cmd-click opens it, and AX link
  children support semantic agent clicks. Actual Hanimex serve/Vite browser
  navigation and clean fixture shutdown pass; see
  `reports/visible-links-evidence/summary.md` for scope and timing limits.
- DECLRMM/DECSLRM, per-screen horizontal margins, origin-aware coordinates/replies,
  regional wrap/tab/CR/BS, rectangular scrolling and insert/delete with wide-edge
  repair and no partial-width history. Partial-width image scrolling currently
  clears placements while retaining image resources.
- Numeric/application keypad modes with localized decimal text, distinct keypad
  Enter, enhanced press/repeat/release encoding, delivered-key identity tracking
  across releases, and focus-loss cleanup. A 64 KiB control reserve inside the
  existing 2 MiB ingress cap admits owned releases under ordinary-input pressure.
- Bundled Obel Mono faces and Symbols Nerd Font Mono fallback, numeric font-size
  input with Up/Down and stepper controls. Exhaustive glyph inspection covers
  10,624 printable Nerd characters in four styles; real PTY/Metal runs cover 44 pages.
- Native AppleScript dictionary with stable pane identifiers, bounded screen reads,
  input, splits/windows/tabs and validated preference changes. The disposable
  automation fixture verifies targeting while Settings is active and child cleanup.
- Policy-controlled OSC 52 text clipboard writes through a native Allow/Deny
  sheet, bounded requests and a one-second prompt cooldown. Reads return an empty
  denial reply without consulting the pasteboard. Late decisions after close/EOF
  cannot write, and denial suppresses subsequent prompts for that session.
  Base64 decoding streams with constant carry, fallible output growth, decoded
  and encoded caps, strict padding checks and bounded parser callback spans.
  A full outstanding-request queue discards payloads without allocating decoded data.
- Kitty keyboard logical/shifted/base-layout and associated-text metadata,
  modifier-only events in all-keys mode, and legacy Shift/Option compatibility.
  Modifier presses preserve selections and anchored history. Typed events account
  for all retained strings and reject impossible write bounds before admission.
- Final-window closure quits the app and reaps PTY children; closed sessions
  silently reject late focus/key releases. PTY EOF closes input admission while
  leaving the final screen and history searchable.
- Project-owned terminfo source and compiled bundle database, with exact `tput`
  expansion checks and real parser replay. The entry omits unrendered blink and
  unsupported private extensions; the shell keeps the documented
  `xterm-256color` fallback for remote compatibility. DEC Special Graphics now
  maps the entire 32-character set, including scan lines and control pictures.

Current automated evidence:

- Final Swift runtime validation is green in macOS CI run `42535806699` at
  `5cfe701`. The earlier `0587616` source has a 501-second local full-suite pass;
  the runtime-34 input changes have focused Encoder/KeyMap coverage and eight
  native fixtures. The final Emulator assertion correction changes tests only.
- `reports/runtime34-evidence/summary.md`: both 16 MiB × ten-run visible-app
  orders pass every standard workload. Swift/Rust throughput ratios range from
  86.8797% to 92.2243%; both apps exit naturally with no survivors. These are
  alternate-screen parser/barrier measurements, not display latency.
- `reports/sql-full-34bd618-evidence/summary.md`: the paired 8.16 GB primary
  SQL stress run completes and drains in both implementations, but Swift is
  47.093159 MiB/s versus Rust's 69.319794 MiB/s (67.9361%). This remains below
  the 70% target and is not hidden by the standard-workload result.
- `reports/build-comparison-0587616/summary.md`: one immutable, warm-cache,
  complete-app build pair measured Rust `just build` at 29.470697 seconds and
  Swift `just release-build` at 32.433977 seconds. The recipes intentionally
  do different work, so this is provenance rather than a language-only or
  statistical compile-speed comparison.
- `reports/runtime34-evidence/summary.md` retains eight passing owned native
  fixtures, including Kitty demo coverage after muting macOS output; all record
  natural exit and empty cleanup.
- Native clipboard tests use private named pasteboards for allow/deny, queued
  cancellation, stale/closed callbacks, prompt bounds and a real PTY read-denial
  exchange. An explicit child handshake makes the pending-request EOF case
  deterministic, and the fixture waits for every child to be reaped.
- The signed AppleScript fixture passes the complete dictionary, including
  inactive/settings targeting and an exact 4 KiB input receipt. It exits normally
  and reaps all five PTY children. Six headless fault tests cover command timeout,
  fixture locking, cleanup/report failures and UTF-8-safe evidence output.
- Native smoke sets a real Canvas accessibility selection and injects synthetic
  AppKit Shift/Command events in legacy and Kitty all-keys modes. Separate real
  Session/PTY tests verify anchored history, legacy shifted bytes, typed metadata
  admission and write bounds. These are not hardware keyboard-layout tests.
- Startup automation waits for the OSC 133 B marker rather than prompt drawing
  or a fixed startup delay. A private-ZDOTDIR real Zsh fixture uses a nonblocking
  FIFO handshake to hold A, then release B and verify exact executed output.
  Editing smoke also waits for the visible prompt before recording its cursor.
- `reports/native-smoke.json`: actual macOS 15.6 text input, PTY, Unicode/SGR,
  marked-text callback commit, guarded preedit cancellation on resize/focus,
  resize, split and Metal submission checks. Session tests exercise native
  scroll/focus/release/typing event ordering through the typed view snapshot ABI.
- Independent captured-frame resize comparison found an incorrect retained-frame
  anchor with raw layer gravity. The development build now sets AppKit's native
  top-left placement policy. Across the controlled nested-split/window-resize
  sequence, all detected markers in 536 captured candidate frames stayed 60×60;
  the scaling control distorted 61 of 536 frames. The report records scope and
  provenance in `docs/rendering-second-review.md`; this is separate from shell
  prompt-redraw correctness. The strengthened follow-up covers actual divider
  dragging and window live resize: 658 correct candidate frames, zero failures,
  and two explicitly inconclusive frames; the scaling control has 113 failures.
  All three final pane generations were presented and captured. See
  `docs/rendering-proof-followup.md` for source/binary identity and capture limits.
- `reports/atlas-budget-smoke.json`: a zero exact-fallback budget exercises visible
  replacement glyphs without omitted glyph quads or Metal command errors. The
  test waits for the target pane revision's GPU completion; it does not capture
  compositor pixels. Replacement counts include repeated uses across frames.
- `reports/metal-shell.png`: observed local native shell window.
- `reports/dmscene-kitty-hakkuh.json`: real native player, 640×400 Kitty image,
  controls, resize, successful child exit and no Metal command errors.
- `reports/dmscene-kitty-auto.json`: auto-detected Kitty mode with image placements.
- `reports/dmscene-kitty-960.json`: explicit 960×600 direct image frames with
  controls/resize/exit and zero Metal errors. The older forced-size auto Anjuna
  setup is marked failed and superseded, since it fell back to text.
- `reports/dmscene-kitty-960-binary.json` repeats the high-resolution image test
  after the typed bridge and accessibility implementation; all checks pass.
- Earlier three-app pilots in `reports/comparison-002` and
  `reports/comparison-003` are retained as historical parser evidence, not as
  claims about the frozen Swift runtime.

Required work remaining before the requested completion gate:

- Broaden startup stability testing. One earlier combined-build native smoke
  timed out at its first command and an unchanged rerun passed. The former A/B
  readiness ambiguity is now removed and the controlled handshake plus native
  smoke pass; the original timeout's exact cause remains unproven. Its failed
  count-only report remains in the worktree-cleanup artifact archive.
- Broaden rapid nested-resize validation. The marked prompt-boundary fix passes
  focused prefix/wrap/eviction/alternate-screen regressions and the controlled
  Starship/ZLE fixture. The latter uses a fixture-owned WINCH redraw hook; broader
  natural shell redraw behavior and live mouse resize still need coverage.
  The native placement correction passes the strengthened per-pane compositor
  fixture; broader display/scale and arbitrary shell cases remain separate gates.
- Resolve the host's Downloads authorization stall for Launch Services launches:
  a read/discard probe blocks in `open` without a visible permission alert, despite
  a valid ad-hoc signature and Downloads usage description. Direct launch from
  the authorized coding session completes the real dump tests. No broad disk
  permission was changed; `reports/downloads-access-probe.json` records this limit.
- Full command/capability audit and hardware keyboard/layout validation.
  The bundled custom terminfo is available;
  switching the default identity still needs local/remote compatibility evidence.
- Resumable reflow work quanta and fallible temporary-memory allowances. REP now yields in bounded quanta; actor/input ordering during REP is tested.
- Broader selection/search navigation, live-edit and fractional pixel-scrolling
  validation. Indexed history and stable viewport anchors are implemented, but
  selection still holds a bounded host snapshot rather than owner-validated,
  eviction-aware endpoints. Multi-display and long-lived interaction coverage
  remains incomplete.
- Shared reactor/owner lanes, complete end-to-end admission accounting, global
  memory budgets and broader queue-race tests. Transactional paste cancellation
  with bracket closure is implemented and tested at every partial-write offset.
- Row/run shaping caches, asynchronous raster service, ligatures, complete
  geometric glyph coverage, GPU recovery testing and broader resource-retirement
  stress.
- Accessibility history fetching and real VoiceOver
  validation, real CJK input methods and dead keys/layout/Option-policy testing,
  composition routing during focus/resize.
- Broader configuration validation and lifecycle/configuration tests. Persisted font size/history/Option settings are implemented.
- Sustained idle/GPU/startup/latency/memory measurements and complete application
  interaction corpus, multi-display/sleep/scale and resource-retirement stress.
- Performance: the runtime-34 standard visible-app gate passes in both orders,
  but the paired full-SQL workload is 67.9361% of Rust and remains below the
  70% target. Measurements must guide further changes.
- Clean-machine installation, update/rollback and broader signed-distribution
  lifecycle tests. Final app/PKG notarization, stapling and trust validation
  pass; development builds remain distinct from those distribution artifacts.

The signed `0.2.0`/build `5` runtime milestone is frozen at source `34bd618`.
Its app and PKG were accepted by Apple's notary service, stapled and passed
trust validation. The final runtime's close fixtures exit and reap their owned
PTY children. `reports/distribution-0.2.0.json` records the independent signature,
stapling, Gatekeeper and signed-app shutdown checks. After the user closed their
old sessions, installation completed and every regular file was verified against
the notarized source. Separate signed native and editing smoke tests pass; an
earlier inactive/key-window failure is retained with its cause unresolved.

The Vulkan-specific requirements have been superseded by the authorized Metal
platform decision; the terminal behavior and native quality gates remain the goal.

Latest native evidence: Obel Mono is the configured font. `session-tests.json`
checks input admission before a mode suffix behind a 500k REP, framed paste,
oversize rejection, and saturation/cancel/close. `native-idle.json` records a
60-second idle test on an M2 Max: zero submissions, ~0.013% of one CPU core,
~42 MiB physical footprint for one visible pane. The specification names an
M2-class MacBook with 32 GiB RAM; this Max-class result is not an equivalent
reference configuration. `native-smoke.json` includes actual pane/layer geometry and
Metal command times; `quit-smoke.json` also verified the process exits.
