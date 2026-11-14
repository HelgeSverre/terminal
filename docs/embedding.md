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
      .product(name: "TerminalView", package: "terminal"),
      .product(name: "TerminalSession", package: "terminal"),
    ]),
]
```

| Product | Contents |
| --- | --- |
| `TerminalView` | `TerminalCanvasView`, `TerminalRendering`, `ClipboardAccess`, `TerminalViewConfiguration`, `TerminalEditMenu`. Carries the fonts and the shader source as package resources. |
| `TerminalSession` | `Session`, `LaunchSpec`, `SessionEnd`, `TerminalSessionConfiguration` |
| `TerminalLauncher` | The helper executable every session starts its child through |

The emulator (`TerminalCore`) is linked in by both libraries. It has no public
interface of its own yet.

## Show a terminal

```swift
import AppKit
import TerminalSession
import TerminalView

// Once per app: the renderer and the clipboard access all views share.
let rendering = try TerminalRendering()
let clipboard = ClipboardAccess(writingTo: .general)

// Once per terminal. `launcherPath` is where the app keeps the launcher; see below.
let session = Session(
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
| `LaunchSpec(executable:arguments:cwd:launcher:)` | Any program. `arguments` includes the program name as its first element. |

The child sees `TERM=xterm-256color`, `COLORTERM=truecolor` and
`TERM_PROGRAM=HelgeTerminal`. Variables that describe another terminal the
host itself was started from (`TERM_SESSION_ID`, `KITTY_*`, `TMUX` and the
like) are removed.

## Callbacks and control

All callbacks run on the main thread.

| Member | Meaning |
| --- | --- |
| `view.onTitle` | The program set the window title |
| `view.onActivated` | The view is becoming the window's first responder |
| `view.onFocused` | The view has become first responder, one main-queue turn later |
| `session.onStatus` | A lifecycle or failure message, such as `Launch failed: …` or `Session finished` |
| `session.onEnd` | The child has exited and its last output is on screen. `SessionEnd` carries `exitedCleanly` and `seconds`, the run time in seconds. |
| `session.rawInput(_:)` | Send bytes to the child as if typed |
| `session.clearDisplay()` | Clear the display, as the app's Clear Screen command does |
| `session.close()` | End the session and its child |
| `view.apply(_:)` | Change the configuration of a running view |

`TerminalViewConfiguration` holds the font size in points, whether Option
sends Escape, and a `TerminalSessionConfiguration`: the history limit in rows
(at most 50,000) and whether typing scrolls back to the newest output.

## Menus

Copy, Paste, Select All and Cancel Paste are ordinary responder actions on
the view. `TerminalEditMenu.make()` returns an Edit menu wired to them. Its
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

`TerminalView` carries Obel Mono, Symbols Nerd Font Mono and the Metal shader
source as package resources, so an embedding app adds nothing to its bundle
for them. The shader source is compiled when `TerminalRendering` is created.
The fonts keep their own licenses; see the
[font directory](../Sources/TerminalView/Resources/Fonts/README.md).

## What is missing

- **A stable interface.** Nothing here is versioned yet. Depend on a commit
  or on `main`, and expect changes.
- **Theme and font choice.** Colors and the font are the app's own; a host
  can set only the font size.
- **The find bar.** The Find action needs the app's find bar, which a host
  cannot attach yet.
- **Feeding bytes without a child process.** `Session` always starts a
  program on a PTY. An SSH client or a replay tool needs a session over its
  own transport.
- **The emulator on its own.** `TerminalCore` has no public interface for
  headless use.
- **A launch without the helper.** The host must carry `TerminalLauncher`.
- **Other platforms.** macOS on Apple Silicon is the only tested target.
  There is no iOS view and no SwiftUI wrapper; wrap `TerminalCanvasView` in
  an `NSViewRepresentable` for SwiftUI.
- **Zsh shell integration.** The app's integration scripts are part of its
  bundle and are not applied in an embedding app.

[SwiftTerm compared](swiftterm-comparison.md) describes how this differs from
the established library for the same job.

## Layout of the package

| Target | Directory | Imports |
| --- | --- | --- |
| `TerminalInterop` | `Sources/TerminalInterop` | C declarations of the emulator interface, and the spawn |
| `TerminalCore` | `Sources/TerminalCore` | `TerminalInterop` |
| `TerminalSession` | `Sources/TerminalSession` | `TerminalCore` |
| `TerminalView` | `Sources/TerminalView` | `TerminalSession`, AppKit, Metal |
| `TerminalApp` | `Sources/Terminal` | `TerminalView`; the app itself |

Declarations one target needs from another are `package`: visible inside this
package, invisible to an embedding app. Only what this page describes is
`public`.
