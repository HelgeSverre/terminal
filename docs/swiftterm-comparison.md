# SwiftTerm and Terminal compared

SwiftTerm is a terminal library with two sample apps. Terminal is an app with
no library. That is the main difference, and most of the others follow from it.

- **Embedding.** SwiftTerm ships one SwiftPM library product with about 1,550
  public declarations: an engine (`Terminal`), AppKit and UIKit views
  (`TerminalView`), a PTY host (`LocalProcess`, `LocalProcessTerminalView`) and
  a headless host (`HeadlessTerminal`). Terminal has no public declaration.
  Its emulator class is `private`, and the only boundary is an internal C
  interface that tests and headless tools use.
- **Platforms.** SwiftTerm declares macOS 11, iOS 14, tvOS 13 and visionOS 1,
  and builds its engine on Linux, Windows, WASI and Embedded Swift. Terminal
  declares macOS 15 and is built for Apple Silicon only.
- **Protocol coverage.** SwiftTerm implements more: Sixel, iTerm2 images, the
  complete Kitty graphics protocol, bidirectional text, DECRQSS, XTGETTCAP,
  XTVERSION, the title stack, window operations, pixel mouse reports, OSC 12,
  OSC 777, the Kitty clipboard protocol and national character sets. Terminal
  implements none of those. Both implement the Kitty keyboard protocol with
  all five flags, DECLRMM, OSC 8, OSC 52, OSC 133, synchronized output and
  Unicode 18 width and grapheme tables.
- **Rendering.** Both rasterize with CoreText. SwiftTerm draws with
  CoreGraphics by default and has an opt-in Metal renderer; it shapes text, so
  ligatures and Arabic work. Terminal draws with Metal only, one glyph per
  cell, with shaping disabled.
- **Where Terminal is ahead.** Bounded, resumable work on the owner queue
  (reflow, selection, search, REP), history limited by bytes as well as rows,
  viewport and selection anchored to row identity, a process-wide glyph
  budget, a macOS accessibility text interface, drag and drop, and a launcher
  that reports the failing stage of a spawn.
- **Maintenance.** SwiftTerm has 92 commits and four releases in the 30 days
  before this comparison, 54 open issues, and is one release away from 2.0.
  Terminal is one week old, with 521 commits and 41 tags.

Performance was not measured for this document. No build, test or benchmark
was run in either repository. The only performance numbers below are ones
each project publishes about itself, and they are attributed.

## What was compared

| | SwiftTerm | Terminal |
| --- | --- | --- |
| Repository | `github.com/migueldeicaza/SwiftTerm` | `/Users/helge/code/terminal` |
| Commit | `d4f52faaae413b2e69c728ad79cd225cdbebc042` | `e229650c726b448faf66e20a23dd573d9a727dd1` |
| Commit date | 2026-11-12 | 2026-11-12 |
| Latest release | `v1.99.3`, 2026-11-06 | `v0.4.3`, 2026-11-12 |
| Read on | 2026-11-14 | 2026-11-14 |

SwiftTerm paths below are relative to its repository root; `S/` stands for
`Sources/SwiftTerm/`. Terminal paths are relative to this repository; `T/`
stands for `Sources/Terminal/`. A source refactor is moving Terminal's files
into separate targets, so each reference also names the type or function.

SwiftTerm's `main` branch carries the 2.0 API. Its README says so, and the
`v1.99.x` tags are previews of it. The 1.x API lives on a `v1.x` branch that
was not read.

In the tables, **yes** means the code path was read, **no** means the code
was searched and the feature is absent, **partial** carries a note, and **not
verified** means the source did not settle the question. Nothing was run, so
"yes" never means "observed working".

## 1. Scope and packaging

| | SwiftTerm | Terminal |
| --- | --- | --- |
| Ships | A library, plus `termcast` and `SwiftTermFuzz` executables | A macOS app (`Helge Terminal.app`), installed by Homebrew cask |
| SwiftPM products | `SwiftTerm` (library), `termcast`, `SwiftTermFuzz` (`Package.swift`) | None declared. Targets: `TerminalApp`, `TerminalInterop`, `TerminalLauncher`, `dev`, two test targets (`Package.swift:17`) |
| Sample or host apps | `TerminalApp/MacTerminal`, `TerminalApp/iOSTerminal`, `TerminalApp/WebTerminal` (Xcode projects and a SwiftPM package) | The app is the only host |
| Minimum OS | macOS 11, iOS 14, tvOS 13, visionOS 1 (`Package.swift`, `platforms:`) | macOS 15 (`Package.swift:15`) |
| Other platforms | Linux and Windows exclude `Apple/`, `Mac/`, `iOS/`; WASI and Embedded Swift through package traits (`Package.swift`, `Docs/wasm.md`, `Docs/embedded-swift.md`) | None. Release build targets `arm64-apple-macosx15.0` (`tools/Dev/AppBundle.swift:100`) |
| Dependencies of the library or app | None on Apple platforms. `swift-png` on Linux, Windows, WASI and Android under the `PortableGraphics` trait. `swift-argument-parser` for `termcast` only | Sparkle 2.10.1, pinned exactly (`Package.swift:18`) |
| License | MIT | MIT |
| Swift tools and language mode | Tools 6.2, language mode 6 (`swiftLanguageModes: [.v6]`) | Tools 6.0, language mode 5 on every Swift target (`Package.swift:29`) |
| Size of non-test Swift source | About 75,000 lines under `Sources/SwiftTerm` | About 23,700 lines under `Sources/Terminal` |
| Commits, 30 days to 2026-11-14 | 92 (`gh` commit search) | 521, the whole history; first commit 2026-11-07 |
| Commits, 12 months | 688 (`gh` commit search) | 521 |
| Releases | `v1.99.0` 2026-10-08, `v1.99.1` 10-21, `v1.99.2` 10-29, `v1.99.3` 11-06 | 41 tags; `v0.4.3` on 2026-11-12 |
| Open issues / pull requests | 54 / 43 (`gh` search, 2026-11-14) | 2 open items (`gh api`, issues and pull requests together) |

SwiftTerm's own platform table (`S/Documentation.docc/GettingStarted.md`) says
"macOS 13+" and "iOS 13+". The manifest is the authority and says macOS 11
and iOS 14. No Windows job exists in its CI (`.github/workflows/xcode.yml` has
`linux-headless` only), so a working Windows build is not verified.

## 2. Architecture

### Layering

SwiftTerm keeps everything in one module and separates by directory and
conditional compilation. `S/Terminal.swift` (10,779 lines) is the engine and
knows no UI. `S/Apple/` holds what AppKit and UIKit share, including both
renderers; `S/Mac/` and `S/iOS/` hold the two `TerminalView` classes;
`S/LocalProcess.swift` and `S/Pty.swift` hold the PTY host; `S/Portable/`
holds the snapshot types that a non-Apple host draws from. The engine reports
to its host through the `TerminalDelegate` protocol (`S/Terminal.swift:35`).

Terminal is one app module (`TerminalApp`) with a C target beside it.
`T/Emulation/` holds the emulator (`TerminalEmulator`,
`T/Emulation/TerminalEmulator.swift:59`), the document (`TerminalDocument`,
`T/Emulation/TerminalDocument.swift:996`) and reflow; `T/Text/` holds UTF-8
decoding, width and segmentation; `T/IO/` holds the PTY read path;
`T/Session.swift` (`Session`, line 200) owns the child and the ordering;
`T/Canvas.swift` (`TerminalCanvasView`, line 4) is the view;
`T/Renderer.swift` (`TerminalRendering`, line 56) draws. The emulator has no
delegate: it accumulates replies and clipboard requests, and the session
drains them (`takeReplies`, `takeClipboardRequests`).

### Threads and ownership

| | SwiftTerm | Terminal |
| --- | --- | --- |
| Who may touch terminal state | Any thread that holds `Terminal.terminalLock`, a non-recursive, FIFO-fair lock (`S/TerminalLock.swift:34`) | Only the session's serial queue, `no.helgesverre.terminal.owner` (`Session.queue`, `T/Session.swift:256`) |
| PTY reading | Two dedicated threads per process: a gather thread fills a ring of four 64 KiB buffers, a parse thread delivers them (`S/TerminalIOPipeline.swift`, header and `bufferCount`) | One serial Dispatch lane shared by all panes reads into 64 KiB slabs; `PTYReadBroker` orders deliveries to each owner (`T/IO/PTYReadEndpoint.swift:6`, `T/IO/PTYReadBroker.swift:14`) |
| Backpressure | The parse thread blocks in the delegate; "Blocking here IS the backpressure mechanism" (`S/TerminalIOPipeline.swift`, `TerminalIOPipelineDelegate`) | Read credit is held until the parser consumes the bytes; 64 KiB and 256 nodes of read-ahead (`docs/architecture.md`, `PTYReadBroker.init`, `T/IO/PTYReadBroker.swift:50`) |
| Host callbacks | `TerminalDelegate` methods can run on the parse thread with the lock held; a host must not call back into lock-taking API (`S/Documentation.docc/Embedding.md`, `S/TerminalLock.swift` rule 2) | Completions hop to the main actor (`DispatchQueue.main.async` throughout `T/Session.swift`) |
| Rendering thread | A dedicated render thread on the Metal path (`RenderLoop`, `S/Apple/RenderLoop.swift`); lock order is frame lock, then terminal lock | Frames are requested per surface through `CAMetalDisplayLink` (`T/Renderer.swift:118`); glyph rasterization runs on a worker (`T/GlyphRasterWorker.swift`) |

### How output reaches the screen

SwiftTerm: the parse thread takes the terminal lock, parses a batch and marks
changed rows (`S/LineChangeTracker.swift`, `Terminal.getUpdateRange`,
`S/Terminal.swift:8344`). The view's frame driver (`S/Apple/FrameDriver.swift`)
coalesces changes to the display cadence. The renderer takes the lock, copies
what it needs into a snapshot (`S/Apple/TerminalSnapshot.swift`,
`Terminal.makeRenderSnapshot(scope:)`, `S/Terminal.swift:8207`) and draws
outside it. Readers and the parser therefore contend on one lock; the fairness
ticket exists because the parse thread otherwise starves the main thread
(`S/TerminalLock.swift`, type comment).

Terminal: the session feeds bytes to the emulator on its queue, then schedules
one publication 8 ms later (`Session.schedulePublish`, `T/Session.swift:1408`).
Publication builds an immutable `TerminalSnapshot` value
(`TerminalEmulator.snapshotValue`, `T/Emulation/TerminalEmulator.swift:1673`),
and only the latest one is delivered to the main actor (`Session.publish`,
`T/Session.swift:1423`). The view and renderer never read live terminal state,
so there is no lock between parsing and drawing. The cost is a full copy of
the visible rows for every publication.

### Buffer and history

| | SwiftTerm | Terminal |
| --- | --- | --- |
| Cell | 8-byte `PackedCell`; graphemes, styles and payloads in an arena shared by all lines of a terminal (`S/CellStorage.swift`, header) | 8-byte `TerminalRowSlot`: scalar, index into the row's own style table, flags; clusters and links in a sparse per-row array (`T/Emulation/TerminalDocument.swift:26`) |
| Row | `BufferLine`, a class (`S/BufferLine.swift:15`) | `TerminalRow`, a copy-on-write value with a stable identity and a revision (`T/Emulation/TerminalDocument.swift:337`) |
| Screen and history | One circular list per buffer holds scrollback and screen together (`CircularBufferLineList`, `S/Buffer.swift:800`, `S/CircularList.swift`) | `TerminalHistory` and two `TerminalScreen` values inside `TerminalDocument` (`T/Emulation/TerminalDocument.swift:802`, `:966`) |
| History limit | Rows only: `TerminalOptions.scrollback`, default 500 (`S/TerminalOptions.swift`, `default`); changed with `Terminal.changeScrollback` (`S/Terminal.swift:9073`). No byte limit was found in `S/Buffer.swift` | Rows and bytes: 50,000 rows and 64 MiB by default (`T/Emulation/TerminalEmulator.swift:87`), set through `terminal_set_history_limit` and `terminal_set_history_byte_limit` |
| Reflow on resize | Synchronous, inside `Buffer.resize` (`reflowWider`, `reflowNarrower`, `S/Buffer.swift:1436`, `:1567`) | A resumable transaction that runs in bounded steps, reserves its memory first (96 MiB per operation, 128 MiB per process) and can evict old history under pressure (`DocumentReflowTransaction`, `ReflowReservationLedger`, `T/Emulation/DocumentReflow.swift:27`, `:62`) |
| Viewport while scrolled back | A row offset (`Buffer.yDisp`) | A row identity, remapped through reflow and clamped on eviction (`viewAnchor`, `resolveViewportAnchor`, `T/Emulation/TerminalEmulator.swift:92`, `:1533`) |
| Alternate screen history | None | None (`GLOSSARY.md`, History) |

## 3. Embedding API

### SwiftTerm

A host picks one of four entry points.

| Type | What it is | Evidence |
| --- | --- | --- |
| `Terminal` | The engine. `open class`. Construct with a `TerminalDelegate` and `TerminalOptions`; call `feed(byteArray:)`, `feed(text:)`, `feed(buffer:)`, `resize(cols:rows:)`; receive bytes for the process in `TerminalDelegate.send(source:data:)` | `S/Terminal.swift:391`, `:1173`, `:8008`, `:8951`, `:92` |
| `TerminalView` | `open class TerminalView: NSView` on macOS, `open class TerminalView: UIScrollView` on iOS and visionOS. Owns a `Terminal`, draws it, handles keyboard, IME, mouse, selection and search. The host implements `TerminalViewDelegate` | `S/Mac/MacTerminalView.swift:105`, `S/iOS/iOSTerminalView.swift:109`, `S/Apple/TerminalViewDelegate.swift:14` |
| `LocalProcessTerminalView` | A `TerminalView` subclass that runs a child on a PTY. macOS only | `S/Mac/MacLocalTerminalView.swift:245` |
| `HeadlessTerminal` | A `Terminal` plus a `LocalProcess`, no view. Not on iOS, Windows, WASI or Android | `S/HeadlessTerminal.swift:20` and its `#if` at line 8 |

**Feeding and receiving.** The host calls `TerminalView.feed(byteArray:)` or
`feed(text:)` with process output; both are documented as callable from any
thread except from inside a delegate callback
(`S/Apple/AppleTerminalView.swift:1313`,
`S/Documentation.docc/Embedding.md`). User input arrives in
`TerminalViewDelegate.send(source:data:)`. `TerminalView.feedSender` and
`inputSender` are `Sendable` handles for a transport that must not retain the
view (`TerminalFeedSender`, `TerminalInputSender`,
`S/Apple/AppleTerminalView.swift:1294`, `:1234`).

**Reading state.** The 2.0 API no longer exposes the `Terminal` behind a
view; `getTerminal()` is gone (`S/Documentation.docc/MigratingFrom1To2.md`,
confirmed: `terminal` is an internal property at
`S/Mac/MacTerminalView.swift:484`). A host reads copies instead:
`terminalDimensions`, `terminalStateSnapshot()`, `visibleRowsText(_:)`,
`terminalContentSnapshot(region:kind:)`, `getBufferAsData(kind:encoding:)`
(`S/Apple/AppleTerminalView.swift:1767`–`1863`). `HeadlessTerminal.terminal`
stays public because the host owns that terminal.

**Configuration.**

| Concern | API | Evidence |
| --- | --- | --- |
| Size, scrollback, TERM name, cursor style, tab width, BiDi, OSC size limit, graphics limits | `TerminalOptions`, read at start | `S/TerminalOptions.swift:164` |
| Font | `init(frame:font:options:)`, `font`, `lineSpacing`, `fontSmoothing`; any `NSFont` or `UIFont` | `S/Mac/MacTerminalView.swift:559`, `:537`; `S/Apple/AppleTerminalView.swift:1629` |
| Fallback glyphs (Nerd Font icons) | `glyphFallbackProvider`, a host-supplied `TerminalGlyphFallbackProvider` with per-codepoint placement | `S/Apple/GlyphFallback.swift:88`, `S/Mac/MacTerminalView.swift:1489` |
| Colors | `installColors(_:)` for the 16 base colors, `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor`, `selectedTextBackgroundColor`, `linkColor`, `backgroundOpacity`, `minimumContrastRatio`, `useBrightColors` | `S/Apple/AppleTerminalView.swift:2548`, `S/Mac/MacTerminalView.swift:1357`–`1768` |
| Keys | `optionAsMetaKey`, `backspaceSendsControlH`, `shouldSendCommandKeyToTerminal`, `pressAndHoldShowsAccentMenu`; `TerminalKeyboardRouter` is public for a host with its own view | `S/Mac/MacTerminalView.swift:2209`, `:1278`, `:4144`; `S/Mac/MacKeyboardRouter.swift:145` |
| Mouse and links | `allowMouseReporting`, `linkReporting`, `linkHighlightMode`, `sendMouseEvent` | `S/Mac/MacTerminalView.swift:1736`–`1743` |
| Renderer | `setUseMetal(_:)`, `metalBufferingMode` | `S/Mac/MacTerminalView.swift:639`, `:370` |
| Custom protocol handling | `Terminal.registerOscHandler(code:handler:)`, `observeOscEvents(codes:_:)` | `S/Terminal.swift:1852`, `:1873` |
| Subclassing | `TerminalView` and `LocalProcessTerminalView` are `open`, with `open` overrides for mouse, IME, copy and paste | `S/Mac/MacTerminalView.swift:2269`–`3349` |

**Drawing somewhere else.** A host with its own renderer takes
`Terminal.makeRenderSnapshot(scope:)`, an owned value with dirty or full rows
(`TerminalRenderSnapshot`, `S/Portable/TerminalRenderSnapshot.swift:65`). A
host whose terminal lives in another process builds rows with
`TerminalRowStore` and feeds the Apple renderers through
`TerminalExternalFrameSource` (`S/TerminalRowStore.swift:24`,
`S/Apple/TerminalExternalFrame.swift:129`). The WebAssembly build exports a
versioned ABI on top of the same snapshots (`Sources/SwiftTermWebWasm/`).

**SwiftUI.** There is no public SwiftUI view. `SwiftUITerminalView` is
internal, UIKit-only and compiled in debug builds only; its comment points to
the separate SwiftTermApp project "for a proper binding"
(`S/iOS/SwiftUITerminalView.swift:2`–`8`). A SwiftUI host writes its own
`NSViewRepresentable` or `UIViewRepresentable`.

**A minimal embedding**, from `S/Documentation.docc/GettingStarted.md`,
checked against the declarations cited above:

```swift
import AppKit
import SwiftTerm

final class ViewController: NSViewController, LocalProcessTerminalViewDelegate {
    var terminalView: LocalProcessTerminalView!

    override func viewDidLoad() {
        super.viewDidLoad()
        terminalView = LocalProcessTerminalView(frame: view.bounds)
        terminalView.processDelegate = self
        terminalView.autoresizingMask = [.width, .height]
        view.addSubview(terminalView)
        terminalView.startProcess(executable: "/bin/zsh", execName: "-zsh")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        view.window?.title = title
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}
```

For a custom transport (SSH, a socket) the host uses `TerminalView`, forwards
`send(source:data:)` to the transport and calls `feed(byteArray:)` with what
comes back. SwiftTerm ships no SSH client; the iOS sample uses swift-nio-ssh
(`README.md`, Using SSH).

### Terminal

Nothing is public. The search for `public` and `open` in `Sources/Terminal`
finds four occurrences, all in comments. What exists is internal:

| Piece | What it is | Evidence |
| --- | --- | --- |
| C interface | 35 functions, 33 of them on an opaque `Terminal *`: create, destroy, feed, resize, three snapshot forms (JSON, borrowed cell views, view-relative), scroll, replies, OSC 52 requests, key input, search tasks, history limits, image pixels, spawn | `T/Interop/Bridge.h` |
| Its implementation | 33 `@_cdecl` functions that unwrap the pointer to the `private final class TerminalEmulator`; the two spawn functions are C (`T/Interop/Spawn.c`) | `T/Emulation/TerminalEmulator.swift:2104`–`2186` |
| Swift side doors | The app does not go through C for snapshots, selection, link validation or resize. It calls `swiftTerminalSnapshot` and the `TerminalSelectionBridge`, `TerminalPresentedContentBridge` and `TerminalResizeBridge` enums with the same opaque pointer | `T/Emulation/TerminalEmulator.swift:2070`–`2095` |
| `Session` | Owns the child, the PTY, the emulator handle and the ordering of input, output, resize, selection, search and clipboard decisions. Publishes snapshots through `onSnapshot` | `T/Session.swift:200` |
| `TerminalCanvasView` | An `NSView` with `NSTextInputClient`, mouse, selection, drag and drop, find bar and the accessibility text interface. It reads `TerminalPreferences` and `TerminalTheme` directly | `T/Canvas.swift:4` |
| `TerminalRendering` | One shared Metal service; each view attaches a `CAMetalLayer` and receives a surface lease | `T/Renderer.swift:56`, `attach` at `:274` |

The C interface reports `terminal_abi_version() == 1` and
`docs/decisions.md` calls it versioned, but it is not a host API in its
current form:

- It has no way to subscribe to changes. A caller polls
  `terminal_snapshot_binary` and `terminal_replies`.
- `terminal_feed` returns the bytes consumed and may stop early (at 64 KiB,
  when 32 KiB of replies are pending, or to resume a REP), so the caller owns
  a retry loop (`TerminalEmulator.feed`,
  `T/Emulation/TerminalEmulator.swift:461`).
- Time is an argument (`now`, in milliseconds); the emulator has no clock.
- Selection, link activation and resumable resize are not in the header at
  all.
- `terminal_spawn_args` needs the path of the bundled launcher executable.
- The header's type is named `Terminal`, which collides with SwiftTerm's
  class name in any target that imports both.

Fonts, colors and key policy are not parameters. The font is the bundled
Obel Mono (`TerminalFont.family`, `T/Font.swift:7`); colors come from
`TerminalTheme` (`T/Theme.swift`); the session's configuration has three
fields: history rows, follow-tail-on-input and the word-selection profile
(`TerminalSessionConfiguration`, `T/Preferences.swift:225`).

## 4. Emulation coverage

Terminal's evidence is in `T/Emulation/TerminalEmulator.swift` unless another
file is named; the function is given with its line. SwiftTerm's evidence is in
`S/Terminal.swift` unless another file is named.

### Screen, cursor and modes

| Feature | SwiftTerm | Terminal |
| --- | --- | --- |
| C0 controls, cursor movement, erase, insert and delete, REP | yes (`cmdCursorUp` … `cmdRepeatPrecedingCharacter`, `:4484`–`:7553`) | yes (`handleCSI`, `:894`; REP is resumable, `feed`, `:465`) |
| Alternate screen 47, 1047, 1049 | yes (`cmdSetMode`, `:7347`–`:7355`); 1048 too | yes (`setMode`, `:1244`); 1048 no |
| Scroll region DECSTBM | yes (`cmdSetScrollRegion`, `:5763`) | yes (`setVerticalMargins`, `:1041`) |
| Origin mode DECOM | yes (`:6206`) | yes (`setMode`, `:1239`) |
| Left and right margins DECLRMM, DECSLRM | yes (`cmdSetMargins`, `:5721`; mode 69, `:6242`) | yes (`setMode` case 69, `:1265`; `setHorizontalMargins`, `:1068`) |
| Tab stops HTS, TBC, CHT, CBT | yes (`cmdTabSet`, `:4454`; `cmdTabClear`, `:7381`) | yes (`handleEscapedByte` 0x48, `:681`; `handleCSI` 0x67, `:946`; `tab`, `:750`) |
| DEC Special Graphics, SO and SI | yes (`S/CharSets.swift`) | yes (`decSpecialGraphics`, `:9`; `:504`) |
| National character sets, G2 and G3 | yes (`S/CharSets.swift`; designators at `:5056`) | no: only `ESC (` and `ESC )` with `0` or `B` (`feed`, `:524`) |
| Double-width and double-height lines | yes (`cmdDoubleWidthSingleHeight`, `:5118`) | no: `ESC #` implements DECALN only (`:531`) |
| Rectangular operations DECERA, DECSERA, DECRQCRA | yes (`:5353`–`:5435`); DECRQCRA answers zero in release builds unless enabled | no |
| Selective erase DECSCA, DECSED | yes (`cmdSelectCharacterProtection`, `:5813`) | yes (`handleCSI` 0x71, `:986`; `eraseDisplay(selective:)`, `:1021`) |
| DECCOLM 132 columns | yes (`:6200`) | no |
| Soft reset DECSTR, hard reset RIS | yes (`cmdSoftReset`, `:6393`; `cmdReset`, `:8902`) | yes (`softReset`, `:1277`; `reset`, `:771`) |
| Cursor style DECSCUSR | yes (`cmdSetCursorStyle`, `:5830`) | yes (`handleCSI` 0x71 with space, `:987`) |
| Synchronized output 2026 | yes; 1,000 ms timeout (`:9143`) | yes; 150 ms timeout (`setMode`, `:1270`) |
| Bracketed paste 2004 | yes (`:6102`) | yes (`setMode`, `:1263`) |
| Focus reporting 1004 | yes (`:6256`) | yes (`setMode`, `:1260`) |
| Bell | yes (`TerminalDelegate.bell`, `:108`; `BellStyle`, `S/Apple/BellStyle.swift`) | no: BEL is consumed and ignored (`feed`, `:499`) |

### Reports

| Feature | SwiftTerm | Terminal |
| --- | --- | --- |
| DA1 | yes: `?65;4;1;2;6;21;22;17;28c` for an `xterm` name (`cmdSendDeviceAttributes`, `:7489`) | yes: `?62;22c` (`handleCSI`, `:980`) |
| DA2 | yes: `>65;20;1c` (`:7500`) | yes: `>1;10;0c` (`:977`) |
| DSR 5 and 6, DECXCPR | yes (`cmdDeviceStatus`, `:6465`) | yes (`handleCSI` 0x6e, `:974`) |
| DECRQM | yes, including permanently set and reset states (`cmdDecRqm`, `:6174`) | yes for the modes it implements, 0 otherwise (`modeReport`, `:1200`) |
| DECRQSS | yes (`class DECRQSS`, `:1753`) | no: DCS strings are discarded (`handleEscapedByte`, `:673`; `BUGS.md`) |
| XTGETTCAP | yes, from a generated terminfo table (`class XTGETTCAP`, `:1629`; `Sources/SwiftTermBuildInfoGenerator/XtgettcapTableGenerator.swift`) | no (`BUGS.md`) |
| XTVERSION | yes (`cmdXTVERSION`, `:5856`) | no (`implementsCSI`, `:886`; `BUGS.md`) |
| Window operations XTWINOPS, sizes in cells and pixels | yes (`cmdWindowOptions`, `:5590`) | no: CSI `t` is not handled (`BUGS.md`) |
| Title stack, CSI 22 and 23 t | yes (`:5669`–`:5692`) | no |
| In-band size reports 2048, color scheme reports 2031 | yes (`S/DECPrivateModes.swift`) | no |

### Color and attributes

| Feature | SwiftTerm | Terminal |
| --- | --- | --- |
| 16, 256 and 24-bit color | yes (`cmdCharAttributes`, `:6626`) | yes (`applySGR`, `:1146`, cases 38 and 48 at `:1178`) |
| Colon-separated SGR | yes (`:6788`) | yes (`applySGR(_:colonSyntax:)`, `:1077`) |
| Bold, faint, italic, inverse, conceal, strike, overline | yes | yes (`applySGR`, `:1154`–`:1162`; faint at `T/CellPalette.swift:31`) |
| Blink | yes (`S/Mac/MacCaretView.swift:68`) | partial: stored, never animated (`docs/terminfo.md`) |
| Underline styles: double, curly, dotted, dashed | yes (`UnderlineStyle`, `S/CharData.swift:55`) | partial: parsed and stored (`:1110`, `:1163`); every style draws as one 1-pixel line (`TerminalRendering.draw`, `T/Renderer.swift:801`) |
| Underline color, SGR 58 and 59 | yes (`:6869`) | yes (`:1178`, `:1193`; `CellPalette.Colors.underline`) |
| OSC 4 set and query, OSC 104 | yes (`oscChangeOrQueryColorIndex`, `:4284`) | yes (`TerminalPalette.applyOSC`, `T/Emulation/TerminalPalette.swift:48`) |
| OSC 10 and 11 set and query | yes (`oscSetColors`, `:4361`) | yes (`T/Emulation/TerminalPalette.swift:69`) |
| OSC 12 cursor color, OSC 110, 111, 112 | yes (`dispatchOsc`, `S/EscapeSequenceParser.swift:816`–`:821`) | no (`finishString`, `:1309`, accepts 4, 10, 11 and 104 only) |

### OSC and host integration

| Feature | SwiftTerm | Terminal |
| --- | --- | --- |
| OSC 0 and 2 title | yes; OSC 1 icon title too (`S/EscapeSequenceParser.swift:804`) | yes (`finishString`, `:1299`); OSC 1 no |
| OSC 7 working directory | yes (`oscSetCurrentDirectory`, `:3768`); OSC 6 document too | yes (`:1300`) |
| OSC 8 hyperlinks | yes, with `id` and other parameters (`oscHyperlink`, `:4006`) | partial: the URI is kept, parameters are dropped (`:1303`) |
| OSC 52 clipboard | yes: write and read, both decided by the delegate (`oscClipboard`, `:4032`) | partial: write only, with a streaming decoder and a 1 MiB cap; a read gets an empty reply (`OSC52Decoder`, `T/Emulation/ClipboardProtocol.swift:7`; `feed`, `:589`) |
| Kitty clipboard protocol, OSC 5522 | yes, off until the host opts in (`S/KittyClipboardProtocol.swift`) | no |
| OSC 133 prompt marks | yes: marks, per-cell semantic content, prompt navigation, click-to-move (`oscSemanticPrompt`, `:3634`; `S/SemanticPrompt.swift`) | partial: A, B, C and D set a prompt phase and anchor, used for Cmd-K and for clearing the prompt on reflow; no mark history or navigation (`:1312`) |
| OSC 9 notification | partial: `9;4` progress only (`oscProgressReport`, `:4132`); other OSC 9 payloads reach a host only through `observeOscEvents` | no |
| OSC 777 notification | yes (`oscNotification`, `:4115`) | no |
| OSC 1337 iTerm2 | yes: inline images and capability report (`osciTerm2`, `:4190`) | no |

### Input

| Feature | SwiftTerm | Terminal |
| --- | --- | --- |
| Mouse X10 (9), 1000, 1002, 1003 | yes (`cmdSetMode`, `:7293`–`:7314`) | yes (`setMode`, `:1261`; `TerminalCanvasView.reportMouse`, `T/Canvas.swift:773`) |
| SGR mouse 1006 | yes | yes (`:1262`) |
| UTF-8 1005 and urxvt 1015 mouse | yes (`:6258`, `:6264`) | no |
| SGR pixel mouse 1016 | yes (`:6266`; `sendEvent(…pixelX:pixelY:)`, `:9368`) | no |
| Alternate scroll 1007 | yes (`:6262`) | no |
| Kitty keyboard protocol | yes: all five flags, push, pop, set, query (`KittyKeyboardFlags`, `S/KittyKeyboardProtocol.swift:12`; `S/KittyKeyboardEncoder.swift`) | yes: all five flags, a 32-entry stack per screen, set, query (`handleCSI` 0x75, `:958`; `TerminalInputEncoder`, `T/Emulation/TerminalInputEncoder.swift:6`) |
| xterm modifyOtherKeys | no (`// TODO: XTMODKEYS`, `:6616`) | no (`handleCSI` comment, `:899`) |
| Application cursor and keypad | yes | yes (`setMode`, `:1238`; `handleEscapedByte`, `:688`) |

### Graphics

| Feature | SwiftTerm | Terminal |
| --- | --- | --- |
| Kitty graphics | yes: direct, file, temporary-file and shared-memory transmission (the last three off by default), animation, Unicode placeholders, relative placements (`S/KittyGraphics.swift`, `S/KittyPlaceholder.swift`, `KittyGraphicsConfiguration`, `S/TerminalOptions.swift:94`) | partial: direct transmission of RGB, RGBA and PNG, zlib, chunks, placement, cropping, z-order, delete, query. Files, shared memory, image numbers, relative and Unicode placements and animation answer `ENOTSUP` (`KittyGraphicsStore`, `T/Emulation/KittyGraphics.swift:54`, `:198`–`:206`) |
| Kitty graphics limits | Storage limit per screen (`storageLimitBytesPerScreen`) | 16 MiB per image, 64 MiB total, 64 images, 256 placements, 4,096 pixels per side (`T/Emulation/KittyGraphics.swift:55`–`:59`) |
| Sixel | yes (`S/SixelDcsHandler.swift`) | no (DA1 comment, `:978`) |
| iTerm2 inline images | yes (`osciTerm2`, `:4190`) | no |

### Unicode

| Feature | SwiftTerm | Terminal |
| --- | --- | --- |
| Width tables | Unicode 18.0.0, generated from the UCD (`S/UnicodeWidthData.swift`, header; `scripts/regen_unicode_width_data.py`) | Unicode 18.0.0, generated from `unicode-width` 0.2.3 (`TerminalWidth`, `T/Text/TerminalWidth.swift:13`) |
| Grapheme clustering | yes, always on (`UnicodeUtil.graphemeJoin`, `S/Utilities.swift:504`) | yes, always on; UAX 29 revision 49 with InCB (`T/Text/TerminalText.swift:12`, `T/Text/Unicode18GraphemeTables.swift`) |
| Mode 2027 | partial: DECRQM reports it permanently set; DECSET and DECRST do nothing (`:6110`, `:6156`) | no: DECRQM answers 0 (`modeReport`, `:1222`) |
| Emoji, ZWJ sequences, variation selectors | yes (`S/Utilities.swift:504`; `Tests/SwiftTermTests/UnicodeTests.swift`) | yes (ZWJ rule at `T/Text/TerminalText.swift:76`; emoji presentation at `T/Text/TerminalWidth.swift:52`) |
| Regional indicator width | Configurable, wide by default (`TerminalOptions.regionalIndicatorWidth`) | Fixed by the width tables |
| Combining marks | yes | yes; a lone mark is drawn on a dotted circle (`T/Renderer.swift:765`) |
| Bidirectional text | yes: terminal-wg BiDi modes, Arabic shaping, mirroring (`S/Bidi.swift`, `S/Apple/TerminalBidi.swift`) | no |
| Wide characters across reflow | yes from source (`S/Buffer.swift:1321`, `:1512`; `Tests/SwiftTermTests/ReflowWideRowsAtTopTests.swift`) | yes from source: a wrap spacer cell marks a wide glyph that moved to the next row (`T/Emulation/TerminalDocument.swift:13`; `T/Emulation/DocumentReflow.swift:439`) |

## 5. Rendering

| | SwiftTerm | Terminal |
| --- | --- | --- |
| Drawing | CoreGraphics by default; Metal after `setUseMetal(true)` (`useMetalRenderer = false`, `S/Mac/MacTerminalView.swift:353`) | Metal only (`makeBackingLayer` returns `CAMetalLayer`, `T/Canvas.swift:92`) |
| Rasterization | CoreText (`S/Apple/Metal/CoreTextGlyphRasterizer.swift`) | CoreText (`TerminalFont.rasterize`, `T/Font.swift:47`) |
| Glyph cache | Two atlas textures, grayscale and color, with eviction (`S/Apple/Metal/GlyphAtlas.swift`; `S/Documentation.docc/GPURendering.md`) | Up to two 2,048-pixel RGBA atlas pages per renderer, then direct glyph textures, under one 64 MiB budget shared by all panes (`T/Renderer.swift:235`; `GlyphResidency.init`, `T/GlyphResidency.swift:102`) |
| When the cache is exhausted | not verified | A visible outline replaces the glyph; the cell is never blank (`T/Renderer.swift:787`) |
| Shaping and ligatures | Rows are shaped by CoreText and glyphs are mapped back to cells by source index, so a ligature spans its cells (`S/Apple/AppleTerminalView.swift:3764`). The Metal path skips shaping only for fonts whose tables prove ASCII cannot be reshaped (`S/Apple/Metal/PlainTextFont.swift`) | None: one glyph key per cell, `.ligature: 0` (`T/Font.swift:58`); listed as remaining work in `docs/status.md` |
| Font | Any `NSFont` or `UIFont` the host passes | Bundled Obel Mono in four faces (`T/Font.swift:11`) |
| Font fallback | `CTFontCreateForString` per character (`S/Apple/SnapshotTextBuilder.swift:173`), plus a host-supplied provider for symbols | A cascade list with the bundled Symbols Nerd Font Mono, then CoreText's own fallback (`T/Font.swift:36`) |
| Bundled fonts | None | Obel Mono, Symbols Nerd Font Mono 3.5.1 |
| Box drawing and blocks | Drawn as geometry (`S/Apple/BoxDrawingRenderer.swift`, `BlockElementRenderer.swift`, `PowerlineRenderer.swift`); switchable with `customBlockGlyphs` | Blocks, shades, quadrants and the common box characters drawn as rectangles (`GeometricGlyph.rectangles`, `T/Geometry.swift:12`); the rest come from the font |
| Nerd Font icons | Host supplies the font and placement policy (`TerminalGlyphPlacementPolicy`, `S/Apple/GlyphFallback.swift:36`) | Scaled and centered from the bundled symbols font (`T/Font.swift:50`–`:71`) |
| Cursor | Six styles with blink (`CursorStyle`, `S/TerminalOptions.swift:15`; `S/Mac/MacCaretView.swift`) | Block, underline and bar; no blink (`T/Renderer.swift:828`) |
| Damage tracking | Per-row change tracking; the default Metal mode rebuilds only dirty rows (`S/LineChangeTracker.swift`; `MetalBufferingMode.perRowPersistent`) | None in the renderer: every frame rebuilds the quads for all visible cells (`TerminalRendering.draw`, `T/Renderer.swift:643`). Rows carry a revision that a cache could use |
| Idle | not verified | Demand-only: no frame without a request (`TerminalRendering.request`, `T/Renderer.swift:318`) |
| Under an output flood | Render signals coalesce into one pending frame (`RenderLoop`, `S/Apple/RenderLoop.swift`); the parse thread yields the lock in FIFO order | At most one publication per 8 ms; only the newest snapshot is delivered and drawn (`T/Session.swift:1411`, `:1445`) |
| Transparency | `backgroundOpacity`, `translucentCellBackgrounds` (`S/Mac/MacTerminalView.swift:1403`) | no |

Published numbers, not reproduced here. SwiftTerm's `PERFORMANCE.md` reports
RenderBench at 168 MB/s on Metal and 160 MB/s on CoreGraphics after one fix,
and a Darwin PTY ceiling of "about 290 MiB/s" against about 1,050 MiB/s for
the same workload fed headlessly. Terminal's `docs/status.md` reports
whole-app throughput of 241, 283, 205 and 142 MiB/s on short ASCII, long
ASCII, truecolor and mixed Unicode. The workloads, machines and methods
differ, so the two sets cannot be compared with each other.

## 6. Interaction

| | SwiftTerm | Terminal |
| --- | --- | --- |
| Selection: character, word, line | yes (`SelectionService.SelectionMode`, `S/SelectionService.swift:722`) | yes (`TerminalSelectionGranularity`, `T/Emulation/TerminalSnapshot.swift:68`; `T/Canvas.swift:745`) |
| Rectangular selection | yes, Option-drag (`isBlock`, `S/SelectionService.swift:422`; `S/Mac/MacTerminalView.swift:2998`) | yes, Option-drag (`T/Canvas.swift:744`) |
| Selection and changing content | Detects whether the selected rows changed (`selectedContentIsUnchanged`, `S/SelectionService.swift:227`) | Endpoints are row identities; selection survives scrolling and reflow, and clears when its cells are overwritten or evicted (`TerminalSelection`, `T/Emulation/TerminalSelection.swift:28`; `TerminalSelectionReflowTracker`) |
| Copy size | not verified | 16 MiB result limit, built in bounded steps (`T/Emulation/TerminalSelection.swift:32`) |
| Search | Case-sensitive, regular-expression and whole-word options (`SearchOptions`, `S/SearchOptions.swift:12`); `findNext`, `findPrevious`, `searchMatchSummary` (`S/TerminalViewSearch.swift`); a find bar on macOS (`S/Mac/MacFindBarView.swift`) | Literal, case-insensitive only; runs on a worker over immutable pages, cancellable, 10,000 matches at most (`TerminalSearchTask`, `T/Emulation/HistorySearch.swift:171`); a find bar (`T/FindBar.swift:15`) |
| Link detection | OSC 8 plus detected URLs and file paths; `TerminalLinkRequest` with safety checks before opening (`S/Apple/TerminalLinkRequest.swift`, `S/Mac/UntrustedTerminalLink.swift`) | OSC 8 plus `http`, `https` and `mailto` in visible text; activation is validated against the presented rows on the owner queue (`VisibleLinkProjection`, `T/VisibleLinkProjection.swift:9`, `:281`) |
| IME | `NSTextInputClient` on macOS (`S/Mac/MacTerminalView.swift:4166`), `UITextInput` on iOS (`S/iOS/iOSTextInput.swift:72`), a Hangul composer (`S/HangulInput.swift`) | `NSTextInputClient` (`T/Canvas.swift:4`, `:613`–`:688`). Real CJK input methods are untested (`docs/status.md`) |
| Accessibility, macOS | no: `AccessibilityService` is an empty stub and the view overrides no accessibility method (`S/Mac/MacAccessibilityService.swift`) | yes: text-area role, character, line and range queries, attributed strings, frames, selection, link children (`T/Canvas.swift:112`, `:191`–`:284`; `T/AccessibilityProjection.swift`). VoiceOver itself is untested (`docs/status.md`) |
| Accessibility, iOS | yes: `UIAccessibilityReadingContent` (`S/iOS/iOSTerminalView.swift:3999`) | not applicable |
| Drag and drop | no on either platform | yes: file URLs, shell-quoted, and strings, sent as a paste (`T/Canvas.swift:110`, `:917`) |
| Context menu | No menu on macOS (`rightMouseDown` defers to `super`, `S/Mac/MacTerminalView.swift:3049`); the edit menu on iOS | Copy and Paste (`T/Canvas.swift:762`) |
| Scrolling | An `NSScroller` with a style option (`scrollerStyle`), `scrollSensitivity`; `UIScrollView` on iOS | No scroller. Trackpad travel is accumulated to whole lines (`ScrollAccumulator`, `T/ScrollAccumulator.swift:11`); the viewport is pinned to a row while output arrives |
| Paste safety | `pasteText`, bracketed paste, a configurable set of control bytes to strip (`TerminalPasteControls`, `S/TerminalPaste.swift`) | Bracketed paste with cancellation that closes the bracket (`Session.cancelPaste`, `T/Session.swift:1392`) |
| AppleScript | no | yes (`T/Automation.swift`, `Resources/Terminal/Terminal.sdef`) |

## 7. Process handling

| | SwiftTerm | Terminal |
| --- | --- | --- |
| Spawn | `forkpty`, then `chdir` and `execve` in the child (`PseudoTerminalHelpers.fork`, `S/Pty.swift:112`) | `openpty`, then `posix_spawn` of a bundled launcher with `POSIX_SPAWN_CLOEXEC_DEFAULT`; the launcher calls `login_tty`, `chdir` and `execv` (`terminal_spawn_args`, `T/Interop/Spawn.c:106`; `Sources/TerminalLauncher/Launcher.c`) |
| Extra executable needed | no | yes: `Contents/MacOS/TerminalLauncher` (`LaunchSpec.shell`, `T/Session.swift:128`) |
| Launch failure reporting | `LocalProcessError` for busy and fork failure; an `exec` failure appears as exit code 127 (`startProcessChecked`, `S/LocalProcess.swift:554`) | A stage number and `errno` cross a status pipe for each of five stages (`fail`, `Sources/TerminalLauncher/Launcher.c`) |
| Signal state in the child | Dispositions reset and mask cleared before `execve` (`S/Pty.swift:118`–`:131`) | Same, in the launcher |
| Environment | `TERM=xterm-256color`, `COLORTERM=truecolor`, `LANG=en_US.UTF-8`, and `LOGNAME`, `USER`, `DISPLAY`, `LC_TYPE`, `HOME` copied; `PATH` is not copied (`Terminal.getEnvironmentVariables`, `S/Terminal.swift:9602`). The host can pass its own | The parent's environment, minus variables that name another terminal; `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=HelgeTerminal`, a version, and a validated UTF-8 `LANG` when none is set (`make_environment`, `T/Interop/Spawn.c:67`) |
| Terminfo | A source entry in `swifterm-terminfo/`; the XTGETTCAP table is generated from it | A standalone entry, compiled into the bundle and checked by tests, but not the default `TERM` (`Resources/Terminal/Terminal.terminfo`, `docs/terminfo.md`) |
| Login shell | The host's choice: `execName` sets `argv[0]`, and the sample passes `-zsh` (`TerminalApp/MacTerminal/ViewController.swift:257`). The default executable is `/bin/bash` | `$SHELL -l` (`T/Session.swift:131`) |
| Shell integration | None bundled | A zsh `ZDOTDIR` shim adds OSC 133 hooks for plain interactive zsh (`T/Interop/Spawn.c:75`; `Resources/Terminal/ShellIntegration/zsh`) |
| Sandbox | `LocalProcessTerminalView` needs the App Sandbox off (`S/Mac/MacLocalTerminalView.swift:227`); `LocalProcess` is not compiled for iOS | Not sandboxed (`Resources/Terminal/Terminal.entitlements` has no sandbox key) |
| Child exit | A `DispatchSourceProcess` and a dedicated waiter thread (`S/LocalProcess.swift:656`, `:458`); output is drained with a timeout (`drainTimeout`) | A `DispatchSourceProcess` on the session queue (`T/Session.swift:724`); EOF and exit are independent, and output is drained before the session ends (`docs/decisions.md`, Launch) |
| Termination | `SIGTERM`, then `SIGKILL` after `killEscalationDelay` on deinit (`S/LocalProcess.swift:440`) | `SIGHUP`, then `SIGKILL` after 2 s (`Session.close`, `T/Session.swift:1517`) |
| Resize | `TIOCSWINSZ` (`PseudoTerminalHelpers.setWinSize`, `S/Pty.swift:151`) | `TIOCSWINSZ` after the emulator commits the new geometry, under a descriptor lease (`T/Session.swift:927`) |
| Descriptor lifetime | The pipeline keeps the PTY open until its last callback returns (`drainAvailableAndShutdown` comment, `S/TerminalIOPipeline.swift`) | `PTYDescriptorLifetime` leases the descriptor to reads, writes and ioctls; close waits for them (`T/IO/PTYDescriptorLifetime.swift:6`) |
| Recording | `termcast` records and plays asciinema files (`Sources/Termcast/`) | no |

## 8. Testing and conformance

| | SwiftTerm | Terminal |
| --- | --- | --- |
| Suites | 192 files in `Tests/SwiftTermTests`, 181 using Swift Testing and 11 XCTest; about 2,250 lines declare a test (a `rg` count of `@Test` and `func test`, approximate) | 52 Swift files in `Tests/TerminalTests` and 23 in `Tests/DevTests`, all Swift Testing; 414 `@Test` declarations |
| esctest | yes: a pinned esctest2 commit; 474 lines in `Tests/SwiftTermTests/Fixtures/esctest-known-good.txt` gate CI, and the full run is reported without gating (`Makefile`, `.github/workflows/xcode.yml`, job `esctest`). The pass count was not run here | no |
| vttest | Listed as a resource in `README.md`; no automated use was found | no |
| Fuzzing | A libFuzzer target (`Sources/SwiftTermFuzz`) and a replay of imported Ghostty corpora; `Docs/fuzzing.md` gives 4,001 inputs | None in the tree. `reports/direct-text-path-2026-11-10/README.md` describes a differential fuzzer (`tools/DifferentialFuzz.swift`) that was used then and has been removed |
| Tests ported from other emulators | xterm.js and Ghostty (`README.md`); a parity matrix maps 268 Ghostty Kitty-graphics tests (`S/Documentation.docc/KittyGraphicsParityMatrix.md`) | no |
| Differential or oracle tests | no | The C snapshot path is kept as an oracle for the direct Swift path (`Tests/TerminalTests/BinarySnapshotOracle.swift`, `SnapshotBridgeTests.swift`); fixtures from the archived Rust core (`Tests/TerminalTests/differential-fixtures.json`, `docs/differential-replay.md`) |
| Unicode conformance | A CI step checks that the generated tables match the UCD | The official 853-case grapheme break corpus is a required test (`Tests/TerminalTests/Unicode18CorpusTests.swift`, `docs/unicode18-generation.md`) |
| Real programs | no | fish, Neovim, tmux and fzf in the test run (`.github/workflows/ci.yml`); real-PTY session tests; GUI smoke runs outside CI |
| Sanitizers | Thread Sanitizer on the locking, synchronized-output and pipeline suites (job `thread-sanitizer`) | no |
| CI | macOS (Xcode 27.1): app builds, package build, tests, coverage, strict concurrency; Linux headless; WASI and browser; DocC | macOS 15 runner: `just test`, then bundle verification |
| Terminfo check | `Tests/SwiftTermTests/TerminfoCompatibilityTests.swift` | Exact `tput` expansions replayed through the parser (`Tests/DevTests/TerminfoSmokeTests.swift`, `docs/terminfo.md`) |

## 9. What this means for a library built from Terminal

### Strengths to lead with

- **No lock in the host's way.** State lives on one queue and leaves it as
  immutable snapshots. SwiftTerm's host must know which callbacks hold the
  terminal lock and which calls take it (`S/Documentation.docc/Embedding.md`
  has a section for each). A library with Terminal's model can promise that
  every callback arrives on the main actor and that no API deadlocks.
- **Bounded work.** Reflow, selection, copy, search and REP run in steps with
  stated limits, and reflow reserves its memory before it starts. SwiftTerm's
  reflow is one synchronous call under the lock.
- **History by bytes.** A host can cap scrollback at a memory figure, not only
  a row count.
- **Stable identities.** Rows carry an identity and a revision. Viewport,
  selection, search matches and link activation are expressed against them, so
  they survive output, reflow and eviction or fail explicitly.
- **macOS accessibility.** Terminal exposes its text to assistive clients;
  SwiftTerm's macOS view does not.
- **Shared glyph budget.** A host with many terminals gets one bounded glyph
  memory figure for the process.
- **Launch diagnostics and environment hygiene.** The launcher reports which
  step failed, and children do not inherit another terminal's identity.

### Gaps to close before it could replace SwiftTerm for an embedder

In rough order of how early an embedder meets them:

1. **A public API.** Nothing is public. `TerminalEmulator` is private, and the
   C interface has no notifications, no selection or link calls, and a
   polling, retrying feed. A Swift API needs to be designed, not uncovered.
   The header's `Terminal` type name must change.
2. **A separable engine.** The files under `T/Emulation` and
   `T/Text` import only Foundation, CoreGraphics, ImageIO and Compression,
   which is a good start, but the code compiles as part of the
   app target in Swift 5 mode with exclusivity checks disabled in release
   builds. SwiftTerm is in Swift 6 mode with strict concurrency checked in CI.
3. **A view that takes its configuration from the host.** Font, colors,
   insets, key policy and scrollback are read from `TerminalPreferences`,
   `TerminalTheme` and `TerminalFont` globals. An embedder needs each as a
   parameter, and needs to choose its own font without bundling Obel Mono.
4. **A process host without a helper executable**, or a documented way to
   embed and sign the launcher inside a host's bundle. SwiftTerm's `forkpty`
   path needs nothing extra.
5. **A transport-agnostic session.** `Session` assumes a local child.
   SwiftTerm's `TerminalView` works with any byte source, which is why SSH
   clients use it.
6. **A headless public type** with content snapshots, the equivalent of
   `HeadlessTerminal` and `TerminalContentSnapshot`. `just replay` shows the
   capability exists internally.
7. **Lower deployment target and Intel.** macOS 15 and arm64 exclude hosts
   that SwiftTerm's macOS 11 reaches. `CAMetalDisplayLink` sets the floor at
   macOS 14 unless the frame scheduling changes.
8. **iOS and visionOS.** There is no UIKit view, no `UITextInput`, and the
   spawn path does not apply. This is the largest single piece of work and
   the main reason apps choose SwiftTerm today.
9. **Protocol coverage a host's users will notice:** OSC 52 read with a host
   decision, OSC 12, the title stack, XTVERSION, DECRQSS and XTGETTCAP, bell,
   underline styles drawn as such, cursor blink, pixel mouse reports, and
   notifications (OSC 9 and 777) surfaced to the host.
10. **Text shaping.** No ligatures and no bidirectional text. Hosts that show
    code expect the first; SwiftTerm has both.
11. **Images.** No Sixel and no iTerm2 images, and Kitty graphics without
    file transmission, animation or placeholders.
12. **A CoreGraphics or software fallback.** SwiftTerm draws without Metal by
    default and throws `MetalError` when a GPU is missing. Terminal has no
    second path, and its hosted CI already needs a virtual-GPU policy.
13. **Search options.** Case-sensitive, whole-word and regular-expression
    search.
14. **A SwiftUI wrapper.** SwiftTerm has no public one either, so shipping
    `NSViewRepresentable` and `UIViewRepresentable` types would be a point in
    Terminal's favor rather than a catch-up item.
15. **Conformance evidence.** An esctest run and a fuzzer in the tree. An
    embedder comparing the two today finds 474 gated esctest cases on one
    side and none on the other.

### Things SwiftTerm does that are out of scope

These follow from SwiftTerm being a general engine and need no answer in a
macOS-first library:

- Linux, Windows, WASI and Embedded Swift builds of the engine, and the
  TypeScript package on top of the WebAssembly build.
- tvOS.
- `termcast` recording and playback.
- Rendering a terminal that lives in another process (`TerminalRowStore`,
  `TerminalExternalFrameSource`).
- The Kitty clipboard protocol, OSC 7501 program status, VT52 and
  double-height lines, DECCOLM and the rectangular-area checksum.

Bidirectional text and the non-direct Kitty graphics transports sit between
the two lists: a decision for the library plan, not a finding of this
comparison.

## Not verified

| Item | Why |
| --- | --- |
| SwiftTerm builds and runs on Windows | The manifest handles Windows, but no CI job builds it and nothing was built here |
| SwiftTerm's esctest pass count and vttest results | No test was run; only the 474-line known-good list was read |
| SwiftTerm ligature and BiDi output on screen | The shaping code was read; nothing was rendered |
| SwiftTerm behavior when its glyph atlas fills | The eviction is described in `GPURendering.md`; the code path was not traced |
| SwiftTerm idle CPU and whether it draws without changes | Needs a measurement |
| SwiftTerm copy size limits | Not searched exhaustively |
| SwiftTerm has no byte limit on scrollback | `S/Buffer.swift` shows a row limit only; other files were not searched for one |
| Wide characters across reflow, both projects | Code and tests were read; no case was run |
| VoiceOver with either project, CJK input methods with Terminal | Both need a person; `docs/status.md` lists them as open for Terminal |
| Test counts for SwiftTerm | A text count of declarations, not a test run |
| Every performance figure | Quoted from each project's own documents; none reproduced |
| The SwiftTerm 1.x API | Only `main` (the 2.0 API) was read |
