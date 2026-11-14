# Embedding the terminal in another app

The repository is a Swift package. Besides the app, it builds three libraries
that another macOS app can use to show a terminal: a view, the session behind
it, and the emulator behind that. [`Examples/Embedding`](../Examples/Embedding)
is a complete app of 60 lines that does so.

```shell
cd Examples/Embedding
swift build && swift build --product TerminalLauncher
.build/debug/EmbeddingExample
```

The public interface is small and new. It can change between releases until
the package has a 1.0 tag. What exists today is one terminal view running one
child process; [what is missing](#what-is-missing) lists the rest.

## Requirements

| | |
| --- | --- |
| Platform | macOS 15 or later, AppKit |
| Swift tools | 6.0 |
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

An instance is used from one thread at a time. The screen is text, the
cursor, the title, the alternate-screen flag and the reported directory;
colors, styles, history and selection are not public yet.

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

### Lifetime

A session serves one view; creating a second view on it stops the program
with a message. `close()` ends the session: the child is sent `SIGHUP`, and
`SIGKILL` two seconds later if it is still there. Releasing the last
reference to a session does the same, so a host that drops a view and its
session does not leave a shell running. After `close()` the session does not
call `onEnd`.

## Callbacks and control

All callbacks run on the main thread.

| Member | Meaning |
| --- | --- |
| `view.onTitle` | The program set the window title |
| `view.onActivated` | The view is becoming the window's first responder |
| `view.onFocused` | The view has become first responder, one main-queue turn later |
| `session.onStatus` | A line of text about the session's life, for a log |
| `session.onLaunchFailure` | The child could not be started. `SessionLaunchFailure` says why: `.invalidArguments`, `.spawn(errno:)`, or `.stage(_:errno:)` with the launcher's failing step, such as `.execute` for a missing program or `.workingDirectory` for a missing directory. |
| `session.onEnd` | The child has exited and its last output is on screen. `SessionEnd` carries `exitedCleanly`, `exitCode` or `terminatingSignal`, and `seconds`, the run time in seconds. |
| `session.processIdentifier` | The child's process ID, once it has started |
| `session.workingDirectory` | The directory the child last reported with OSC 7 |
| `session.rawInput(_:)` | Send bytes to the child as if typed |
| `session.scroll(_:)` | Move the view over the history by lines; positive is toward older output |
| `view.visibleText` | The text on screen, one line per row |
| `view.gridSize` | The columns and rows the view holds |
| `session.clearDisplay()` | Clear the display, as the app's Clear Screen command does |
| `session.close()` | End the session and its child |
| `view.apply(_:)` | Change the configuration of a running view |

`TerminalViewConfiguration` holds the font size in points, whether Option
sends Escape, and a `TerminalSessionConfiguration`: the history limit in rows
(at most 50,000) and whether typing scrolls back to the newest output.

## Menus

Copy, Paste, Select All, Cancel Paste and Clear Screen are ordinary responder
actions on the view (`copy(_:)`, `paste(_:)`, `selectAll(_:)`,
`cancelPaste(_:)`, `clearScreen(_:)`). `TerminalEditMenu.make()` returns an Edit menu wired to them. Its
Find items do nothing in an embedding app until a host can attach a find bar:

```swift
let edit = NSMenuItem()
edit.submenu = TerminalEditMenu.make()
NSApp.mainMenu?.addItem(edit)
```

Programs may write the clipboard with OSC 52 through the `ClipboardAccess`
the view was given; a view created with `clipboard: nil` refuses those writes
and copies nothing. [Clipboard protocol](osc52-clipboard.md) describes the
policy.

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
- **Theme and font choice.** Colors and the font are the app's own; a host
  can set only the font size.
- **The find bar.** The Find action needs the app's find bar, which a host
  cannot attach yet.
- **Feeding bytes without a child process.** `TerminalSession` always starts a
  program on a PTY. An SSH client or a replay tool needs a session over its
  own transport.
- **More of the emulator.** `HeadlessTerminal` gives text only: no colors
  or styles per cell, no history, no selection, no key encoding.
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
