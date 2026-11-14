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
swift build && swift build --product TerminalLauncher
.build/debug/EmbeddingExample
.build/debug/ReplayExample            # or with a file of recorded output
```

The public interface is new. It can change between releases until the
package has a 1.0 tag; [what is missing](#what-is-missing) lists what it does
not cover.

## Requirements

| | |
| --- | --- |
| Platform | macOS 15 or later, AppKit |
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
| `TerminalLauncher` | The helper executable every session starts its child through |

As a dependency the package brings no dependencies of its own: the app, its
updater and the test suites are part of the manifest only in this
repository.

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
Selection and key encoding are not public here.

## Show a terminal

```swift
import AppKit
import TerminalHost
import TerminalUI

// Once per app: the renderer and the clipboard access all views share.
let rendering = try TerminalRendering()
let clipboard = ClipboardAccess(writingTo: .general)

// Once per terminal. `launcherPath` is where the app keeps the launcher; see below.
let session = TerminalSession(
  launch: .loginShell(cwd: NSHomeDirectory(), launcher: launcherPath),
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

### The launcher

A session starts its child through a small helper, `TerminalLauncher`. The
helper makes the PTY the child's controlling terminal, changes to the working
directory, resets signal handling and then runs the program. When one of
those steps fails, the session reports which.

The package cannot place the helper in your app, so the host passes its path
in the `LaunchSpec`. Build it with `swift build --product TerminalLauncher`
and copy it into the bundle, for example into `Contents/MacOS`, and sign it
with the app.

### What to run

| Launch | Runs |
| --- | --- |
| `LaunchSpec.loginShell(cwd:launcher:)` | `$SHELL -l`, or `/bin/zsh -l` when `SHELL` is unset |
| `LaunchSpec(executable:arguments:cwd:launcher:environment:)` | Any program. `arguments` includes the program name as its first element. |

The child inherits the host's environment with `TERM=xterm-256color`,
`COLORTERM=truecolor` and `TERM_PROGRAM=HelgeTerminal` set, and with the
variables removed that describe another terminal the host itself was started
from (`TERM_SESSION_ID`, `KITTY_*`, `TMUX` and the like). `environment` names
variables for the child and replaces any of these, so a host sets its own
`TERM_PROGRAM` there.

### Shell integration

For an interactive zsh (`zsh` or `zsh -l`), the launch looks for
`../Resources/ShellIntegration/zsh/.zshenv` beside the launcher's directory.
When it is there, zsh starts through it: the user's own configuration is
loaded as usual, and the shell marks its prompts and reports its working
directory, which is what `session.workingDirectory` reads. A host that
wants this copies `Resources/Terminal/ShellIntegration/zsh` from this
repository to `Contents/Resources/ShellIntegration/zsh` in its bundle, with
the launcher in `Contents/MacOS`. Without the directory, zsh starts
unchanged. No other shell is wrapped.

### Lifetime

A session serves one view; creating a second view on it stops the program
with a message. `close()` ends the session: the child is sent `SIGHUP`, and
`SIGKILL` two seconds later if it is still there. Releasing the last
reference to a session does the same, so a host that drops a view and its
session does not leave a shell running. After `close()` the session does not
call `onEnd`.

### A session without a local process

An SSH client, a serial console or a replay tool gives the session a
transport instead of a launch. No launcher is needed.

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
| `session.search(_:completion:)` | Search the screen and its history, matching case. A hit selects the newest match and gives its one-based position and the number of matches. |
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

`fontFamily` names an installed fixed-pitch family, such as `"Menlo"` or
`"Monaco"`; the grid is measured from it. Left nil, or naming a family the
Mac does not have, it gives the bundled Obel Mono. A family without a bold
or italic face draws its regular one. Icons the family lacks come from the
bundled symbols font. Views with different families share one renderer.

### Ligatures

`configuration.ligatures`, off unless set, joins runs of punctuation when
the font has ligatures for them: `->`, `=>`, `!=`, `===`, `|>`. The bundled
Obel Mono has none, so name a `fontFamily` that does, such as
`"JetBrains Mono"` or `"Cascadia Code"`. A run is at most eight cells, ends
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

`TerminalUI` carries Obel Mono, Symbols Nerd Font Mono and the Metal shader
source as package resources, so an embedding app adds nothing to its bundle
for them. The shader source is compiled when `TerminalRendering` is created; its initializer throws
`TerminalRendering.RendererError` (`.noDevice`, `.noShaders`, `.noMemory`).
The fonts keep their own licenses; see the
[font directory](../Sources/TerminalUI/Resources/Fonts/README.md).

## What is missing

- **A stable interface.** Nothing here is versioned yet. Depend on a commit
  or on `main`, and expect changes.
- **The rest of the look.** The find bar and the selection notice take
  their colors from the scheme but keep their shape.
- **More of the emulator.** `HeadlessTerminal` has no selection and no
  search.
- **A launch without the helper.** The host must carry `TerminalLauncher`.
- **Other platforms.** macOS on Apple Silicon is the only tested target.
  There is no iOS view and no SwiftUI wrapper; wrap `TerminalCanvasView` in
  an `NSViewRepresentable` for SwiftUI.
- **Zsh shell integration.** The app's integration scripts are part of its
  bundle and are not applied in an embedding app.

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
| `TerminalUI` | `Sources/TerminalUI` | `TerminalHost`, AppKit, Metal |
| `TerminalApp` | `Sources/Terminal` | `TerminalUI`; the app itself |

Declarations one target needs from another are `package`: visible inside this
package, invisible to an embedding app. Only what this page describes is
`public`.
