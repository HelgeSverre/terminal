# Deeper Swift port: ownership, names, and migration

Proposed on 2026-11-08 from experiment `74ff431` and production `eb0293e`. This is an executable migration plan, not a claim that the target design or parity already exists. Active port work can supersede individual observations below; update the acceptance evidence when it does. The plan changes only this experiment until its release gates pass.

The next useful semantic step is to consolidate terminal behavior around one rich cell/document representation, then integrate the already-written algorithms through that representation. A rename-only pass would leave multiple competing models with better labels. Keep mechanical moves separate from semantic changes, remove the C emulation round trip after integration, and retain the existing ordered session scheduler.

## What the code actually does today

| Evidence in the experiment | Architectural consequence |
| --- | --- |
| `native/SwiftTerminalCore.swift` holds parser state, two grids, history, modes, input mapping, search, graphics integration, JSON creation, borrowed allocation, and C exports. | Extract coherent ownership, rather than splitting each type into its own file. |
| `SwiftReflow.Cell` has text/width/continuation; `SwiftCell` additionally has style/link/flags; `SwiftSearchCell` has a third kind model. | A single rich cell representation must survive reflow and feed search. Converting through text-only cells is not acceptable integration. |
| `SwiftMarginGrid<Value>` edits a generic rectangular array and delegates blank creation; it has no knowledge of grapheme pairs, protection, or history. It is absent from the app's source list. | Merge its algorithms into document editing with actual terminal cells. A generic grid interface does not earn its place here. |
| The app compiles `SwiftReflow.swift` and `SwiftSearchViewport.swift`, but `resize` copies/truncates rows; C search `fill` and `step` return `2`, and acceptance scans the document synchronously. | Compiled standalone code is not integrated behavior. Resize and search must pass through the app's real semantic path in tests. |
| `publishBinary` makes a full JSON snapshot, parses it into a dictionary, removes rows, serializes metadata, and separately allocates C cell strings. `Session.publish` decodes and copies again. | Direct immutable Swift snapshots remove a material ownership and allocation problem, not merely FFI syntax. |
| `SwiftSnapshotBridge.swift` defines a competing JSON `SnapshotBridge`, but the app compiles the original `SnapshotBridge.swift`. | Delete the unused replacement after checking all source manifests; keep one compatibility decoder until the host switches. |
| `Session.swift` owns PTY events, admission, bounded reads/writes, paste cancellation, lifecycle, search dispatch, image caching, and all snapshot type declarations. | Keep session ordering together. Move data definitions and image-resource ownership to emulation; extract lifecycle only with a coherent PTY interface. |
| `SwiftTerminalCore.feed` ignores the ABI clock; graphics gets `now: 0`. Geometry checks each axis but omits Rust's total-cell limit. `terminal_validate` only checks handle presence. | Typed time, validated geometry, and real invariant checks are semantic work, not cleanup. Do not delete clock parameters just because the incomplete port currently ignores them. |
| The normal recipe and `SwiftIncrementalBuild.swift` have separate handwritten source lists. They already disagree about reflow/search. | Establish a single build source graph before more files arrive. |
| Production includes AppleScript automation, PTY-end admission handling, and stale-frame rejection that this experiment's base may lack. | Final comparison requires the same host revision and resources on both implementations. Preserve these fixes during integration. |

Recorded evidence remains limited: native Session 20/20, native C PTY 10/10, initial differential smoke 5/5. The pinned Unicode corpus was 715/853 when inspected. Neither those counts nor standalone graphics/reflow tests replace all 86 original behavioral cases. `docs/swift-port-parity.md` is the status ledger; this document describes the destination.

## Target ownership and source tree

Use `Sources` and `Tests` consistently. The folders below identify domain ownership. Initially they can remain one Swift compiler module; directories do not require protocols, packages, or public declarations. Once the direct Swift seam is working, compile `TerminalEmulation` independently of AppKit/Metal and keep the app as its caller. Do not combine that build change with the first file move.

```text
Sources/
  TerminalEmulation/
    TerminalEmulator.swift       # ordered protocol effects and public seam
    TerminalDocument.swift       # rich cells/rows, screens, history, identities
    DocumentEditing.swift        # document's margins/rectangles/wide-cell repair
    DocumentReflow.swift         # document's atomic resize and anchor remapping
    TerminalProtocol.swift       # incremental VT framing and command decoding
    TerminalInput.swift          # semantic input and negotiated wire encoding
    TerminalSnapshot.swift       # immutable presentation values and resources
    HistorySearch.swift          # bounded literal matching and result proofs
    KittyGraphics.swift          # uploads, decoding, resources, placements
    Unicode/
      TerminalText.swift         # UTF-8, grapheme state and terminal width
      Unicode18Tables.swift      # generated tables; no handwritten policy
  TerminalApp/
    Application/
      main.swift                # entry point and argument dispatch only
      TerminalApplication.swift # menus, app lifecycle, window registration
      TerminalWindow.swift      # panes, splits, tab/window behavior
      AppleScriptCommands.swift # current production automation
    Session/
      TerminalSession.swift     # admission, ordered events, fair scheduling
      PTYProcess.swift          # descriptors, launch handshake, reaping, close
      PTYWriteQueue.swift       # queued writes and paste framing/cancellation
      SessionHistorySearch.swift # query replacement/retry/worker scheduling
    Presentation/
      TerminalCanvasView.swift  # AppKit input/IME/selection/accessibility hooks
      AppKitKeyRouting.swift    # NSEvent -> semantic input / native shortcut
      AccessibilityProjection.swift
      MetalRenderer.swift      # frame coalescing, glyph atlas, GPU lifetime
      CellGlyphGeometry.swift  # box/block raster geometry
      TerminalFont.swift
      TerminalTheme.swift
      Terminal.metal
    Preferences/
      TerminalPreferences.swift
      SettingsWindow.swift
    Diagnostics/
      NativeSmoke.swift        # existing in-process diagnostics
      EditingSmoke.swift
      FontCatalog.swift
      TimingDistribution.swift
  PTYLaunch/
    PTYSpawn.c
    PTYSpawn.h                  # launch declarations only
    PTYLauncher.c              # distinct executable, not linked into app
Resources/
  Info.plist
  Terminal.sdef                # from production automation
  ShellIntegration/
  Fonts/
  AppIcon.png
Tests/
  Emulation/                   # scenarios exercise TerminalEmulator
  Session/                     # PTY, ordering, shutdown and paste scenarios
  Presentation/                # geometry/input/accessibility/renderer gates
  Fixtures/                    # transcripts, Unicode corpus, graphics assets
  Oracle/
    RustOracle.swift           # launches pinned reference executable
    LegacyTerminalABI.swift    # temporary Swift C exports and encoding
    LegacyTerminalABI.h        # temporary declarations for original C tests
    LegacySnapshotDecoder.swift # temporary old-host decoder
Tools/
  Build.swift                  # one incremental compile/package graph
  Distribution.swift
  GenerateUnicode18.swift
  DifferentialReplay.swift
  TerminalBenchmark.c
```

The diagnostic files stay in the app while its self-test switches depend on them; moving them to `Tests` without replacing that mechanism would be misleading. The legacy adapter is temporarily linked into the experiment app until the host switches, despite its eventual test-only location. During that interval, keep it under an explicit `Compatibility/` folder instead of pretending it is test-only. Keep Rust sources at their pinned original paths until the oracle runner is reproducible; do not also rename Cargo packages during the Swift migration.

`DocumentEditing` and `DocumentReflow` are implementation partitions of **TerminalDocument**, not new public modules. Their deletion would move terminal invariants into command handlers, so they earn internal locality. Conversely, a generic `Grid<Value>`, a forwarding `SnapshotProvider`, or a facade that merely renames every C function would add interface without depth.

| Module | Sole knowledge owner | What callers no longer need to know |
| --- | --- | --- |
| TerminalEmulator | VT semantic ordering, terminal modes, current pen, pending protocol work, replies, synchronized-update timing | Escape syntax, REP resumption, mode-dependent input, graphics/parser interaction |
| TerminalDocument | Rich row content, active screen, cursor and saved state, screen-local editing modes, margins, history retention, row identities, viewport anchor and resize transaction | Wide-cell repair, protected erase, physical/logical row mapping, anchor eviction and epoch changes |
| TerminalText | Pinned UTF-8/grapheme/width behavior | OS Unicode version, partial scalar state, cluster continuation rules |
| HistorySearch | Query validation/folding, bounded matching, row proofs and result validity | Character-to-cell mapping, soft-wrap joining, stale-hit detection |
| KittyGraphics | Protocol resource IDs/generations, uploads/decode limits, placement lifecycle | Chunk atomicity, PNG/zlib validation, eviction and image reuse |
| TerminalSession | Cross-event order, input admission, scheduling, publication pacing | Mode-after-output races, queue pressure, ordering resize against PTY output |
| PTYProcess / PTYWriteQueue | OS lifecycle / admitted write progress and framing | EOF versus child exit, descriptor retirement / partial paste cancellation |
| MetalRenderer | Render request coalescing, GPU resources and frame validity | In-flight resource retention, atlas mutation, drawable mismatch rejection |

A screen-local flag belongs with document editing (origin, insertion, margins, wrap behavior). Protocol negotiation flags belong with emulation/input (keyboard, focus, mouse, bracketed paste). Do not maintain overlapping mutable `Modes` bags. A snapshot projects the authoritative values; it does not become another writable source.

## Old-to-new mapping and deliberate merges

| Current files/types | Destination and action |
| --- | --- |
| `SwiftTerminalCore.swift` / `SwiftTerminalCore` | Split into `TerminalEmulator`, `TerminalProtocol`, `TerminalDocument`, and the temporary legacy adapter. Do not rename the whole file to `Engine`. |
| `SwiftStyle`, `SwiftCell`, `SwiftRow`, `SwiftScreen` | Canonical internal document types, grouped in `TerminalDocument.swift`; use typed cell kinds and colors. Preserve style/link/protection on every edit. |
| `SwiftMargins.swift` / `SwiftMarginGrid<Value>` | Merge operations into `DocumentEditing.swift`; remove generic `Value`/blank callback and second grid storage. |
| `SwiftReflow.swift` / text-only cells and request/result bags | Merge into `DocumentReflow.swift`, operating on canonical rows. Old columns and viewport come from the document, not caller-provided redundant fields. |
| `SwiftSearchViewport.swift` | `HistorySearch.swift`. It is a search task, not a viewport implementation. Remove copied document-wide row arrays from the owner/worker seam; retain one immutable row page. |
| `SwiftUnicode.swift`, `SwiftUnicode18Tables.swift` | `Unicode/TerminalText.swift`, `Unicode18Tables.swift`; merge UTF-8/segmenter/width policy behind one internal text interface, keep generated data separate. |
| `SwiftInputEncoder.swift` | `TerminalInput.swift`; keep semantic keys and encoding together, replace UInt32 bridge IDs outside the legacy adapter. |
| `SwiftGraphics.swift` / `KittyGraphicsStore` | `KittyGraphics.swift` / `KittyGraphics`; keep format decoding internal until a second real consumer requires a seam. |
| `Session.swift` snapshot/color/image declarations | `TerminalSnapshot.swift`; adopt Swift names (`softWrapped`, `historyRows`) and keep legacy JSON spelling in adapter coding keys only. |
| `Session.swift` / `Session` and nested `HistorySearch` | `TerminalSession.swift` / `TerminalSession`; nested search scheduling becomes `SessionHistorySearch`. Do not confuse worker scheduling with matching. |
| `Transport.swift` / `WriteTransaction` | Combine transaction state with existing session write queue in `PTYWriteQueue.swift`; do not create a one-method Transport wrapper. |
| `SnapshotBridge.swift`, `SwiftSnapshotBridge.swift` | Original becomes temporary `LegacySnapshotDecoder`; unused competing JSON version is removed; both disappear from the app after direct snapshots. |
| `Bridge.h` | Split legacy emulation declarations from `PTYSpawn.h`; final app imports only launch declarations. |
| `Spawn.c`, `Launcher.c` | `PTYSpawn.c`, `PTYLauncher.c`; retain behavior during the language experiment. |
| `Canvas.swift`, `Renderer.swift`, `Geometry.swift`, `KeyMap.swift` | Name actual responsibility: `TerminalCanvasView`, `MetalRenderer`, `CellGlyphGeometry`, `AppKitKeyRouting`. |
| `Font.swift`, `Theme.swift`, `Preferences.swift`, `Settings.swift`, `Statistics.swift` | `TerminalFont`, `TerminalTheme`, `TerminalPreferences`, `SettingsWindow`, `TimingDistribution`; no extra facades. |
| `main.swift`, production `Automation.swift` | Separate application/window ownership from entry point; automation becomes `AppleScriptCommands.swift`. Preserve pane IDs and automation contracts. |
| `SwiftCoreTests`, `SwiftSearchViewportTests`, `TransportTests` | `TerminalEmulatorTests`, `HistorySearchTests`, `PTYWriteQueueTests`; move scenario tests without replacing expected behavior. |
| `SwiftDifferential.swift`, `SwiftIncrementalBuild.swift` | `DifferentialReplay.swift`, consolidated `Build.swift`; language prefixes no longer distinguish product owners. |

Keep established technology names such as CoreText and CoreGraphics: they are proper platform names. Remove our generic `core` variables, recipe names and descriptions when their owning code migrates (`emulator`, `emulation-test`, `benchmark-emulation`). Oracle paths remain historical and can retain their pinned Rust package names.

## Interface sketches and lifetime rules

These are design sketches, not a demand for this exact collection of public types. Add a method only when the app or scenario corpus needs it. No protocol is needed for a single production implementation; the differential runner is the real Rust/Swift seam.

```swift
// Confined to the session owner queue; deliberately not Sendable or an actor.
final class TerminalEmulator {
    init(size: TerminalSize, historyRows: Int)

    // bytes is borrowed only for this call. Empty input may drain pending REP.
    func advance(_ bytes: UnsafeRawBufferPointer,
                 at time: TerminalInstant) -> EmulationProgress
    func apply(_ action: TerminalAction, at time: TerminalInstant) -> TerminalEffects
    func finish(at time: TerminalInstant) -> TerminalEffects
    func snapshot(at time: TerminalInstant) -> TerminalSnapshot?
}

struct EmulationProgress {
    let consumedBytes: Int
    let hasPendingWork: Bool
    let effects: TerminalEffects // ordered replies and typed host requests
}

enum TerminalAction {
    case input(TerminalInput)
    case resize(TerminalSize)
    case scroll(rows: Int)
    case followTail
    case clearDisplay
    case setHistoryRows(Int)
}
```

`TerminalSize` validates dimensions once: each axis 1…4096, at most 1,048,576 cells, checked pixel arithmetic. It carries cell pixel extent because graphics and PTY sizing require it; the headless runner supplies an explicit fixture extent. Remove convenience resize overloads/default 8×16 arguments once call sites use a size. The document derives old dimensions, anchor and alternate policy internally. A failed resize leaves state untouched. `TerminalInstant` is monotonic time supplied by the session or replay; emulation owns deadline interpretation, including upload expiry and synchronized output. Repeated `snapshot` polling must not fabricate revision changes.

`TerminalEffects` contains consumable protocol bytes and domain host actions, such as a requested redraw, rather than magic `clearDisplay` integers. It must not duplicate a second retained reply queue. The session transfers those bytes into its write queue before another semantic event runs. Input bytes are encoded when that input reaches the owner, after earlier output and pending work. This preserves the existing REP-before-input guarantee. A nil snapshot means publication is temporarily gated by synchronized output; it is not a decode failure. The session schedules the next deadline check while the emulator owns the deadline and release decision.

Do not expose a general configurable work budget. Port the frozen behavior first: a feed turn accepts at most 65,536 bytes, REP advances at most 4,096 placements, and reply pressure stops admission at the oracle's 32,768-byte threshold. Session admission/read/write watermarks remain session policy. Algorithmic work bounds do not prove wall-clock latency bounds: reflow and PNG decoding need separate latency measurements and may require resumable work later. Cancellation/close must remain able to run between bounded turns.

```swift
// Public immutable projection; no C pointers, mutable row handles or JSON.
struct TerminalSnapshot: Sendable {
    let revision: TerminalRevision
    let size: TerminalSize
    let rows: [RowSnapshot]
    let cursor: CursorSnapshot
    let viewport: ViewportSnapshot
    let modes: ModeSnapshot
    let images: [ImagePlacementSnapshot]
    // Each placement retains its exact immutable pixel generation.
    let imageResources: [ImageKey: ImagePixels]
    // title, palette, search and prompt projection omitted here for brevity.
}
```

Start with immutable value rows and Swift copy-on-write storage; no zero-copy promise. A delivered snapshot remains valid after more output, resize, image-ID replacement, or session destruction. The emulator creates the full consistent snapshot on the owner queue. Image resources belong to graphics, and snapshots retain the exact generation, removing the session's C fetch/cache loop. The renderer alone owns GPU textures. Session/main/render mailboxes retain only the latest pending request; submitted GPU work retains its resources until completion. Account for retained snapshot generations separately from the graphics store's live budget, and stress replacement of a maximum-size image while frames are in flight.

Use checked `Sendable` on immutable values where possible. Keep any required unchecked synchronization declaration on the small owner/coalescing wrappers, with the confinement rule next to it. Do not blanket-mark the mutable emulator `@unchecked Sendable`. Do not change to actors merely because the implementation language is Swift: suspension and reentrancy would require proving the entire ordering contract again.

```swift
// SessionHistorySearch owns queue hops, replacement, cancellation and retries.
// These operations are internal to the emulation/search collaboration.
extension TerminalEmulator {
    func beginSearch(_ query: String) throws -> HistorySearchTask
    func fillSearchPage(_ task: inout HistorySearchTask) -> SearchProgress
    func acceptSearch(_ task: HistorySearchTask) -> SearchOutcome
}

struct HistorySearchTask: Sendable {
    mutating func step() -> SearchProgress // worker: no emulator reference
}
```

Only one queue owns the task at a time: owner fills one immutable row, worker advances it, owner accepts or fills the next page. Transfer value ownership, not a mutable document reference. The task keeps a frozen stop position, 1…4096-byte query, at most one 16 MiB row, bounded matching state, and 64-cell work quantum. `TerminalDocument` owns row identity/revision and anchor mutation; `HistorySearch` owns validation of its captured proof. An accepted hit changes viewport/highlights in one owner operation. Session scheduling retains the existing latest-query replacement and at-most-two-retry policy. It does not inspect epochs or reconstruct offsets. No all-history `[SearchRow]` conversion per quantum.

Port the oracle's search character semantics deliberately: the current Swift task uses `Character` and Foundation case folding, while the Rust task matches scalar values. Passing grapheme tests alone cannot establish search parity. Keep any necessary scalar-to-cell mapping private to search.

```swift
// Called by AppKit and automation; it hides PTY/emulation scheduling.
final class TerminalSession {
    func submit(_ input: TerminalInput) -> InputAdmission
    func resize(to size: TerminalSize)
    func scroll(rows: Int)
    func find(_ query: String,
              completion: @escaping @MainActor (SearchOutcome) -> Void)
    func cancelPaste()
    func close()
    // Main-actor snapshot/status delivery configured once at construction.
}
```

An admission result means accepted into the ordered queue, not already written. Accepted input is delivered or receives an explicit terminal-close outcome; write pressure cannot silently reject it later. Urgent paste cancellation and close remain transport controls outside a blocked semantic event. PTY EOF, parser finish, write closure, and child reaping remain distinct states. Keep the current Dispatch-source model and independent process/output drainage; extract `PTYProcess` only when it can own those transitions without turning the session into a descriptor-state switchboard.

## Ordered changes and gates

Each row is independently reviewable. A failed semantic gate blocks the dependent step, not unrelated evidence collection. Do not mix file moves, reformatting and semantic fixes in one diff.

| Step | Concrete change | Required exit evidence |
| --- | --- | --- |
| 0. Freeze inputs | Record Rust oracle commit/binary hash, Swift commit, compiler/SDK/OS, fixture hashes and host baseline. Inventory all 86 Rust tests by scenario and expected observables. | Machine-readable ledger maps every source test to replay/native scenario or an explicit gap. Initial 5 cases remain a smoke subset. |
| 1. Repair the build graph | One source manifest/graph for app, headless runner and tests; inventory uncompiled files; remove the unused competing snapshot implementation after reference check. Add all intended suites to a real gate. | Clean/no-op builds and every listed test executable succeed; deliberately add/remove a source to verify graph invalidation. Current omitted algorithms are labelled unintegrated. |
| 2. Mechanical naming | Move existing source/test/resource files and rename established owners; update recipes, manifests, distribution paths, resource lookup and diagnostics. Keep legacy ABI unchanged. Defer internal ownership splits/merges to steps 3–9. | Same semantic outputs before/after moves, app smoke and bundle resource/signature verification. No opportunistic port fixes. |
| 3. Canonical document | Replace three independent cell/row models with rich cells, stable row IDs/revisions, typed kinds/colors, and document-owned geometry validation. Keep snapshot adapter behavior. | Invariant checks cover dimensions, wide pairs, legal kinds, row identities and resource references; corresponding Rust scenario replay remains stable. |
| 4. Complete text/protocol integration | Wire pinned Unicode tables/segmenter into actual printing, including arbitrary byte partitions, malformed UTF-8, pending clusters, mode/save/restore behavior and bounded protocol strings. Wire monotonic time and synchronized updates. | All 853 pinned grapheme cases, terminal width/maximal-subpart cases, semantic transcripts and timeout scenarios pass through actual emulation. Generated tables have provenance/license and reproducible hashes. |
| 5. Document edits/resize | Integrate margins/rectangle operations, rich reflow, viewport identities and history retention using one atomic resize transaction. | Original margin/viewport/clear cases; styles/links/protection and wide cells survive shrink/grow; scrolled anchors survive output/resize and clamp on eviction; alternate return restores primary view. |
| 6. Search and input | Replace stub search exports with the bounded worker task; use semantic input internally; retain old C IDs only in adapter. | Original search/keypad/input cases, cancellation/replacement during output and resize, teardown while worker runs, row memory limit and queue ordering all pass. |
| 7. Graphics integration | Wire actual clocks, parser termination, screen transitions, cursor effects and document placement transformations into KittyGraphics. | Original 13 graphics cases plus real dmscene transcript/app run; direct/PNG/zlib/chunk/delete, timeout, replacement, placement/resource limits and alternate-screen behavior. Screenshots alone are insufficient. |
| 8. Direct Swift host seam | Move immutable snapshot types into emulation; session calls concrete emulator and receives typed effects/snapshots. Move all borrowed allocation/JSON/opaque handles to test compatibility adapter. | Run the same native Session/PTY and differential corpus via direct Swift and legacy adapter; snapshot lifetime tests retain old rows/images across mutation/destruction; no ABI/JSON path in app. |
| 9. Session/host ownership | Extract coherent PTYWriteQueue and SessionHistorySearch; extract PTYProcess if its lifecycle stays local. Bring production host fixes and AppleScript support onto the experiment before comparison. | Input admission, partial-paste cancellation, close/HUP-resistant child, process/output drainage, automation targeting, IME/accessibility, stale-frame geometry gates. |
| 10. Performance and product choice | Run same-host benchmarks and incremental build matrix. Remove oracle-only C exports and Rust app/build dependencies from the candidate product; retain reproducible external reference tests. | Complete parity ledger, native app corpus, resize/redraw stress, dmscene, resource bounds and comparable raw reports. Only then decide whether to replace production. |

Steps 4–7 can be prepared concurrently after step 3 establishes the representation; one integration owner serializes changes to `TerminalEmulator`/`TerminalDocument`. Search/graphics standalone success is a prerequisite, not the final integration gate. Keep the main-branch stretched-frame correction intact. The Starship prompt-fragmentation issue is still under diagnosis: reproduce both clean direct-zsh and actual Starship-init fixtures and compare identical resize sequences. Do not attribute it to language, reflow, or rendering before evidence isolates the cause.

The oracle runner must compare cells/style/link/flags, cursor/modes, replies, input bytes, history/viewport transitions, graphics resources/placements, and resource refusal/timeout behavior. Internal epoch counters need not have identical numbers if intentionally redesigned, but their invalidation behavior must match dedicated transition cases. Never normalize away history or epochs in the only test meant to verify those semantics. Every transcript should run whole, byte-at-a-time, and with deterministic varied chunking; use explicit time and resize/input interleavings where those are part of the behavior.

## Incremental builds without confusing the comparison

First make the existing incremental compiler path the normal executable build, driven by the same source graph as tests. Persist object maps and `.swiftdeps`; use path-derived unique object names rather than filename stems once directories exist. Invalidate the build when source membership, compiler/SDK, target, optimization flags, imported headers or generated tables change. Separate development incremental mode from release optimization choices and report both.

The build graph must also skip unchanged C compilation, Metal compilation, resource copies and signing. Signing depends on final bundle contents and is never skipped after a relevant change. A no-op build that still relinks/resigns is a different measurement from a no-op compiler invocation. Do not add a custom general build framework: extend the narrow existing tool, and use one graph. Defer a SwiftPM/Xcode migration until source ownership and direct Swift imports are settled; it would otherwise add another moving variable. If the custom graph starts recreating package-manager behavior, replace it in its own measured change.

Measure five conditions on both branches: fresh output with warm shared caches, fully unchanged, private implementation edit in emulation, edit to a widely imported snapshot declaration, and host-only edit. Also test a shader/resource-only edit. Report compile, link, packaging/signing and complete `just build` separately. Apply equivalent host incremental improvements to the Rust variant, or label the comparison as a workflow difference rather than a language advantage.

## Decisions and unresolved work

* **Concrete Swift ownership, not a universal backend protocol.** The production app needs one emulator. Rust and Swift are two real adapters at the transcript runner seam; runtime backend switching would impose permanent complexity for a temporary experiment.
* **Typed snapshots, retaining immutable generations.** This avoids the current JSON/borrowed-cell/copy round trip. Start with safe copies/COW; optimize row reuse only after profiling. Maximum retained generations need measurement under slow GPU/presentation pressure, not an assumption that the 64 MiB store budget covers all copies.
* **Keep C launch code.** The language question concerns terminal emulation; the 73-line spawn module and 19-line helper already isolate descriptor inheritance/session creation. Rewriting them adds no necessary Swift benefit. C ABI emulation removal and C launcher removal are different decisions.
* **Use row identities, not an integer scroll offset as truth.** The frozen baseline already defines anchored viewport semantics. Reflow maps anchors within its transaction, and publication derives offsets. A snapshot revision must not double as a clamp revision.
* **Keep rich cell semantics before compact storage.** Swift strings/arrays may allocate more than Rust's compact cells. Measure allocations, retained memory and COW churn before introducing inline scalar storage or arenas. A smaller executable does not imply a smaller working set.
* **No standalone viewport module yet.** Anchor resolution/reflow/history eviction share document knowledge. Extract only if a second caller gains depth without learning those invariants.
* **Atomic semantics do not require an unbounded owner turn.** Resize can build a replacement document privately and commit once, but cancellation and event ordering need a designed continuation if its measured duration is unacceptable. PNG work may similarly need immutable decode work off-owner. These are measured follow-up decisions, not prerequisites for untested concurrency rewrites.
* **Public limits versus internal budgets.** History retention is a user preference; parser/search work quanta and graphics protocol caps are invariant policy. Do not expose every internal constant as a constructor parameter. Preserve existing effective limits before considering changes.
* **Keep naming changes finite.** Rename one owner and its callers together, remove the old name, and avoid temporary synonyms outside the compatibility adapter. `GLOSSARY.md` records domain language; it is not a place for concurrency or file-layout rules.

## Work ownership when executing

Use at most five implementation lanes initially; more parallel writers would fight over the same document/parser integration. Workers can write fixtures and isolated algorithms concurrently, but must not each invent a cell model or edit the session event loop.

| Lane | Exclusive ownership | Depends on / handoff |
| --- | --- | --- |
| Integration lead | TerminalEmulator, TerminalDocument, canonical types, snapshot seam; all final integration edits | Establishes step 3 contract first; receives typed changes from other lanes |
| Text/protocol | TerminalText, generated tables/generator, TerminalProtocol, Unicode/protocol fixtures | Hands integration lead exact print/cluster behavior and passing corpus |
| Document behavior | DocumentEditing, DocumentReflow, margin/viewport/clear fixtures | Uses canonical cells; coordinates identity/anchor contract with lead |
| Search/input | HistorySearch, TerminalInput and focused fixtures | Lead wires emulator calls; session owner wires scheduling later |
| Graphics | KittyGraphics, graphics fixtures/dmscene recordings and checks | Lead wires parser/time/document effects; owns image protocol semantics |

Build/oracle work runs first or in a separate non-conflicting verification lane with exclusive `Tools`, manifests, ledger and benchmark artifacts. Host/session cleanup starts after the direct interface stabilizes; assign it one owner rather than splitting admission, transport and lifecycle across workers. One migration owner performs mechanical file moves only when semantic lanes have a clean handoff. Never have a file-move lane running beneath active implementation edits.

## Honest Rust/Swift comparison

Keep the provisional table in `swift-port-parity.md`, not duplicate drifting measurements here. The final table should include these rows and disclose parity beside every runtime result:

| Measurement | Equal conditions / evidence |
| --- | --- |
| Behavioral coverage | All 86 source scenarios mapped; Unicode 853/853 plus width/UTF-8; graphics/dmscene; native PTY and Session; clear/resize/automation/IME gates |
| Build times and peak build RSS | Same machine, SDK, architecture, optimization purpose, host revision, source graph and cache condition; raw runs and median/spread |
| Signed/stripped executable and bundle size | Same resources/features/signing; strip copied binaries only; identify any runtime libraries or changed deployment requirements |
| Emulation throughput | Same transcript bytes/chunks/time events; include ASCII, SGR-heavy, wide/combining text, adversarial control strings, REP and graphics |
| End-to-end PTY throughput and DSR latency | Same benchmark executable/hash, geometry, font, history, visible state and shell integration; several alternated runs |
| Responsiveness under load | Input admission-to-processing p50/p95/p99/max; queue high-water marks; search, paste cancellation and resize while output streams |
| Memory and allocations | Idle plus fixed histories, Unicode-heavy rows, resize, maximum-image replacement, retained snapshots and slow presentation; peak and settled resident/physical bytes |
| Presentation correctness | Stale-frame rejection, 120-resize direct-zsh and Starship fixtures, primary/alternate return, dmscene artifacts, IME/accessibility/automation |
| Maintenance cost | Production language/bridge surface removed, number of authoritative models, normal build workflow, warnings/concurrency exceptions, documented unsupported cases |

Pin input hashes and output directories per run, record host/OS/power/visible-window conditions, warm up, alternate Rust/Swift execution order, and report several measured runs with spread. Never promote the existing smaller binary or faster executable-only incremental result into a runtime win. Final acceptance is a complete terminal with a clearer ownership model and comparable evidence, not simply a Swift executable that launches.
