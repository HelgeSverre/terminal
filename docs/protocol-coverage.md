# Terminal protocol coverage

Current source coverage was reconciled on 2026-11-17. This updates the earlier
audit starting at `3ad91fe`; its dated validation record below remains
historical. Tests named in the current tables are regressions under
`Tests/TerminalTests`; [gap implementation status](gap-implementation-status.md)
records the revisions the full gate passed at. Kitty graphics, SIXEL and iTerm2 images do not
claim complete conformance. See the [gap inventory](gap-inventory.md),
[implementation plan](gap-implementation-plan.md) and [qualification matrix](qualification.md).

## Graphics

| Feature | Implementation and evidence | Limits or remaining work |
| --- | --- | --- |
| Kitty RGB, RGBA, PNG, indexed `f=8/16`; zlib; chunks | `KittyGraphicsStore.consume`, bounded transport/decode; `TerminalGraphicsOracleTests` and `GraphicsGapTests.indexedSamplesFollowPaletteAndDefaultColors` | Indexed samples follow palette/default-color changes; indexed animation edits are rejected. 16 MiB per decoded image, 64 MiB live store, 64 images, 256 placements, 4096 pixels per side |
| File, temporary-file, shared-memory transport; image numbers | `KittyTransport`, extension transport/number tests; `GraphicsGapTests` covers shared-memory offset/unlink, blocked-reader cancellation and timeout | Host transport yields asynchronously with bounded completion/cancellation; the C/headless path retains synchronous transport. Broader filesystem/PTY integration remains separate |
| Placement, crop, offset, layering, cursor movement | `layout`, `visible`, `applyReflow`, `scrollRectangle`; graphics gap tests cover ordinary/relative/placeholder reflow, clipping, line feed and deferred-wrap scroll | Mapping and wide-cell anchor regressions exist; broader live-client and session-to-Metal conformance remains unqualified |
| Unicode placeholders | `KittyPlaceholder`, `placeholderSlice`; extension tests verify slices, color IDs and unmarked continuation; real Neovim/Snacks images and splits checked directly and through tmux | Unpatched upstream Snacks needs `SNACKS_KITTY=true`; with the repository's pinned detection patch no override is needed (direct path verified, tmux/SSH not). No exhaustive Metal pixel oracle |
| Relative placements | `origin`, `pruneOrphans`; extension tests cover ordinary and virtual parents, movement, scrollback, screen changes, deletion, cycles and depth | Maximum depth 8; virtual parents cache at most 256 extrema pairs (512 row IDs plus a tail), scan appended history and the live grid, and rebuild on eviction/reflow/prototype changes |
| Animation frames and playback | `addFrame`, `control`, `playback`; extension tests cover frames, composition, loops, loading, gap edits and frame deletion | Up to 1000 frames within shared storage budget; broader UI scheduling coverage remains separate |
| Image/placement deletion | `delete`, `deleteFrame`; extension selectors, resolved relative origins, root promotion, resource accounting and oracle cross-screen/cache tests | Positional deletion leaves virtual prototypes intact; manipulate their placeholder text instead |
| Queries and quiet replies | `consume`, `featureReply`, `outcome`; action-specific non-default keys, ignored payload and pending-upload preservation tests | Advertises implemented formats/actions only, not full protocol conformance |
| SIXEL | `SixelDecoder`, DCS parser; `TerminalImageTests` plus `GraphicsGapTests.sixelBackgroundAspectPaletteAndDisplayModes` | Bounded decode now handles background/transparent holes, aspect scaling, persistent palette registers, DECSDM 80 and mode 8452; wider client/pixel compatibility still needs qualification |
| iTerm2 inline images | `InlineImageDecoder`, `showInlineImage`; original sizing tests plus graphics gap multipart atomicity/cancellation, clock-driven GIF frames, ReportCellSize and capability replies; `GraphicsRenderedGapTests` | Bounded inline and multipart display; a file sent without `inline=1` is offered as a bounded download that needs an explicit Save and a chosen destination. Broader animation/stretch/alpha client behavior remains a validation gate |
| Shared image lifetime and rendering | `KittyGraphicsStore.show`, immutable image generations, session `ImageKey` cache and renderer textures | Engine/ABI checks exist; session-to-Metal pixel correctness for animation, crop, alpha and z order remains unverified |

## Input and other terminal protocols

| Feature | Coverage | Limits |
| --- | --- | --- |
| Kitty keyboard | All five flags, set/query/push/pop and independent main/alternate stacks; `TerminalInputEncoderTests`, `EmulatorTests` | Host key metadata/IME edge cases are not exhaustive |
| xterm modifyOtherKeys | Levels 1/2, dispatch/query/reset, keyboard-protocol precedence; `TerminalInputCompatibilityTests` | Physical layout/Option/dead-key behavior and current interactive client combinations require native evidence |
| Mouse, focus, paste | X10, 1000/1002/1003, UTF-8 1005, SGR 1006, urxvt 1015 and pixel-SGR 1016; focus 1004 and paste 2004; shared `TerminalMouseEncoder`, compatibility/encoder tests | Mode 1001 remains unsupported; pixel coordinates depend on native presentation geometry and require client validation |
| Synchronized output 2026 | `TerminalSchedulerOracleTests.synchronizedOutputUsesABIClockDeadline` and session scheduling | A bounded timeout is intentional |
| OSC 8 hyperlinks | URI and bounded `id` storage; cell payload, headless screen, reflow and activation proofs preserve anchor identity; visible-link tests | Other unrecognized parameters are ignored; client/browser interaction still needs current-tip evidence |
| OSC 52 clipboard | Strict bounded streaming decoder; `OSC52ProtocolTests`; application permission/cache tests | Selection `c` writes only; reads deliberately return empty; see [clipboard policy](osc52-clipboard.md) |
| OSC 133 shell markers | A/B/C/D state, command exit metadata and prompt clearing; `TerminalPromptClearOracleTests`, `ShellIntegrationTests`; bundled zsh/Bash/fish hooks | Arbitrary shell configurations, prompt frameworks and remote hooks are not certified by protocol state tests |
| Discovery/status/colors/titles | Host-supplied XTVERSION, bounded XTGETTCAP/DECRQSS, DECDSR reports for absent hardware, DECID, OSC 10/11/12 and attribute colors, scheme 996/2031, geometry queries and title stacks (titles are never reported back); `TerminalProtocolDiscoveryTests` | Replies advertise selected implemented capabilities; child window movement/resizing remains excluded |
| VT cursor, erase, rectangles and saved state | `TerminalVTSemanticsTests`, `EmulatorTests`, [esctest baseline](conformance.md) | 460 esctest cases pass and are protected; the 66 remaining failures are dispositioned in [conformance](conformance.md) |
| Underline, blink and fractional presentation | `UnderlineGeometry`, `TerminalBlinkPresentation`, viewport geometry; `PresentationTests` includes geometry/clock and Metal pixel oracles | Authored pixel oracles are distinct from a completed real-GPU/compositor/native-input qualification |
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
| G3 | `a=d,d=f/F` acknowledges without deleting any frame | Fixed: root promotion, frame renumbering, stable image-number ordering, playback state, storage release and last-frame semantics; extension regressions |
| G4 | Relative child of a virtual placement has no resolved origin | Fixed: derive independent minimum coordinates from actual placeholder text, including scrollback and active-screen changes; bounded cached origins and snapshot regressions |
| G5 | Coordinate deletion checks a relative placement's stored cursor anchor rather than its resolved parent origin | Fixed: rendering and deletion share origin resolution; all positional selectors tested, including text movement without an intervening snapshot |
| G6 | Feature query replies echo `I` and use one key list for all actions | Fixed: action-specific supported non-default keys; ignored payload, unsupported actions and in-progress upload preservation covered |
| G7 | `Animation.firstGap=0` passes through the generic 40 ms default, so the root frame is displayed instead of initially gapless | Fixed: gapless root default, explicit root-gap edits, ignored zero-gap updates and bounded playback preserving elapsed time/completed loops |
| G8 | The tested `kitten icat` renders blank at baseline: its 128 KiB chunks, unpadded base64 and repeated action on continuations exceed older transport assumptions | Bounded compatibility with the examined client framing; canonical decoding and total decoded-image limits retained |

G3–G8 were repaired in the 2026-11-17 follow-up. G8 was found in real-client testing;
the [Kitty client examined in that run](https://github.com/kovidgoyal/kitty/blob/master/tools/tui/graphics/command.go)
uses 128 KiB chunks and unpadded base64. The parser envelope is limited to
128 KiB plus 4 KiB of header space. Relative graphics may perform indexed
history lookups for bounded parent IDs; viewport FollowTail still avoids its
own retained-history anchor resolution. The G1–G8 dispositions and validation
below describe that earlier repair batch. New source coverage is listed in the
current tables above; complete VT or graphics conformance remains unclaimed.

The [2026-11-17 real-client report](../reports/kitty-real-world-2026-11-17/README.md)
records that run's tests, frozen app identity, visible PNG/GIF/placeholder results
and native checks. Its recorded integration caveats: Snacks needs its terminal
allowlist override; interactive `icat --hold` under default tmux ignored exit
keys even though its image rendered. That historical failure's cause is not
isolated. A truthful Helge discovery fixture passed a current-client rerun on
the frozen `306a592` app (direct path); upstream Snacks acceptance and the
tmux and SSH variants remain external gates.

## Earlier state and ownership review

| Machine and owner | Transition and invariant | Evidence or disposition |
| --- | --- | --- |
| Chunk upload, `KittyGraphicsStore` | Idle → collecting → committed; malformed/cancel/timeout drops pending work. Completed query must not store or move cursor | Oracle atomic chunks, upload lifecycle and detection tests; retained |
| Frames, `KittyGraphicsStore` | Stopped/loading/running; compose validates before assigning pixels and generation; playback snapshots retain the selected generation | G1/G3/G7 repairs; extension playback/deletion tests |
| Placements, `KittyGraphicsStore` | Anchored/virtual/relative; removal prunes descendants; screen and row identity govern visibility | Hierarchy/screen tests; G4/G5 repairs and large-history validation |
| SIXEL command, `SixelDecoder` | No command → repeat/raster/color → draw; each command owns bounded numeric state; CAN/SUB discards the decoder | G2 repair and image tests |
| Inline image, `InlineImageDecoder` | Header → bounded payload → decode/admit, or failed; cancellation discards all partial work | Image tests; retained |
| Parser/input/clipboard | Owner-serialized negotiation and framing; independent keyboard screen stacks, bounded clipboard payload | Input/OSC52/scheduler tests; retained |
| Session snapshots/Metal textures | Retain resources by image ID plus immutable generation until consumers release them | Source inspection and engine tests; pixel integration test deferred |

## Earlier module decisions

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

## Historical validation and review

Baseline `3ad91fe`, clean main checkout; work performed in a detached scratch
worktree. Swift 6.2.4, arm64 macOS 15.6 (24G84), repository development bundle plus optimized
Swift Testing with test hooks. One heavy job at a time.

- Baseline `just test` at `3ad91fe`: passed (117 developer, 357 terminal,
  13 glyph tests, plus tooling/terminfo/PTY checks). Development executable
  SHA-256 `41a265d2fdf75f10809f900d22328e4acd289ec47641954efa205264476e59e2`.
- G1/G2 red run: updated tests against unchanged baseline implementation failed
  in three cases with 11 assertions (composition offsets/rejection and SIXEL
  command isolation). Green at `814f7b8`: `just unit-test --filter
  KittyGraphicsExtensionTests --filter TerminalImageTests --filter
  TerminalGraphicsOracleTests`, 39 tests in 3 suites passed.
- Private cleanup at `95c8aba`: the same 39 focused tests passed again.
- Final `just test` at `95c8aba`: passed (117 developer, 359 terminal and
  13 glyph tests, plus tooling/terminfo/PTY checks). `just verify` passed.
  `swift build --package-path Examples/Embedding` built both example hosts.
  Development app executable SHA-256:
  `36e15619c80c6a7e9146c5b4db02432c4b040989e43a5ead46443ca0226ecd04`.
  Optimized `TerminalPackageTests.xctest/Contents/MacOS/TerminalPackageTests` SHA-256:
  `bf5f8a9ec31f371cdfb6036e9d2ec35251e43e9bbb1acdff78cff8af80eb64e8`.
- `just esctest` at `95c8aba`: known-good gate passed at pinned `2798f12`;
  320 passed, 206 failed, 41 known deviations, 0 skipped of 567 cases. This
  preserves the documented conformance baseline; it is not a full conformance pass.
- Review: three read-only Discover reviewers covered graphics/SIXEL state,
  adjacent protocols/consumers, and report retention/renderer integration.
  Sweep A Challenge and Verify passed for `814f7b8` with rotated behavior,
  consumer and evidence lenses. The baseline missing-frame EINVAL was also
  confirmed by the red run (distinct from a missing-image ENOENT).
  Sweep B Discover retained the store/transport/decoder/snapshot/cache owners
  and selected only unused private inputs/state for removal. Three rotated
  Challenge and Verify reviewers passed that delta (source patch SHA-256
  `e3d3c6b177f763800c2daf767c7bd210e9f329c4751cea9d49fa81290677be1c`, committed
  as `95c8aba`); no substantive code changes followed. Report retention and
  archive links were reviewed; no tracked report was a test fixture.
- Locally verified. CI, GUI graphics pixel checks, iOS and sanitizer fuzzing
  are not part of this local verification. Final audit bookkeeping changes
  only Markdown; source/test/build inputs remain those of `95c8aba`.

Raw local logs are ignored; retain final commands, source revisions and artifact
identity here instead of adding another report directory to Git.
