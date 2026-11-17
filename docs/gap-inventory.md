# App gap inventory — 2026-11-17

Implementation follow-up: [current results and remaining qualification](gap-implementation-status.md).
The dated findings below preserve the original audit baseline.

Audited source: `7573f72` on `main` (application code is unchanged from
`a9aa3e574b3de9daefe8ef864abdae80bb9161e7`). This is an inventory and suggested
order of work, not approval to implement every feature below.

## Scope and confidence

Inspected the engine/parser/document, PTY/session and transport, AppKit/Metal
view, UIKit view, app windows/settings/automation, shell integration, package,
CI/release workflows, tests, recorded runtime evidence and all GitHub issues.
Compared protocol claims with primary specifications and current Snacks source.
This is a source and evidence audit across the app, not an exhaustive bug proof,
fresh hardware qualification, or a penetration test.

Status distinguishes **missing**, **partial**, **observed** (cause unresolved),
**validation** (evidence missing), and **decision** (optional product scope).
**Next** means the highest-value follow-up; **Later** means a real gap with less
immediate evidence of user impact; **Optional** needs a product decision.
These priorities are recommendations, not severity scores or release blockers.

The most useful next work is identification/capability replies, reproducing
the tmux keyboard problem, fixing underline rendering, checking real IMEs and
VoiceOver, and implementing the already-planned crash recovery. Completing
every xterm feature should not precede those user-visible improvements.

## Terminal compatibility

The dispatch evidence for this section is
[`TerminalEmulator.swift`](../Sources/TerminalEngine/Emulation/TerminalEmulator.swift)
(`implementsCSI`, `handleCSI`, `modeReport`, `finishString`) and
[`TerminalPalette.swift`](../Sources/TerminalEngine/Emulation/TerminalPalette.swift).

| ID | Status / order | Gap and consequence | Completion evidence |
| --- | --- | --- | --- |
| C01 | Missing / Next | **XTVERSION (`CSI > q`) has no reply.** `TERM_PROGRAM=HelgeTerminal` and its version are set for children, but the query path rejects `>q`. Programs querying the terminal cannot identify it. DA2's hardcoded VT220 firmware value is not the app version. | Reply with Helge's real identity/version; test query variants, framing, headless/embedding identity policy, direct PTY and tmux/SSH paths. |
| C02 | Missing integration / Next | **Snacks does not recognize Helge by default.** Its current environment table contains no Helge entry. Adding C01 alone does not add that entry. The prior real-client test needed `SNACKS_KITTY=true`. | Test a Helge-specific detection entry and default image startup, then pursue upstream recognition separately. See [Snacks source](https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/lua/snacks/image/terminal.lua) and [runtime report](../reports/kitty-real-world-2026-11-17/README.md). |
| C03 | Missing / Next | **XTGETTCAP and DECRQSS** are absent. Applications cannot query supported terminfo values or current terminal settings through those protocols. | Implement a bounded, truthful subset with supported/unsupported replies and round-trip tests. Keep capability advertisement tied to implementation. |
| C04 | Partial / Later | **Color protocols:** OSC 4/10/11/104 work; OSC 5 special colors and OSC 12 cursor color/query do not. OSC 110/111 resets are explicitly omitted in the palette code. Color parsing accepts `#RRGGBB` and `rgb:` components, not all xterm spellings; chained dynamic-color changes are absent. | Prioritize cursor color/query and practical reset behavior; add real theme-switching cases. Exotic CIE/TekHVC syntax is lower priority. Revisit deliberate reset exclusions explicitly. |
| C05 | Partial / Next triage | **VT semantics beyond missing extensions:** the latest conformance run has failures in margin movement, selective erase, resets and save/restore as well as absent rectangular operations, insert/delete columns and forward/back index. The failures need individual disposition, not a blanket “unsupported extensions” explanation. | Turn high-impact failures into focused regressions; distinguish xterm-specific expectations, intentional policy and actual defects. Counts and examples below. |
| C06 | Partial / Later | **Input compatibility:** Kitty keyboard negotiation exists, but xterm `modifyOtherKeys` is explicitly ignored. Mouse 1001/1005/1015/1016 are absent; supported paths are X10, 1000/1002/1003 and SGR 1006. | Test concrete clients before extending legacy mouse encodings; prioritize keyboard fallback and pixel mouse only where useful. See [input encoder](../Sources/TerminalEngine/Emulation/TerminalInputEncoder.swift). |
| C07 | Partial / Later | **OSC 8 identity:** only the URI survives; parameters including `id` are discarded. Distinct logical links sharing a URI cannot retain their protocol identity. | Preserve identity through cells, wrapping/reflow and hover projection; test adjacent same-URI/different-ID links. |
| C08 | Missing / Optional | **Theme reporting/notifications:** no `CSI ? 996 n` color-scheme report or mode 2031 change notifications. Read-only window reports are also limited to 14/16/18/19; title queries and title-stack behavior are absent. Window-changing commands remain intentionally excluded. | Decide which read-only queries clients need; implement truthful replies without enabling child-controlled window movement/resizing. |

References: [xterm's maintained control-sequence text](https://github.com/ThomasDickey/xterm-snapshots/blob/master/ctlseqs.txt)
and the repository's [protocol coverage](protocol-coverage.md). Not every xterm
extension is a requirement for Helge Terminal.

### What the green conformance check means

Downloaded `conformance-results` from
[CI run 44069317138](https://github.com/HelgeSverre/terminal/actions/runs/44069317138),
which tested `a9aa3e5`: **320 passed, 206 failed, 41 marked known xterm
deviations, 0 skipped, 567 total; no regressions or newly passing cases.**
The check protects the 320-case known-good set. It does not assert full
conformance. The 41 known deviations are separate from the 206 failures.

Grouped from that artifact's actual `failing` list:

| Failure family | Cases |
| --- | ---: |
| Backspace, tab-backward and horizontal cursor movement | 12 |
| Palette/dynamic/special color changes and resets | 38 |
| Rectangular operations, insert/delete columns, forward/back index | 44 |
| DA/DA2/DECID, DEC status/mode/settings queries | 48 |
| DEC modes, conformance level, soft/hard resets | 21 |
| Selective erase and other erase operations | 13 |
| FF/IND/LF/NEL/REP/RI/VT | 7 |
| Cursor save/restore | 4 |
| Window operations | 19 |
| **Total** | **206** |

Examples worth triaging: `CUBTests.test_CUB_StopsAtLeftMarginInScrollRegion`,
`CUFTests.test_CUF_StopsAtRightMarginInScrollRegion`,
`CBTTests.test_CBT_IgnoresRegion`, and the DECSED/DECSEL/DECSTR/REP failures.
Some DA/window failures reflect deliberate identity or host policy; changing
the app to satisfy them blindly would be wrong. The artifact, pinned suite
and reproduction command are linked in [conformance.md](conformance.md).

## Images and graphics

The G1–G8 repairs in [protocol coverage](protocol-coverage.md) are completed,
not outstanding findings. These are the remaining limits.

| ID | Status / order | Gap and consequence | Completion evidence |
| --- | --- | --- | --- |
| G01 | Partial / Later | **Placement persistence:** primary width reflow and partial-width scrolling clear image placements. The image resource may survive while its visible placement disappears. | Define intended anchoring through both operations and test ordinary, relative and placeholder images. Evidence: emulator reflow/scroll paths and [`KittyGraphics.swift`](../Sources/TerminalEngine/Emulation/KittyGraphics.swift). |
| G02 | Missing / Optional | **Kitty indexed images (`f=8/16`)** are rejected; RGB/RGBA/PNG work. These are newer palette-linked formats, not the cause of the fixed icat blank-image bug. | Implement only when useful clients need them; test palette changes and alpha. The [current Kitty specification](https://sw.kovidgoyal.net/kitty/graphics-protocol/#indexed-color-data) documents the extension. |
| G03 | Partial / Later | **SIXEL:** transparent-background subset only; P2 background semantics, aspect ratios, DECSDM 80, mode 8452 and palette persistence across images are missing. | Expand decoder/protocol tests against real SIXEL clients, including erase/background and scrolling behavior. Evidence: [`SixelDecoder.swift`](../Sources/TerminalEngine/Emulation/SixelDecoder.swift), `TerminalImageTests`. |
| G04 | Partial / Optional | **iTerm inline images:** original inline `File` form and first frame only; no multipart, downloads, ReportCellSize or feature reporting. | Choose supported scope before implementation. Add image/client tests for selected features. Evidence: [`InlineImageDecoder.swift`](../Sources/TerminalEngine/Emulation/InlineImageDecoder.swift). |
| G05 | Partial / Later | **Graphics transport responsiveness:** file/shared-memory work runs synchronously on the terminal owner. Size bounds exist, but a slow filesystem can still delay that session. Successful shared-memory transport lacks a dedicated regression. | Add a successful shared-memory test and measure owner latency with slow file transport before redesigning it. Evidence: [`KittyTransport.swift`](../Sources/TerminalEngine/Emulation/KittyTransport.swift), graphics extension tests. |

Image budgets (16 MiB/image, 64 MiB/store, 64 images, 256 placements, 4096 pixels
per side, 1000 frames and relative depth 8) are intentional resource limits,
not automatically defects. Full animation/crop/alpha/z-order pixel validation
is listed separately under V04.

## Desktop behavior and usability

| ID | Status / order | Gap and consequence | Completion evidence |
| --- | --- | --- | --- |
| U01 | Partial / Next | **Underline styles are flattened.** The model preserves underline kinds, but the renderer draws one single line for every nonzero kind. Curly/dotted/dashed/double diagnostics lose their appearance. | Render each supported kind with pixel tests, including colored underlines, wide cells and Retina scaling. Evidence: [`Renderer.swift`](../Sources/TerminalUI/Renderer.swift), `cell.style.underline > 0` branch. |
| U02 | Partial / Optional | **No blinking presentation.** SGR blink is retained and cursor shape codes accept blinking variants, but rendering has no blink phase; cursor variants 3/4 and 5/6 are paired. | Decide whether blink is wanted. If so, add deadline-driven redraws and idle/occlusion tests; otherwise document steady rendering as policy. Evidence: parser SGR flags and renderer cursor switch. |
| U03 | Missing app wiring / Optional | **BEL has no app feedback.** The session exposes/coalesces `onBell`, but the app never assigns it. No audible/visual bell or inactive-pane attention indication follows. | Choose quiet visual, audible, or deliberately disabled behavior; wire and rate-limit only the chosen behavior. Evidence: [`TerminalSession.swift`](../Sources/TerminalHost/TerminalSession.swift), [`main.swift`](../Sources/Terminal/main.swift). |
| U04 | Partial / Next validation | **IME preedit is simplified.** `setMarkedText` flattens attributes, `characterIndex(for:)` always returns 0, candidate geometry uses the cursor cell, and rendering sizes preedit to at most 20 cells. It does not represent the full selected-clause/caret geometry of long compositions. | Exercise Japanese/Chinese/Korean input, multi-clause edits, long preedit, clicks, focus switches and resize. Implement only the terminal-appropriate text-input contract; do not fake edits to arbitrary shell text. Evidence: [`Canvas.swift`](../Sources/TerminalUI/Canvas.swift) NSTextInputClient methods and renderer marked-text path. |
| U05 | Partial / Next | **Accessibility exposes the presented viewport, not a fetchable history document.** AX projection is bounded at 262,144 UTF-16 units. Screen-reader access to older output requires viewport navigation; history fetching is absent. | Define bounded history navigation and test it with VoiceOver. Existing external AX styled-text checks do not establish speech/navigation usability. Evidence: [`AccessibilityProjection.swift`](../Sources/TerminalUI/AccessibilityProjection.swift), Canvas AX methods. |
| U06 | Partial / Optional | **Trackpad scrolling is line-granular.** Fractional deltas accumulate, but only whole lines reach the session; no sub-row pixel translation is rendered. | Decide whether smooth pixel scrolling is wanted and validate selection/mouse-reporting interaction. Evidence: [`ScrollAccumulator.swift`](../Sources/TerminalUI/ScrollAccumulator.swift). |
| U07 | Partial / Optional | **Find is a bounded, case-insensitive literal search.** No case toggle, regex or whole-word option; retained matches cap at 10,000 and query size at 4096 UTF-8 bytes. Matching uses lowercase mapping, not a general locale-aware normalized search. | Keep caps visible; add search modes only if desired, with cancellation/resource tests. Evidence: [`HistorySearch.swift`](../Sources/TerminalEngine/Emulation/HistorySearch.swift), [`FindBar.swift`](../Sources/TerminalUI/FindBar.swift). |
| U08 | Partial / Later | **Bundled shell integration is zsh-only.** Bash/fish run and are in the PTY corpus, but lack equivalent bundled OSC 7/133 hooks. OSC 133 A/B/C/D is consumed, but exit status is not retained as command metadata; no command-history navigation UI exists. | Test and add equivalent hooks where needed without replacing users' prompts. Treat command navigation/status UI as a separate product choice. Evidence: [`ShellIntegration`](../Resources/Terminal/ShellIntegration), emulator `finishString`. |
| U09 | Missing / Next | **Crash recovery is still a plan.** There is no implemented persistence/restoration of windows, tab/split layout, working directories or scrollback. New windows start at a fixed centered size. | Follow the approved [recovery plan](session-recovery-plan.md), which restores after unclean exit only. Agent auto-resume policy remains undecided; it need not block basic recovery. Do not introduce normal-quit restore contrary to that plan. |
| U10 | Missing / Optional | **Pane management is basic:** split/close/mouse focus and scripted focus exist; no dedicated directional pane-focus shortcuts, zoom-pane command, or pane move/reparent UI was found. Tab navigation already exists. | Choose desired actions, then test nested splits and focus/menu routing. Evidence: `TerminalWindow`, app menu and [`KeyMap.swift`](../Sources/TerminalUI/KeyMap.swift). |
| U11 | Missing UI / Optional | **Customization:** no saved shell/launch profiles, configurable keybindings, separate left/right Option policy, user theme editor/import, or cursor-style controls. Font family and ligatures already exist; embedding callers can supply colors. | Pick actual desired settings rather than importing every original spec option. Evidence: [`Preferences.swift`](../Sources/Terminal/Preferences.swift), [`Settings.swift`](../Sources/Terminal/Settings.swift), [`ViewConfiguration.swift`](../Sources/TerminalUI/ViewConfiguration.swift). |
| U12 | Confirmed / Later | **Bidi controls survive titles.** `sanitizedTitle` removes category Cc only, leaving overrides/isolates that can reorder a displayed host/path. This affects display, not command execution. [Issue #5](https://github.com/HelgeSverre/terminal/issues/5) remains open; Helge requested an explanation, not yet a fix. | Explain and, if selected, strip the specific bidi controls while preserving legitimate ZWJ/WORD JOINER text; add title tests. |
| U13 | Partial / Optional | **Automation is command-based and narrower than the UI/library.** No scriptable window/tab/pane collections, current-directory property, full history read, text selection command, or complete preference surface. `send text` acceptance does not mean command completion. | Extend only the needed scripting contract with stable targeting and bounded reads. Evidence: [automation documentation](automation.md), [`Terminal.sdef`](../Resources/Terminal/Terminal.sdef), [`Automation.swift`](../Sources/Terminal/Automation.swift). |

## Embedding and additional platforms

These are library/platform scope gaps, not reasons to block the macOS app.

| ID | Status / order | Gap and consequence | Completion evidence |
| --- | --- | --- | --- |
| E01 | Partial / Later | **UIKit view is an early implementation.** No selection/copy/paste/find/link UI; it conforms to UIKeyInput, not the full UITextInput composition contract. AX has a generic label/direct-interaction trait, not the macOS text projection. Hardware input handles key-down paths without macOS's full release/repeat metadata path. | Qualify touch, hardware keyboards, IME and VoiceOver on devices before claiming macOS parity. Evidence: [`TouchCanvas.swift`](../Sources/TerminalUI/TouchCanvas.swift), [`iOSCheck`](../Examples/iOSCheck). |
| E02 | Partial / Optional | **Headless API lacks selection/search.** Screen, history viewport, cells, image pixels, replies and encoding exist, but no equivalent of the session's selection/search interface or state serialization. | Add only required host use cases and public API tests. Evidence: [`HeadlessTerminal.swift`](../Sources/TerminalEngine/HeadlessTerminal.swift). |
| E03 | Decision / Later | **No stable embedding API commitment.** The embedding guide tells consumers to pin a commit/main and expect changes. Libraries use Swift 5 language mode; Swift 6 strict-concurrency qualification is separate from the example hosts compiling in Swift 6. Zsh integration depends on bundled helper-relative resources. | Define API/version support, qualify concurrency and test a standalone consumer's resource/launcher packaging. Evidence: [embedding guide](embedding.md), [`Package.swift`](../Package.swift). |
| E04 | Partial / Later | **Dependency mode is inferred from a path substring.** Package.swift excludes app/updater/tests only when its path contains `/checkouts/`. A local path dependency outside that layout resolves the development package graph, including Sparkle; this is not a robust explicit consumer-mode boundary. | Test both remote and local-path consumers, document current behavior, then choose a manifest structure that does not depend on checkout directory naming. |

## Unresolved observations and validation gaps

These must not be reported as demonstrated app bugs. Existing passing evidence
is retained; each row specifies what remains outside it.

| ID | Status / order | Evidence gap | Next experiment |
| --- | --- | --- | --- |
| V01 | Observed / Next | **`kitten icat --hold` through tmux ignores exit keys.** Image displayed, but Enter/Esc/Ctrl-C did not exit with default `extended-keys off`; Neovim input subsequently worked. | Capture negotiated input bytes and compare direct/tmux extended-keys settings with a known-good terminal. Isolate client, tmux or terminal before changing encoding. [Recorded reproduction](../reports/kitty-real-world-2026-11-17/README.md). |
| V02 | Validation / Next | **Real input methods/layouts:** synthetic input tests do not certify physical dead keys, non-US layouts, CJK switching, Option policy, composition during focus/resize, or all Kitty metadata. | Small manual matrix using real keyboards/input sources, retaining exact OS/layout/client versions and outcomes. |
| V03 | Validation / Next | **VoiceOver usability:** external AX text/style checks passed, but speech order, navigation, live-output announcements, selection and find workflow were not exercised. | Complete an actual VoiceOver shell/editor/history workflow; distinguish macOS and UIKit coverage. |
| V04 | Validation / Later | **Rendered image correctness:** PNG/GIF/Chafa/Snacks images were seen, but no exhaustive session-to-Metal pixel oracle for animation timing, crop, alpha, z-order and relative/placeholder combinations. | Add deterministic captured-frame comparisons for representative cases; include successful shared-memory transport. |
| V05 | Validation / Later | **Long-running desktop lifecycle:** rapid resize smoke passes, but mixed-DPI display moves, sleep/wake, display disconnection, occlusion, long-lived selection/search and arbitrary shell redraws are not fully qualified at this tip. An older startup timeout and Downloads/TCC stall have no current isolated explanation. | Reproduce on a frozen app with natural shell configs and ordinary Launch Services startup. Do not treat historical stalls as confirmed current failures. See [status history](status.md). |
| V06 | Partial + validation / Later | **Whole-process resource behavior:** per-session history/graphics/input and shared glyph budgets exist; they do not form a complete app-wide memory admission budget. Historical history accounting is not actual Swift heap size. Swift allocation OOM is not recoverable. GPU error/device recovery and sustained retirement pressure need broader evidence. | Measure many panes, retained snapshots/images, slow consumers and forced allocation pressure; distinguish controlled rejection from process OOM. Evidence: [resource decisions](decisions.md#unicode-and-resource-identity), session/read broker, renderer and glyph residency. |
| V07 | Validation / Later | **Distribution lifecycle:** signed/notarized artifacts and trust checks exist, but clean-machine installation, real update across versions, interrupted update/recovery and permission behavior are not fully qualified by source/build checks. | Use isolated signed copies/clean machines, keeping Helge's installed terminal untouched. Evidence: [releasing](releasing.md), [`Updates.swift`](../Sources/Terminal/Updates.swift), [status](status.md). |
| V08 | Validation / Later | **Support matrix:** current CI runs macOS 15 headless/conformance/ASan jobs, not a full macOS 14/Intel/iOS/device/real-GPU/SSH/remote-terminfo matrix. Earlier targeted platform checks do not certify every new tip. | Define supported combinations and run representative hardware/OS/client cases, including SSH and remote defaults. See [`ci.yml`](../.github/workflows/ci.yml), package platforms, [real-client report](../reports/kitty-real-world-2026-11-17/README.md). |
| V09 | Measured / Later | **Under-five-minute goal depends on the boundary.** On run 44069317138 the native test step took 4m45s, the headless job 5m40s, and the interval from the earliest job start to aggregate completion was 6m03s. One passing run does not establish cold-cache/p95 performance. | Decide whether the goal applies to tests or total feedback, then measure repeated cold/warm runs and setup/cache costs. Keep conformance/fuzz gates. No timing changes are made by this inventory. |

## Intentional choices and stale findings

These are excluded from the repair backlog unless Helge changes the decision:

- **OSC 52 writes and paste prompts:** [#6](https://github.com/HelgeSverre/terminal/issues/6)
  and [#8](https://github.com/HelgeSverre/terminal/issues/8) were closed as not planned.
  Clipboard writes are intentional; reads return empty. No unsolicited multiline
  paste confirmation should be added.
- **Emoji width:** grapheme clustering stays on by explicit decision. Zsh's
  codepoint-width editing mismatch is real and covered by `ShellWidthTests`;
  “Join emoji sequences” is the existing workaround/tradeoff. See [BUGS](../BUGS.md).
- **TERM identity:** `xterm-256color` remains the child default intentionally
  for remote availability. A conservative `helge-terminal` entry is already
  bundled. Do not simply switch TERM to fix Snacks; identity queries and upstream
  detection are separate. See [terminfo](terminfo.md).
- **Raw eight-bit C1, child window manipulation, process reattachment, tmux
  control mode, plugins, visual bidi reordering and persistent raw recordings**
  are not current required scope. Normal-quit session restoration is explicitly
  excluded by the recovery plan.
- **Xcode project:** [#4](https://github.com/HelgeSverre/terminal/issues/4) is an
  open tooling evaluation, not a missing runtime feature. SwiftPM plus the bundle
  tool is the current supported build. It was not closed by this audit.
- **Already done:** hover destination (#7), isolated test/release work (#9),
  release diagnostic exclusion (#10), G1–G8 graphics repairs, size queries
  14/16/18/19, async glyph raster work, shared PTY reading, font/ligature controls,
  selection/reflow work, SwiftUI wrapper and UIKit view. Old documents still
  contain some contrary statements.

| ID | Status / order | Documentation gap | Follow-up |
| --- | --- | --- | --- |
| D01 | Confirmed / Later | `BUGS.md` still lists implemented size replies as missing; `embedding.md` says both that an iOS view exists and that no iOS/SwiftUI view exists; status/decision documents retain older architecture/platform/work lists. Historical migration ledgers are not current defects. | Reconcile living docs with code, preserving clearly dated historical evidence. Use this inventory as the dated cross-app baseline, with protocol coverage for detailed graphics behavior. |

The original spec's Vulkan/macOS 26 architecture was superseded. The current
package declares macOS 14/iOS 17, and the app uses Metal/AppKit. Original TOML
configuration and other broad product aspirations should be reconsidered as
choices, not silently reinstated as release requirements.

## Suggested execution order

1. C01–C03: truthful identity and capability discovery, with real Snacks startup.
2. V01: isolate tmux/icat keyboard negotiation before another input change.
3. U01 and targeted C05 cases: visible underline correctness and practical VT
   semantics, each with a reproducer. Evaluate U12 title filtering separately.
4. U04/U05 and V02/V03: real IME/VoiceOver workflows, then fix demonstrated gaps.
5. U09: basic unclean-exit recovery following the existing plan.
6. G01/G03/G05, V04–V08: graphics and lifecycle coverage; use client evidence to
   prioritize additional protocol work.
7. Optional settings, pane conveniences, search modes and library/platform
   expansion only when selected. Track CI feedback timing independently.

## Audit verification

No application code changed and no new build, GUI session or test suite was run
for this inventory. Source dispatch and call sites were read; existing evidence
was checked against current files rather than treating historical plans as
implemented features or current failures.

- Previous `just test` at `a9aa3e5` passed 120 developer, 379 terminal and 13 GPU
  tests (512 total), plus tooling/terminfo/PTY corpus checks. The [runtime report](../reports/kitty-real-world-2026-11-17/README.md)
  retains commands, versions and frozen executable identity.
- The actual CI run and downloaded conformance JSON confirm the counts/timings
  above. SHA-256 of the downloaded `esctest.json`:
  `e650d389c600d3a07d2eda2d9ff9ec3b24969b1ceee47061b519be09120dbbbb`.
  Raw artifacts stay outside Git.
- GitHub issues were read with `gh` after the connected search rejected its
  arguments. No issues were changed. History search was unavailable because its
  embedding service rejected credentials; no archive fallback was used.
- Primary sources checked: xterm maintainer's control-sequence text, Kitty's
  graphics specification, and Snacks terminal detection source. Source links
  describe protocol expectations; findings about this app come from local code
  and the versioned evidence above.
