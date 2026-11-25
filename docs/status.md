# Implementation status

Current release line: **v0.6.4** (with post-release engineering improvements on
`main`). Terminal is a working development milestone, not v1 completion.
Historical 0.2.x/0.3.x milestones, Rust-to-Swift cutover measurements, and the
2026-11 gap ledgers are preserved in [docs/archive/](archive/README.md).

## Current capabilities

- **Emulation and protocols**: Streaming VT/UTF-8 parser with Unicode 18
  grapheme/width tables, primary reflow with resumable bounded resize
  transactions, alternate screen, DECLRMM/DECSLRM horizontal margins, DEC
  Special Graphics, and bounded CSI/OSC/DCS handling. Implements truthful
  host-supplied identity, XTVERSION/XTGETTCAP/DECRQSS replies, dynamic colors,
  color-scheme notifications, geometry queries, title filtering/stacks (titles
  are never reported back to programs), OSC 8 hyperlinks with surviving anchor
  IDs, OSC 52 clipboard writes (reads denied), and OSC 133 shell prompt
  integration for zsh, bash, and fish. See [protocol coverage](protocol-coverage.md)
  and [terminfo](terminfo.md).
- **Conformance and fuzzing**: `esctest2` passes **461 of 567** cases (65
  reported failures, 41 known xterm deviations) with a known-good regression
  gate in CI alongside a two-minute Address Sanitizer fuzzer. See
  [conformance](conformance.md).
- **Graphics**: Kitty graphics (RGB/RGBA/PNG, zlib, chunking, file/shared-memory
  transport, indexed palettes, placements, cropping, Unicode placeholders,
  relative placements, reflow/rectangular-scroll mapping, animation), SIXEL
  (background, aspect, palette, display modes), and iTerm2 inline images
  (multipart, animation, cell-size/capability reporting) sharing the image store
  and Metal textures. OSC 1337 file transfers require explicit Save/Dismiss
  confirmation.
- **Rendering and presentation**: AppKit windows and Metal renderer with
  CoreText glyph rasterization, bundled Obel Mono + Symbols Nerd Font Mono
  fallback, lazy atlas growth with a process-wide glyph budget, distinct
  underline geometries, cursor/text blink with occluded wakeups suppressed,
  fractional scrolling, and top-left native resize placement.
- **Input, selection, search, and accessibility**: Native AppKit IME/preedit,
  Kitty keyboard protocol, modifyOtherKeys, mouse encodings (SGR, pixel-SGR,
  UTF-8, urxvt), owner-confined character/word/line/rectangular selection,
  bounded worker-based search (case-sensitive, whole-word, and finite-state
  regex; see [search](search.md)), visible-link Cmd-hover/Cmd-click and AX
  activation, and bounded accessibility projection.
- **Desktop controls and automation**: Windows, native tabs, nested splits,
  pane headers/colors/inactive dimming, validated shell profiles, configurable
  shortcuts and per-side Option policy, theme/font/cursor controls, directional
  pane actions/zoom/move, and AppleScript automation. See [usage](usage.md),
  [desktop controls](desktop-controls.md), and [automation](automation.md).
- **Recovery and handoff**: Unclean-exit layout and bounded literal scrollback
  recovery with explicit Resume confirmation (`RecoveryCoordinator`); normal
  quit clears recovery state. Experimental [session handoff](session-handoff.md)
  (off by default) allows relaunching or updating while pane programs keep
  running.
- **Embedding**: Separate Swift package targets (`TerminalEngine`,
  `TerminalHost`, `TerminalUI`) usable by external macOS and UIKit hosts; see
  [embedding](embedding.md).

## Recent improvements (post-v0.6.4)

- **Swift 6 & embedding hygiene**: Strict library-boundary enforcement across
  the three library targets, CI verification of Swift 6 consumer embedding
  (`just embedding-check`) and WMO release bundles (`just release-build`), and
  UIKit touch selection and lazy accessibility fixes.
- **Performance and memory compaction**: Packed snapshot cell colors/kinds,
  reused Metal renderer buffers, byte-oriented OSC buffering, and
  `KERN_PROCARGS2` process-argument sampling for recovery instead of shelling
  out.
- **Architecture and conformance**: Split `TerminalEmulator` and
  `TerminalSession` into focused files, extracted `RecoveryCoordinator`, added
  `DECRQSS` `DECSNLS`/`DECSLPP` support (bringing esctest to 461 passes), and
  added a real Metal Kitty pixel oracle test (`GraphicsRenderedGapTests`).

## CI and virtual-GPU policy

Hosted macOS CI runs three required jobs on every push to `main`:

1. **Headless tests** (`just test`, bundle verification, `just embedding-check`,
   and `just release-build`) using `TERMINAL_CI_GPU_POLICY=paravirtual` for the
   hosted runner's virtual GPU.
2. **Protocol conformance** (`just esctest` against the 461-case known-good
   gate).
3. **Sanitizer fuzzing** (`just fuzz 120` with Address Sanitizer and
   exclusivity checks).

See [qualification](qualification.md) for how hosted paravirtual CI separates
from hardware GPU and distribution qualification.

## Remaining validation and external gates

Source implementation and local headless/smoke tests do not substitute for
external hardware, user-interaction, and release-environment checks. The main
open gates are:

- **Real input and accessibility**: Physical CJK input methods, dead keys,
  international keyboard layouts, per-side Option behavior, and live VoiceOver
  testing (see [input and accessibility validation](native-input-accessibility-validation.md)).
- **Natural client and graphics corpus**: Broad live testing with natural
  shells, tmux, and real Kitty/SIXEL/iTerm2 clients (including upstream Snacks
  allowlist support), plus real-device UIKit embedding checks.
- **Hardware lifecycle and sustained performance**: Multi-display/sleep/scale
  transitions, GPU recovery, sustained idle/memory/throughput profiling on
  reference hardware, and closing the remaining throughput/footprint gaps
  documented in [benchmarking](benchmarking.md).
- **Recovery and handoff in the wild**: Power-loss/hard-reset recovery,
  real-agent resume flows, and observing a released build complete a live
  Sparkle update with session handoff enabled.
- **Clean-machine distribution and CI timing**: Clean-machine ZIP install and
  cross-version/interrupted update testing, Downloads authorization behavior
  under Launch Services, and repeated cold/warm hosted CI timing baselines
  (see [qualification](qualification.md)).

## Historical provenance

Older milestones, cutover comparisons, and point-in-time audits are kept in
[docs/archive/](archive/README.md), including the
[Swift cutover ledger](archive/swift-cutover.md),
[gap inventory](archive/gap-inventory.md),
[gap implementation status](archive/gap-implementation-status.md), and
[rendering proof reviews](archive/rendering-second-review.md).
