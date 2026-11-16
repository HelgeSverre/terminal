# Terminal protocol coverage

Audit of the Swift implementation on 2026-11-16, starting at `3ad91fe`.
Kitty graphics, SIXEL and iTerm2 images work, but none is a claim of complete
conformance. This is the current coverage inventory; older comparison reports
describe their recorded revisions. Tests named below are under `Tests/TerminalTests`.

## Graphics

| Feature | Implementation and evidence | Limits or remaining work |
| --- | --- | --- |
| Kitty RGB, RGBA, PNG; zlib; chunks | `KittyGraphicsStore.consume`, bounded transport/decode; `TerminalGraphicsOracleTests` (PNG/zlib, chunk partitions, malformed atomicity, expiry) | No indexed `f=8/16`; 16 MiB per decoded image, 64 MiB live store, 64 images, 256 placements, 4096 pixels per side |
| File, temporary-file, shared-memory transport; image numbers | `KittyTransport`, `KittyGraphicsExtensionTests.filesAndTemporaryFilesAreRead`, `.imageNumbersNameTheNewestImage` | Shared-memory success has no dedicated regression; transport executes synchronously on the session owner |
| Placement, crop, offset, layering, cursor movement | `layout`, `visible`; oracle cursor/resize/screen tests and extension deletion tests | Primary width reflow clears placements; scroll-region/clipped-anchor deletion semantics need broader conformance cases |
| Unicode placeholders | `KittyPlaceholder`, `placeholderSlice`; two extension tests verify slices, color IDs and unmarked continuation | No end-to-end tmux/Neovim or Metal pixel oracle |
| Relative placements | `origin`, `pruneOrphans`; extension tests cover following/moving/deleting parents, cycles and depth | Maximum depth 8; a virtual placeholder parent is accepted but its child never renders (G4) |
| Animation frames and playback | `addFrame`, `control`, `playback`; extension tests cover frames, composition, loops, loading and gaps | Up to 1000 frames within shared storage budget; frame deletion is a no-op (G3); default root gap differs (G7); loop edits and UI scheduling need more coverage |
| Image/placement deletion | `delete`; extension selectors and oracle cross-screen/cache tests | `f/F` is not implemented; positional selectors do not resolve relative origins (G5) |
| Queries and quiet replies | `consume`, `featureReply`, `outcome`; oracle query and extension feature tests | Feature replies are not yet action-specific and echo some default/identity keys (G6) |
| SIXEL | `SixelDecoder`, DCS parser; `TerminalImageTests` covers RGB/HLS, repeat, raster size, scrolling, cropping to limits and DA1 advertisement | Transparent background only; header/raster aspect ratios, P2 background, DECSDM 80 and mode 8452 unsupported; palette resets per image |
| iTerm2 inline images | `InlineImageDecoder`, `showInlineImage`; `TerminalImageTests` covers BEL/ST, aspect ratio, cells/pixels/percent/auto sizing and large images | Original `OSC 1337;File=...;inline=1` only; first frame only; no multipart, downloads, ReportCellSize or feature reporting |
| Shared image lifetime and rendering | `KittyGraphicsStore.show`, immutable image generations, session `ImageKey` cache and renderer textures | Engine/ABI checks exist; session-to-Metal pixel correctness for animation, crop, alpha and z order remains unverified |

## Input and other terminal protocols

| Feature | Coverage | Limits |
| --- | --- | --- |
| Kitty keyboard | All five flags, set/query/push/pop and independent main/alternate stacks; `TerminalInputEncoderTests`, `EmulatorTests` | Host key metadata/IME edge cases are not exhaustive |
| Mouse, focus, paste | X10, 1000/1002/1003 and SGR 1006; focus 1004 and bracketed paste 2004; encoder and mode tests | No 1001/1005/1015/1016; UI mouse encoding lacks a direct regression |
| Synchronized output 2026 | `TerminalSchedulerOracleTests.synchronizedOutputUsesABIClockDeadline` and session scheduling | A bounded timeout is intentional |
| OSC 8 hyperlinks | URI storage and visible-link projection tests | OSC parameters, including `id`, are discarded |
| OSC 52 clipboard | Strict bounded streaming decoder; `OSC52ProtocolTests`; application permission/cache tests | Selection `c` writes only; reads deliberately return empty; see [clipboard policy](osc52-clipboard.md) |
| OSC 133 shell markers | A/B/C/D state and prompt clearing; `TerminalPromptClearOracleTests` | Shell-integration behavior beyond those markers is not implied |
| Device attributes, status, modes and window size | `EmulatorTests.deviceReplies`, terminfo tests, [esctest baseline](conformance.md) | DECRQSS, XTGETTCAP, rectangular operations and many window/mode operations remain absent |
| String framing | APC/OSC/DCS cancellation, termination and discard paths; graphics partition and OSC52 tests | Raw eight-bit C1 controls are intentionally excluded by `docs/spec.md` |

Primary specifications: [Kitty graphics](https://sw.kovidgoyal.net/kitty/graphics-protocol/),
[Kitty keyboard](https://sw.kovidgoyal.net/kitty/keyboard-protocol/),
[DEC SIXEL](https://vt100.net/docs/vt3xx-gp/chapter14.html),
[iTerm2 images](https://iterm2.com/documentation-images.html), and
[xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html).
Capability statements above come from this repository's implementation and tests.

## Correctness issues and disposition

| ID | Behavior at baseline | Disposition and acceptance |
| --- | --- | --- |
| G1 | Kitty `a=c` uses lowercase source offsets and uppercase destination offsets; same-frame overlap succeeds; missing frames return EINVAL | Fixed in `814f7b8`: wire offsets, full-image defaults, overlap and error validation before mutation; red/green regressions pass |
| G2 | SIXEL semicolons grow an unbounded parameter array; digits outside a command leak into the next repeat | Fixed in `814f7b8`: five retained fields maximum, command-scoped digits and saturated vertical position; whole/bytewise recovery regressions pass |
| G3 | `a=d,d=f/F` acknowledges without deleting any frame | Deferred feature work: implement root promotion, frame renumbering, playback and resource accounting together; usage no longer claims every selector |
| G4 | Relative child of a virtual placement has no resolved origin | Deferred: supply actual placeholder geometry to the placement owner, with tests through emulator snapshots |
| G5 | Coordinate deletion checks a relative placement's stored cursor anchor rather than its resolved parent origin | Deferred with relative-placement geometry; ordinary selectors are tested, this combination is not |
| G6 | Feature query replies echo `I` and use one key list for all actions | Deferred query-conformance work; queries cannot yet be treated as an exhaustive capability contract |
| G7 | `Animation.firstGap=0` passes through the generic 40 ms default, so the root frame is displayed instead of initially gapless | Deferred animation timing work: distinguish the root default from an added frame's default and test state/loop edits with explicit clocks |

G3–G7 remain observable compatibility limitations, not completed fixes. New
protocol features are outside this repair batch. Runtime scheduling, PTY/renderer
redesign, non-macOS builds and complete VT conformance are outside this audit.

## State and ownership review

| Machine and owner | Transition and invariant | Evidence or disposition |
| --- | --- | --- |
| Chunk upload, `KittyGraphicsStore` | Idle → collecting → committed; malformed/cancel/timeout drops pending work. Completed query must not store or move cursor | Oracle atomic chunks, upload lifecycle and detection tests; retained |
| Frames, `KittyGraphicsStore` | Stopped/loading/running; compose validates before assigning pixels and generation; playback snapshots retain the selected generation | G1 repair; G3 deferred; extension playback tests |
| Placements, `KittyGraphicsStore` | Anchored/virtual/relative; removal prunes descendants; screen and row identity govern visibility | Existing hierarchy/screen tests; G4/G5 deferred |
| SIXEL command, `SixelDecoder` | No command → repeat/raster/color → draw; each command owns bounded numeric state; CAN/SUB discards the decoder | G2 repair and image tests |
| Inline image, `InlineImageDecoder` | Header → bounded payload → decode/admit, or failed; cancellation discards all partial work | Image tests; retained |
| Parser/input/clipboard | Owner-serialized negotiation and framing; independent keyboard screen stacks, bounded clipboard payload | Input/OSC52/scheduler tests; retained |
| Session snapshots/Metal textures | Retain resources by image ID plus immutable generation until consumers release them | Source inspection and engine tests; pixel integration test deferred |

## Module decisions

The graphics store earns its shared ownership: deleting it would distribute
budgets, placement lifetimes and generations across three image decoders and
the parser. Keep it. Keep SIXEL and inline-image decoders separate because their
wire state differs; do not add a generic protocol abstraction. Keep transport
separate from placement state. Parser, input encoder, clipboard decoder, session
cache and renderer retain their existing responsibilities and public interfaces.

The targeted cleanup removes unused private `blend` source-offset inputs and
unused SIXEL overflow/redundant numeric state. Both blend callers supply a
complete source rectangle; the decoder finishes numeric fields before drawing.
These were private baseline interfaces; no public embedding interface changes.

## Validation and review

Baseline `3ad91fe`, clean main checkout; work performed in a detached scratch
worktree. Swift 6.2.4, arm64 macOS, repository development bundle plus optimized
Swift Testing with test hooks. One heavy job at a time.

- Baseline `just test` at `3ad91fe`: passed (117 developer, 357 terminal,
  13 glyph tests, plus tooling/terminfo/PTY checks). Development executable
  SHA-256 `41a265d2fdf75f10809f900d22328e4acd289ec47641954efa205264476e59e2`.
- G1/G2 red run: updated tests against unchanged baseline implementation failed
  in three cases with 11 assertions (composition offsets/rejection and SIXEL
  command isolation). Green at `814f7b8`: `just unit-test --filter
  KittyGraphicsExtensionTests --filter TerminalImageTests --filter
  TerminalGraphicsOracleTests`, 39 tests in 3 suites passed.
- Final `just test`, `just verify`, embedding build: pending.
- Review: three read-only Discover reviewers covered graphics/SIXEL state,
  adjacent protocols/consumers, and report retention/renderer integration.
  Sweep A Challenge and Verify passed for `814f7b8` with rotated behavior,
  consumer and evidence lenses. The baseline missing-frame EINVAL was also
  confirmed by the red run (distinct from a missing-image ENOENT).
  Sweep B Discover retained the store/transport/decoder/snapshot/cache owners
  and selected only unused private inputs/state for removal; Challenge/Verify pending.
- CI, GUI graphics pixel checks, iOS and sanitizer fuzzing are not yet executed.

Raw local logs are ignored; retain final commands, source revisions and artifact
identity here instead of adding another report directory to Git.
