# Implementation status

The goal remains active. This is a working development milestone, not v1 completion.

Implemented and locally exercised:

- Native macOS 15 AppKit bundle, precompiled Metal shaders, ad-hoc signing, Run action.
- 16-byte cells, copy-on-write physical rows, symbolic styles, bounded history.
- Streaming VT/UTF-8, bounded CSI/OSC and constant-memory unsupported string discard.
- Deferred wrap, wide repair, SGR, cursor/margins, erase/insert/delete/scroll/tab/REP,
  DEC save/restore, normal/alternate screens, reset, replies, title/links/palette.
- Unicode 18 grapheme/width tables, incremental cluster extension, occupancy repair.
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
- AppKit text-input callbacks, selection/copy, paste, mouse/focus, local history,
  basic literal search, windows/tabs/nested splits and font size controls.
- Minimal pane-only content with Obel Mono; geometric block and common box glyphs.
- App icon, bundle identity `no.helgesverre.terminal`, Developer ID signing,
  notarized/stapled app and PKG, transactional personal Applications installation,
  private GitHub repository and a passing macOS CI test run.
- Graphite/yellow visual style drawn from Helge's Trace/Splash/Glue/Shepherd
  projects, with backing-scale-aware 8-point insets, native dark window chrome,
  and a separate settings window with inline validation. Two visual rounds
  checked the actual windows and cancelled test input without saving preferences.
- Bounded Kitty direct RGB/RGBA/PNG graphics, zlib, chunks, placement/cropping,
  alpha/layers, query replies, generation-checked binary pixel bridge and Metal textures.
  Files/shared memory, image numbers, relative/Unicode placements and protocol
  animation are not supported. Primary width reflow clears placements; image
  anchor remapping and complete deletion/scroll-region semantics remain work.
- Typed binary cell snapshot bridge with small JSON metadata and binary image
  bytes; exact old/new bridge equivalence and copy lifetime tests pass.
- Bounded visible accessibility projection with UTF-16↔cluster/cell maps,
  line/range/selection lookup, screen-coordinate geometry and local selection
  changes. Direct arbitrary text replacement through AX is not exposed.
- DECLRMM/DECSLRM, per-screen horizontal margins, origin-aware coordinates/replies,
  regional wrap/tab/CR/BS, rectangular scrolling and insert/delete with wide-edge
  repair and no partial-width history. Partial-width image scrolling currently
  clears placements while retaining image resources.
- Numeric/application keypad modes with localized decimal text, distinct keypad
  Enter, enhanced press/repeat/release encoding, delivered-key identity tracking
  across releases, and focus-loss cleanup. A 64 KiB control reserve inside the
  existing 2 MiB ingress cap admits owned releases under ordinary-input pressure.

Current automated evidence:

- `just test`: 41 core semantic/property-style fixtures, 9 margin fixtures,
  3 keypad fixtures, 7 viewport fixtures, 7 search fixtures, 13 graphics fixtures,
  and the full official Unicode 18 break suite; strict Clippy;
  native build; ten real PTY scenarios including bash/fish/Neovim/tmux/fzf output
  replayed through the core with invariant checks and ordered protocol replies.
- `reports/native-smoke.json`: actual macOS 15.6 text input, PTY, Unicode/SGR,
  marked-text callback commit, guarded preedit cancellation on resize/focus,
  resize, split and Metal submission checks. Session tests exercise native
  scroll/focus/release/typing event ordering through the typed view snapshot ABI.
- `reports/core-benchmark.json`: actual five-run release headless throughput and
  one 10k-row resize measurement, including parser finish and final snapshot.
- `reports/metal-shell.png`: observed local native shell window.
- `reports/dmscene-kitty-hakkuh.json`: real native player, 640×400 Kitty image,
  controls, resize, successful child exit and no Metal command errors.
- `reports/dmscene-kitty-auto.json`: auto-detected Kitty mode with image placements.
- `reports/dmscene-kitty-960.json`: explicit 960×600 direct image frames with
  controls/resize/exit and zero Metal errors. The older forced-size auto Anjuna
  setup is marked failed and superseded, since it fell back to text.
- `reports/dmscene-kitty-960-binary.json` repeats the high-resolution image test
  after the typed bridge and accessibility implementation; all checks pass.
- `reports/sql-cat-stress.json`: actual 8,162,501,113-byte SQL file through `/bin/cat`:
  312.19 seconds, 25.00 MiB/s PTY stream throughput, 95.3 MiB peak sampled physical
  footprint, bounded 64 MiB history, two live resizes, all output drained and parsed,
  exit 0, zero Metal errors. Main heartbeat p95 5.05 ms, maximum 5.87 ms; ordered
  owner probe p95 18.22 ms, maximum 131.67 ms. No SQL contents saved in report.
- After the typed bridge, `reports/sql-cat-stress-binary.json` repeats the same
  full file in 113.51 seconds at 68.77 MiB/s wire throughput, with 112.5 MiB
  peak sampled footprint, zero Metal errors, bounded history, both resizes and
  complete drain/parse/exit. Main heartbeat p95 4.38 ms, max 5.05 ms; ordered
  owner probes p95 0.72 ms, max 125.98 ms (including resize).
- `just benchmark`: identical PTY payloads plus ordered DSR drain in isolated
  app configurations; separates parser throughput from display-latency claims.
  `reports/comparison-002` records the initial three-app pilot. After the typed
  cell bridge, `reports/comparison-003` records ~2.5× improvement here, with fresh
  reference runs; both reference apps still lead all four throughput workloads.

Required work remaining before the requested completion gate:

- Resolve the host's Downloads authorization stall for Launch Services launches:
  a read/discard probe blocks in `open` without a visible permission alert, despite
  a valid ad-hoc signature and Downloads usage description. Direct launch from
  the authorized coding session completes the real dump tests. No broad disk
  permission was changed; `reports/downloads-access-probe.json` records this limit.
- Full command/capability audit, complete kitty alternate/base-layout/modifier
  metadata and modifier-only events, plus custom terminfo.
- Resumable reflow work quanta and fallible temporary-memory allowances. REP now yields in bounded quanta; actor/input ordering during REP is tested.
- Complete typed epoch/anchor lifetimes and owner-confined, eviction-aware selection;
  richer search navigation/options and broader live-edit validation coverage.
  The primary viewport now uses stable anchors, but fractional pixel scrolling,
  unseen-output accounting and indexed anchor lookup remain work. Selected content
  is still held in one bounded host snapshot rather than owner-validated endpoints.
- Shared reactor/owner lanes, complete end-to-end admission accounting, global
  memory budgets and broader queue-race tests. Transactional paste cancellation
  with bracket closure is implemented and tested at every partial-write offset.
- Retained row snapshot ABI/revision reuse, row/run shaping caches, asynchronous raster service,
  ligatures, complete geometric glyph coverage, atlas pressure fallbacks, GPU recovery testing.
- Additional accessibility history fetching/style attributes and real VoiceOver
  validation, real CJK input methods and dead keys/layout/Option-policy testing,
  composition routing during focus/resize.
- Broader configuration validation and lifecycle/configuration tests. Persisted font size/history/Option settings are implemented.
- Sustained idle/GPU/startup/latency/memory measurements and complete application
  interaction corpus, multi-display/sleep/scale and resource-retirement stress.
- Performance targets: current ASCII/mixed replay and reflow measurements do not
  meet all original acceptance targets. Measurements must guide further changes.
- Clean-machine installation and broader signed-distribution lifecycle tests.
  Local Developer ID signing and app/PKG notarization now pass; development
  builds remain distinct from those distribution artifacts.

The Vulkan-specific requirements have been superseded by the authorized Metal
platform decision; the terminal behavior and native quality gates remain the goal.

Latest native evidence: Obel Mono is the configured font. `session-tests.json`
checks input admission before a mode suffix behind a 500k REP, framed paste,
oversize rejection, and saturation/cancel/close. `native-idle.json` records a
60-second idle test on an M2 Max: zero submissions, ~0.013% of one CPU core,
~42 MiB physical footprint for one visible pane. This is not the original M1 Pro
reference machine. `native-smoke.json` includes actual pane/layer geometry and
Metal command times; `quit-smoke.json` also verified the process exits.
