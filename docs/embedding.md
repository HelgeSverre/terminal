# Embedding the terminal in another app

The repository is a Swift package. Besides the app, it builds three libraries
that another macOS app can use to show a terminal: a view, the session behind
it, and the emulator behind that. [`Examples/Embedding`](../Examples/Embedding)
holds two complete apps that do so, both written in the Swift 6 language
mode:

| Example | Shows |
| --- | --- |
| `EmbeddingExample` | A window with a login shell, an Edit menu and a find bar |
| `ReplayExample` | A window with no process: a `TerminalTransport` plays a file of terminal output into it |

```shell
cd Examples/Embedding
env -u TERMINAL_DEVELOPMENT -u TERMINAL_TEST_HOOKS swift build
.build/debug/EmbeddingExample
.build/debug/ReplayExample            # or with a file of recorded output
```

The public interface follows the [compatibility policy](#compatibility-policy)
below. Pin a reviewed commit for reproducible builds.

## Requirements

| | |
| --- | --- |
| Platform | macOS 14 or later with AppKit, or iOS 17 or later with UIKit (a session there runs over a transport; iOS starts no processes). SwiftUI on both. Apple silicon is what the test suite runs on; the app's releases are universal. On an Intel Mac (MacBookPro16,1, macOS 14.8.7) rendering and a child process on a PTY were checked by hand with cross-compiled builds; the test suite has not run there. |
| Swift tools | 6.0. A host may use the Swift 5 or the Swift 6 language mode; the libraries themselves are compiled in Swift 5 mode. |
| Graphics | A Metal device |
| Sandbox | The app must be allowed to start child processes. A sandboxed app can show the view but cannot usefully run a login shell. |

## Add the package

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/HelgeSverre/terminal", branch: "main"),
],
targets: [
  .executableTarget(
    name: "MyApp",
    dependencies: [
      .product(name: "TerminalUI", package: "terminal"),
      .product(name: "TerminalHost", package: "terminal"),
    ]),
]
```

| Product | Contents |
| --- | --- |
| `TerminalUI` | `TerminalCanvasView`, `TerminalRendering`, `ClipboardAccess`, `TerminalViewConfiguration`, `TerminalEditMenu`. Carries the fonts and the shader source as package resources. |
| `TerminalHost` | `TerminalSession`, `LaunchSpec`, `SessionEnd`, `TerminalSessionConfiguration` |
| `TerminalEngine` | `HeadlessTerminal`: the emulator alone, with no window and no process |
| `TerminalLauncher` | An optional helper executable that starts a session's child, as the app does |

The default manifest contains only the libraries and launcher, with no external
dependencies. This is the same for a local path, a URL dependency and a directory
with any name. `TERMINAL_DEVELOPMENT=1` explicitly adds the app, Sparkle, tools
and tests. `just` enables it and the developer tool sets it for app builds.
Plain `swift build` builds the consumer products; use `just build` for the app.
Do not export the development variable in a consumer's build environment.
Consumer commands should clear it, as the example command above does.

## The emulator on its own

`HeadlessTerminal` takes the bytes a program wrote and gives back the screen
as text and the terminal's replies. It needs no AppKit, no Metal and no
launcher, so it suits tests, recordings, and a host that has its own
transport and does its own drawing.

```swift
import TerminalEngine

let terminal = HeadlessTerminal(columns: 80, rows: 24)!
terminal.feed("\u{1b}[1mhello\u{1b}[0m\r\n")       // or feed(Data)
transport.write(terminal.takeReplies())              // answers to the program's queries
if let screen = terminal.screen() {                  // nil while the program holds the display back
  print(screen.text, screen.cursorRow, screen.cursorColumn, screen.title)
}
terminal.resize(columns: 120, rows: 40)              // reflows
```

An instance is used from one thread at a time. A `Screen` holds:

| Member | Meaning |
| --- | --- |
| `rows`, `text` | One string per row without trailing spaces, and the rows joined by newlines |
| `cells` | Every cell: its text, whether it is the second half of a wide character, foreground and background as `0xRRGGBB` with the palette, reverse video and faint applied, bold, italic, underlined, struck through, concealed, and its hyperlink |
| `cursorRow`, `cursorColumn` | Counted from zero |
| `title`, `isAlternateScreen`, `workingDirectory` | As the program set them |
| `historyRows` | Rows kept above the screen |

`screen(scrolledBack: n)` gives the window `n` rows into the history without
moving the terminal, `setColors(_:)` sets the colors programs are told,
`setGraphemeClustering(_:)` sets the state mode 2027 starts in, and
`encode(_:modifiers:)` gives the bytes a key sends in the terminal's current
modes, for the host to write to its transport.
The headless API also provides bounded selection and incremental search. Capture
opaque `selectionPoint(row:column:)` values from the presented viewport, call
`select(from:to:rectangular:)`, and advance pending work with `advanceSelection()`.
`copySelection(_:)` validates the captured selection instead of reinterpreting
stale coordinates. `beginSearch(_:options:)` starts a search; call `advanceSearch()`
while pending, then `navigateSearch(older:)` and `currentScreen()` to read the
revealed match. `clearSelection()`, `cancelSearch()` and `clearSearch()` end the
corresponding operation. See [search](search.md) for budgets and regex semantics.

## Show a terminal

```swift
import AppKit
import TerminalHost
import TerminalUI

// Once per app: the renderer and the clipboard access all views share.
let rendering = try TerminalRendering()
let clipboard = ClipboardAccess(writingTo: .general)

// Once per terminal.
let session = TerminalSession(
  launch: .loginShell(cwd: NSHomeDirectory()),
  startsAtFirstGrid: true)
let view = TerminalCanvasView(
  frame: .zero, session: session, rendering: rendering, clipboard: clipboard,
  configuration: TerminalViewConfiguration(fontSize: 13))

window.contentView = view
window.makeFirstResponder(view)

view.onTitle = { title in window.title = title }
session.onEnd = { end in window.close() }
```

The view sizes the terminal to its bounds and resizes the child's PTY when
its frame changes. With `startsAtFirstGrid`, the child starts when the view
has its first size, so the shell draws its first prompt at the right width.
`view.contentSize(columns:rows:)` gives the view size for a grid, for sizing a
window before it is shown.

### Starting the child

A session starts its child itself: on a new PTY that is the child's
controlling terminal, in the working directory asked for, with signal
handling reset. Nothing has to be added to the host's bundle. When the
program or the directory is missing, `onLaunchFailure` says which.

The app starts its children through a small helper, `TerminalLauncher`,
which does the same steps in a process of its own. A host may do so too by
passing the helper's path as `launcher:`; it must then build the helper
(`swift build --product TerminalLauncher`), copy it into its bundle and sign
it. The [shell integration](#shell-integration) is a package resource and also
works without the helper.

### What to run

| Launch | Runs |
| --- | --- |
| `LaunchSpec.loginShell(cwd:)` | `$SHELL -l`, or `/bin/zsh -l` when `SHELL` is unset |
| `LaunchSpec(executable:arguments:cwd:environment:)` | Any program. `arguments` includes the program name as its first element. |

The child inherits the host's environment with `TERM=xterm-256color`,
`COLORTERM=truecolor` and `TERM_PROGRAM=HelgeTerminal` set, and with the
variables removed that describe another terminal the host itself was started
from (`TERM_SESSION_ID`, `KITTY_*`, `TMUX` and the like). `environment` names
variables for the child and replaces any of these, so a host sets its own
`TERM_PROGRAM` there.

### Shell integration

`TerminalHost` carries the zsh, Bash and fish hooks as package resources.
`TerminalShellIntegration.directory` exposes their root. A launch first uses an
explicit `LaunchSpec.shellIntegrationDirectory`, then helper-relative
`../Resources/ShellIntegration`, then the package resource directory. Hooks load
the user's configuration and report prompts and working directories. Unsupported
shells start normally. A manually linked host must copy
`Sources/TerminalHost/Resources/ShellIntegration` into its resource bundle or
pass an explicit directory; SwiftPM handles the resource bundle automatically.

### Lifetime

A session serves one view; creating a second view on it stops the program
with a message. `close()` ends the session: the child is sent `SIGHUP`, and
`SIGKILL` two seconds later if it is still there. Releasing the last
reference to a session does the same, so a host that drops a view and its
session does not leave a shell running. After `close()` the session does not
call `onEnd`.

### SwiftUI and iOS

`TerminalView` shows a session in SwiftUI, on macOS and iOS:

```swift
struct ContentView: View {
  let session: TerminalSession          // one per view
  let rendering: TerminalRendering      // one for the app
  @State private var title = ""
  var body: some View {
    TerminalView(session: session, rendering: rendering)
      .onTerminalTitle { title = $0 }
      .navigationTitle(title)
  }
}
```

On iOS, `TerminalCanvasView` is a `UIView` implementing `UITextInput`. A tap
brings up the keyboard or opens a link after owner validation. A long press
selects a word; dragging extends the selection and releasing offers Copy,
Paste, Select All, Find and link actions. A one-finger drag scrolls history.
`showFind()` presents an inline search bar and `hideFind()` clears it. Hosts
may instead call the session's search methods and provide their own controls.
iOS starts no processes, so the session runs over a
`TerminalTransport` (an SSH library, for one); `LaunchSpec` fails there with
`.spawn(errno: ENOTSUP)`. `Examples/iOSCheck` runs the view on the
simulator with `just ios-check`.

Composition edits a local document capped at 16,384 UTF-16 units, with
grapheme-safe deletion and replacement. Only committing it sends text to the
remote program; terminal output is never editable UIKit storage. Candidate,
caret and selection geometry share the renderer's bounded preedit layout.
Hardware keys retain press/repeat/release and modifier facts when UIKit exposes
them; printable text follows the input method, including dead keys. UIKit does
not expose AppKit's independent layout translation API, so unavailable key
alternates are left empty. Focus loss and backgrounding cancel composition and
release tracked hardware keys.

VoiceOver exposes nonempty viewport rows and independently actionable links,
with actions for older/newer output, selection, Copy and Find. Projection is
bounded to 256 rows, 65,536 UTF-16 units and 128 links. Older history is reached
through viewport navigation or search. It does not announce every output update.
Source and simulator tests do not certify physical hardware keyboards, CJK input
methods or VoiceOver speech/navigation on devices; those remain qualification
requirements.

### A session without a local process

An SSH client, a serial console or a replay tool gives the session a
transport instead of a launch.

```swift
final class Channel: TerminalTransport {
  var connection: TerminalConnection?
  func start(_ connection: TerminalConnection, columns: Int, rows: Int) {
    self.connection = connection          // open the far end at this size
  }
  func send(_ bytes: Data) { /* keystrokes and the terminal's replies, for the far end */ }
  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) { /* window change */ }
  func close() { connection = nil }
}

let session = TerminalSession(transport: channel, startsAtFirstGrid: true)
// When the far end has output:
channel.connection?.receive(bytes)
// When it is gone:
channel.connection?.end()                 // or end(error:)
```

| Rule | Detail |
| --- | --- |
| Threads | The transport's methods run on one private serial queue, one at a time. `receive` and `end` may be called from any thread. |
| Order | Bytes are shown in the order `receive` got them. Everything received before `end` is shown before the session reports its end. |
| Flow control | `receive` returns at once and keeps the bytes until the terminal takes them. `bufferedByteCount` says how many wait; a source that can outrun the terminal, such as a file, pauses while it is large. |
| End | `end()` gives `onEnd` with `exitedCleanly` true; `end(error:)` gives it false and the error in `transportError`. `exitCode` and `processIdentifier` are nil. |
| Close | `close()` is called once after `start`, when the session is closed or released or the transport has ended it. |

## Callbacks and control

All callbacks run on the main thread.

| Member | Meaning |
| --- | --- |
| `view.onTitle` | The program set the window title |
| `view.onActivated` | The view is becoming the window's first responder |
| `view.onFocused` | The view has become first responder, one main-queue turn later |
| `view.onOpenLink` | The user opened a link with Command-click. Return true when the host has dealt with it; otherwise the view opens it with the workspace. |
| `view.onContextMenu` | The context menu, holding Copy and Paste, before it is shown; the host changes its items |
| `session.onBell` | The program rang the bell. The terminal makes no sound of its own. |
| `session.onStatus` | A line of text about the session's life, for a log |
| `session.onLaunchFailure` | The child could not be started. `SessionLaunchFailure` says why: `.invalidArguments`, `.spawn(errno:)`, or `.stage(_:errno:)` with the launcher's failing step, such as `.execute` for a missing program or `.workingDirectory` for a missing directory. |
| `session.onEnd` | The child has exited and its last output is on screen. `SessionEnd` carries `exitedCleanly`, `exitCode` or `terminatingSignal`, and `seconds`, the run time in seconds. |
| `session.processIdentifier` | The child's process ID, once it has started |
| `session.workingDirectory` | The directory the child last reported with OSC 7 |
| `session.rawInput(_:)` | Send bytes to the child as if typed |
| `session.send(_:modifiers:)` | Press a `TerminalKey` (arrows, Home, End, Page Up and Down, Insert, Delete, Backspace, Tab, Enter, Escape, F1 to F12, or a character key) with Shift, Option, Control or Command, encoded for the program's current modes |
| `session.send(text:)` | Type text, as the keyboard would |
| `session.paste(_:)` | Send text as a paste, bracketed when the program asked for that; at most 1 MiB |
| `session.scroll(_:)` | Move the view over the history by lines; positive is toward older output |
| `view.visibleText` | The text on screen, one line per row |
| `view.hasSelection`, `view.selectedText(_:)`, `view.clearSelection()` | Whether text is selected, the selected text as Copy would give it, and removing the selection |
| `session.search(_:options:completion:)` | Search the screen and history. `TerminalSearchOptions(caseSensitive:wholeWord:regularExpression:)` defaults all options to false. A hit selects the newest match and reports its one-based position and retained count; bounds and regex semantics are documented in [search](search.md). |
| `session.searchNavigate(older:completion:)`, `session.searchClear()` | Step to the next match; remove the search |
| `view.gridSize` | The columns and rows the view holds |
| `session.clearDisplay()` | Clear the display, as the app's Clear Screen command does |
| `session.close()` | End the session and its child |
| `view.apply(_:)` | Change the configuration of a running view |

`TerminalViewConfiguration` holds the font size in points, the font family,
whether Option sends Escape, the inset between the view's edge and the text
(`contentInset`, 8 points unless set), and a `TerminalSessionConfiguration`: the history limit in rows
(at most 50,000), whether typing scrolls back to the newest output, and the
colors.

### Wide text

`configuration.session.graphemeClustering` is the state mode 2027 starts in.
True, the default: an emoji with a skin tone, a flag or a joined family takes
the cells of one character, as a program that segments by grapheme expects.
False: every code point with a width takes its own cells, as zsh and other
programs that sum `wcwidth` expect; their cursor then stays where they think
it is, and such emoji are drawn in pieces. A program can switch the mode for
itself, and a terminal reset returns to the host's choice.

### Font

`fontFamily` names a fixed-pitch family; the grid is measured from it.
`TerminalFonts.bundledFamilies` lists the ones that come with the package
and need not be installed: Obel Mono (the default), JetBrains Mono, Fira
Code, Hack and IBM Plex Mono. `TerminalFonts.installedFamilies()` lists the
fixed-pitch families on the Mac, such as `"Menlo"`, for a font menu. Left nil, or naming a family the
Mac does not have, it gives the bundled Obel Mono. A family without a bold
or italic face draws its regular one. Icons the family lacks come from the
bundled symbols font. Views with different families share one renderer.

### Ligatures

`configuration.ligatures`, off unless set, joins runs of punctuation when
the font has ligatures for them: `->`, `=>`, `!=`, `===`, `|>`. Of the
bundled families, JetBrains Mono and Fira Code have them. A run is at most eight cells, ends
where the style changes, and keeps the width of its cells; letters and
digits are never joined.

### Colors

`TerminalColorScheme` names the text color, the background, the sixteen ANSI
colors, the cursor and the selection, each as `0xRRGGBB`. Unnamed ones keep
Helge Terminal's values.

```swift
var configuration = TerminalViewConfiguration()
configuration.session.colors = TerminalColorScheme(
  foreground: 0x586e75, background: 0xfdf6e3, cursor: 0x268bd2,
  selectionBackground: 0xeee8d5, selectionForeground: 0x586e75)
view.apply(configuration)      // or pass it to the view's initializer
```

Programs that ask for the colors (OSC 4, 10, 11) are told these. A color a
program has set for itself is kept when the scheme changes, and a terminal
reset returns to the scheme. With any scheme but the standard one, the find
bar, the selection notice, search highlights and the idle cursor are colored
from the scheme's text, background and cursor.

## Menus

Copy, Paste, Select All, Cancel Paste and Clear Screen are ordinary responder
actions on the view (`copy(_:)`, `paste(_:)`, `selectAll(_:)`,
`cancelPaste(_:)`, `clearScreen(_:)`), and so are Find, Find Next and Find
Previous. `TerminalEditMenu.make()` returns an Edit menu wired to them:

```swift
let edit = NSMenuItem()
edit.submenu = TerminalEditMenu.make()
NSApp.mainMenu?.addItem(edit)
```

The Find actions open a `TerminalFindBar`, which the host creates, places
over the top edge of the terminal view and attaches. It stays hidden until
Find is chosen. A host with its own search interface leaves it out and calls
`session.search` instead.

```swift
let findBar = TerminalFindBar()
findBar.frame = NSRect(x: 0, y: 0, width: view.frame.width, height: TerminalFindBar.height)
findBar.autoresizingMask = [.width]
container.addSubview(findBar)          // above the terminal view, in a flipped container
view.attach(findBar: findBar)
```

Programs may write the clipboard with OSC 52 through the `ClipboardAccess`
the view was given; a view created with `clipboard: nil` refuses those writes
and copies nothing. `ClipboardAccess(writingTo:)` allows every write, as the
app does. A host that wants a say gives a decision instead:

```swift
let clipboard = ClipboardAccess(writingTo: .general) { text, decide in
  decide(text.utf8.count < 10_000)     // at once, or later after asking the user
}
```

It is asked about each write, on the main thread; Copy from the menu is the
user's own act and is not asked about. [Clipboard protocol](osc52-clipboard.md)
describes the rest of the policy.

## Accessibility identifiers

The view and the find bar carry fixed identifiers for interface tests:
`no.helgesverre.terminal.pane.<UUID>` on each terminal view,
`no.helgesverre.terminal.selection-notice`, and
`no.helgesverre.terminal.find` with `.query`, `.count`, `.previous`, `.next`
and `.close` beneath it. A host may replace them with
`setAccessibilityIdentifier` on the views it owns.

## Resources

`TerminalUI` carries its fonts (7.4 MB: the five bundled families and
Symbols Nerd Font Mono) and the Metal shader
source as package resources, so an embedding app adds nothing to its bundle
for them. The shader source is compiled when `TerminalRendering` is created; its initializer throws
`TerminalRendering.RendererError` (`.noDevice`, `.noShaders`, `.noMemory`).
The fonts keep their own licenses; see the
[font directory](../Sources/TerminalUI/Resources/Fonts/README.md).

## Compatibility policy

The compatibility boundary is the documented `public` Swift API in the three
library products. `package` declarations, internal C bridges, the app, diagnostics
and serialized implementation snapshots are outside it. No binary ABI or
library-evolution compatibility is promised; consumers rebuild the package.

Before 1.0, a tagged `0.x.y` patch preserves documented source signatures and
default behavior, except for fixes to incorrect terminal behavior. A breaking
public API change requires a new `0.x` minor series, migration notes in the
embedding guide, and rebuilding both Swift 6 hosts. After a separately approved
1.0 release, breaking API changes require a major version; additions use a minor
version and compatible fixes a patch. Existing published tags are immutable.
`main` is development and can change; pin a full commit or an approved release
tag rather than relying on its current shape. This policy creates no tag.

macOS 14 and iOS 17 are deployment floors. Apple-silicon macOS is the automated
test platform. Intel macOS and iOS devices require separate runtime evidence;
declaring a deployment floor does not establish a complete hardware test matrix.

### Concurrency contract and qualification

Use the UI, renderer setup, view configuration, callback assignment and session
lifecycle from `MainActor`. Session commands enqueue work onto the terminal owner
queue; callbacks are delivered on `MainActor`. Each headless engine belongs to
one actor or thread at a time and is not a concurrently mutable shared object.
Transport methods run serially on their private queue. A transport sharing state
with another queue must synchronize that state itself; `TerminalConnection` is
the thread-safe ingress/termination interface.

The library targets currently compile in Swift 5 language mode. The example
hosts compile in Swift 6; that verifies consumer use of the public interface,
not that library internals pass Swift 6 strict concurrency checking. Existing
`@unchecked Sendable` queue/lock owners remain explicit audit obligations, not
proof of race freedom. New unchecked annotations must identify the mutable state
and its synchronization; do not add them just to silence diagnostics.

Run `just embedding-check` for the default local-path graph and both Swift 6
hosts. After pushing a candidate, run
`just embedding-check --url https://github.com/HelgeSverre/terminal --revision <full-commit>`
to build the same hosts through remote package resolution. Both commands clear
development/test settings and reject a consumer graph containing Sparkle.
`just ios-check` separately runs UIKit simulator tests with those settings
cleared. Full library concurrency qualification additionally requires compiling
each library with strict concurrency diagnostics, eliminating each unsupported
isolation crossing, then exercising transport receive/end/close, callback
lifetime, resize and rendering races under Thread Sanitizer. A passing host
build alone must never be reported as that qualification.

## Remaining qualification

- **The rest of the look.** The find bar and the selection notice take
  their colors from the scheme but keep their shape.
- **The iOS view needs device evidence.** Complete real IME, touch selection,
  external keyboard, link and VoiceOver workflows on supported devices.
- **Library concurrency migration.** Swift 6 consumer compatibility and full
  strict-concurrency qualification are separate gates, as described above.
- **Stable release adoption.** No 1.0 tag is implied by this implementation.

[The embedding roadmap](embedding-roadmap.md) lists the defects in this
interface, what SwiftTerm and libghostty offer instead, and the order of work.
[SwiftTerm compared](swiftterm-comparison.md) covers that library in detail,
and a [throughput comparison](../reports/swiftterm-throughput-2026-11-14/README.md)
measures both as embedded libraries.

## Layout of the package

| Target | Directory | Imports |
| --- | --- | --- |
| `TerminalInterop` | `Sources/TerminalInterop` | C declarations of the emulator interface, and the spawn |
| `TerminalEngine` | `Sources/TerminalEngine` | `TerminalInterop` |
| `TerminalHost` | `Sources/TerminalHost` | `TerminalEngine` |
| `TerminalUI` | `Sources/TerminalUI` | `TerminalHost`, AppKit or UIKit, Metal |
| `TerminalApp` | `Sources/Terminal` | `TerminalUI`; the app itself |

Declarations one target needs from another are `package`: visible inside this
package, invisible to an embedding app. Only what this page describes is
`public`.
