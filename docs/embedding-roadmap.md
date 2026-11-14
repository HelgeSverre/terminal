# Embedding: where the package stands and what it needs

An audit of the package's public interface on 2026-11-14, set against the two
libraries an app would otherwise choose: SwiftTerm and libghostty. It lists
what is wrong with the interface today, what is missing, and an order to
build it in. [Embedding](embedding.md) describes the interface as it is.

Everything here was read from source; nothing in the other two projects was
built or run for it. The throughput comparison with SwiftTerm is separate and
measured: [swiftterm-throughput-2026-11-14](../reports/swiftterm-throughput-2026-11-14/README.md).

| Project | Commit read | Date |
| --- | --- | --- |
| Terminal | `7a396ab` | 2026-11-14 |
| SwiftTerm | `d4f52fa` | 2026-11-12 |
| Ghostty | `6d95777` | 2026-11-13 |

## The three findings that matter most

- **libghostty-vt is at 1.0.** Released 2026-11-06 (1.0.1 on 2026-11-11) with
  a stable C interface checked in CI, semantic versions and a prebuilt
  XCFramework for SwiftPM. It is an engine only: no PTY, no drawing, no view.
  Its host writes all of those.
- **`ghostty.h` is not for embedders.** The header calls itself
  "libghostty-internal", for the Ghostty macOS app only, and points other
  users to libghostty-vt. It has no versions and no stability promise.
- **Most of what a host needs from us already exists as `package` API.**
  Scrolling, search, selection, copy, key events, the working directory,
  resize and link activation are implemented and used by the app. The gap is
  a designed public surface, not missing machinery.

So the position worth aiming for is the one neither of the others holds: a
complete terminal view from a Swift package (Metal, PTY, input methods,
accessibility) with a typed Swift interface. SwiftTerm is that today, with a
lock-based threading model and no macOS accessibility. libghostty-vt is the
stronger engine and leaves the rest to the host.

## What each offers an embedder

"vt" is libghostty-vt 1.0; "internal" is `ghostty.h`. "n/a" means that layer
is not part of the library by design.

| Capability | Terminal | SwiftTerm | libghostty |
| --- | --- | --- | --- |
| Headless engine API | no | yes | yes (vt) |
| Feed bytes without a child process | no | yes | yes (vt) |
| Local process on a PTY | yes, needs the launcher helper | yes | vt no; internal yes |
| AppKit view | yes | yes | vt no; internal draws into the host's view, host writes input and menus |
| UIKit / iOS | no | yes | vt engine builds for iOS |
| SwiftUI wrapper | no | no public one | no |
| Linux and other platforms | no | engine on Linux | yes (vt) |
| C interface for other languages | internal header only | no | yes, stable (vt) |
| Fonts, colors, cursor, padding | font size only | yes | vt: colors and cursor; internal: Ghostty config files |
| Key binding customization | Option-as-Escape only | partial | internal yes |
| Programmatic selection, copy, text | no (package only) | yes | yes |
| Search API | no (package only) | yes, with regex and whole word | yes (vt) |
| Scrollback limits and access | row limit; no read access | row limit; snapshots | byte and line limits, traversal (vt) |
| Hyperlink and prompt-mark callbacks | no | yes | yes |
| Title | yes | yes | yes |
| Working directory, bell, resize | no | yes | yes |
| Exit | clean or not, no code | exit code | internal yes |
| Kitty graphics | direct transmission only | yes | yes |
| Sixel, iTerm2 images | no | yes | no |
| Ligatures and shaping | no | yes | Ghostty's renderer only |
| Bidirectional text | no | yes | no |
| Accessibility on macOS | yes | no | in Ghostty's app, not the library |
| Many terminals, one renderer | yes | not verified | not verified |
| Snapshot of terminal state | no (package only) | owned snapshots, no restore | yes (vt) |
| Documentation | one page, one example | DocC, three sample apps | vt: reference site, guides, 37 examples |
| Versioning | none; depend on `main` | 1.x stable, 2.0 in preview tags | vt yes; internal no |
| Distribution | SwiftPM by branch | SwiftPM tags | vt: XCFramework, tarballs, wasm |
| Conformance evidence | 414 tests, real programs; no esctest, no fuzzer | 474 gated esctest cases, fuzzer, Thread Sanitizer | fuzzing, interface checks; esctest report-only |
| License | MIT | MIT | MIT |

## Fixed since the audit

- **Defect 1:** the view no longer replaces the host's `session.onStatus`.
- **Defect 2:** a second view on one session stops with a message instead of
  blanking the first.
- **Defect 3:** releasing a session ends its child, as `close()` does.
- **Defect 4:** `TerminalRendering.RendererError` is public.
- **Defect 5:** launch failures arrive as `SessionLaunchFailure` on
  `onLaunchFailure`; `SessionEnd` carries the exit code or the signal.
  `onStatus` remains, as text for a log.
- **Defect 7, in part:** the libraries no longer read the host's command
  line, and `LaunchSpec.environment` lets a host set `TERM_PROGRAM` and any
  other variable. The zsh integration lookup and the accessibility
  identifiers are unchanged. `EarlyChild` touches `UserDefaults` only when the
  app starts an early child, which a host never does.
- **Defect 8:** the parser's classes are exempt from dynamic exclusivity
  checks in the source, so the package build needs no flag. The same host
  measured 131 MiB/s on truecolor before and 204 to 206 after; mixed Unicode
  went from 107 to 142 to 143.
- **From "not public":** scroll, process ID, working directory, visible text,
  grid size, and the Paste, Cancel Paste and Clear Screen actions are public.

- **Defect 6:** the modules are now `TerminalEngine`, `TerminalHost` and
  `TerminalUI`, the session type is `TerminalSession`, and the C functions
  are `helge_terminal_*`. The lists below use the names they had when
  audited: `TerminalCore`, `TerminalSession`, `TerminalView` and `Session`.
- **Defect 19:** as another app's dependency the package has no dependencies
  of its own and no app, tool or test targets, and never compiles the test
  hooks. The manifest tells by its location in a `checkouts` directory.
- **Headless engine, first step:** `HeadlessTerminal` in the `TerminalEngine`
  product feeds bytes and returns screen text and replies. Cell styles,
  history and a session over a host's transport are still missing.
- **Mode 2027:** a query is answered "permanently set". A layout by code
  point width is not built; see `BUGS.md`.

The lists below are as audited at `7a396ab`.

## Defects in the public interface today

### Breaks a host, or forces a rename later

1. **The view overwrites the host's `session.onStatus`.** `TerminalCanvasView`
   assigns it in its initializer (`Sources/TerminalUI/Canvas.swift:145`).
   A handler set before the view exists is lost; the example sets it after
   and works by order alone.
2. **A session serves one view, and nothing says so.** The view also takes
   over `onSnapshot` and `onClipboardWrite`. A second view on the same
   session blanks the first.
3. **Releasing a session does not end it.** The process source captures the
   session strongly (`Session.swift:741`), so a session with a live child is
   never freed and the child keeps running. `close()` is required and
   undocumented.
4. **`TerminalRendering.init()` throws a type the host cannot see.**
   `RendererError` is internal, so "no Metal device" and "no shaders" cannot
   be told apart.
5. **Status is English strings.** Launch failure, rejected input and
   "Session finished" all arrive on `onStatus`. A failed launch never fires
   `onEnd`, so a host can only tell failure from a slow start by parsing text.
6. **Names.** `Session` is too generic for a public type. The module
   `TerminalUI` shares its name with SwiftTerm's main class. The C type
   `Terminal` and the unprefixed `terminal_*` symbols can collide in a host
   process.
7. **App behaviour inside the libraries.**
   - `Session` reads `--session-statistics-file` from the host's command
     line; the renderer reads three smoke-test flags.
   - `EarlyChild` reads and writes the `LaunchGrid` key in the host's
     `UserDefaults`.
   - The spawn sets `TERM_PROGRAM=HelgeTerminal` and applies the app's zsh
     integration when it finds it beside the launcher.
   - Accessibility identifiers are `no.helgesverre.terminal.*`.
8. **The package build is slower than the app.** The app turns off dynamic
   exclusivity checks; a package cannot pass that flag on. Measured cost: 131
   against 190 MiB/s on truecolor output, see the throughput report.

### Contract unclear or uneven

9. Callbacks are plain `var`s on an `@unchecked Sendable` class, read on the
   main thread with no lock. Setting them is safe only from the main thread;
   that is not written down.
10. Session callbacks are `@MainActor` closures; view callbacks are not.
    `ClipboardAccess` and the renderer check the thread at run time.
11. `rendering: nil` draws nothing and `clipboard: nil` disables Copy as well
    as OSC 52. Paste reads `NSPasteboard.general` whatever pasteboard the
    host gave.
12. `paste:`, `find:`, `findNext:`, `findPrevious:` and `cancelPaste:` are
    internal, so a host building its own menu cannot name them.
13. `Session.configure` is public and the view also calls it, overwriting the
    host's value.
14. `rawInput` returns nothing; over the 2 MiB admission limit the bytes are
    dropped and reported as a status string.
15. `LaunchSpec` takes paths as `String`, includes `argv[0]` in `arguments`,
    has no environment, and its limits (256 arguments, 1 MiB) are
    undocumented.
16. The child starts in `init`, at the first resize, or after a fixed second.
    There is no `start()`.
17. About half the public members have no documentation comment; several
    that do describe panes, an app concept.
18. About 60 `public override` members of the view are public only because
    the class is.
19. Sparkle, the developer tool and the app are in the same package, so every
    embedder resolves Sparkle. `TERMINAL_TEST_HOOKS` in an embedder's build
    environment compiles the test hooks in.

## What a host needs that is not public

| Need | State today |
| --- | --- |
| Scroll, search, selection and copied text | implemented, `package` (`Session.swift:1302`–`1397`) |
| Screen text or a snapshot | implemented, `package` (`onSnapshot`, `TerminalSnapshot`) |
| Key events instead of raw bytes | implemented, `package` |
| Working directory, process ID, exit status | held privately |
| Grid size and a resize notification | size is `package`; no notification |
| Bell | discarded in the emulator (`TerminalEmulator.swift:500`) |
| Link opening, context menu, clipboard decision | fixed in the view |
| Font, colors, insets, cursor | fixed (`Font.swift`, `Theme.swift`) |
| Environment and `TERM_PROGRAM` for the child | fixed in `Spawn.c` |
| A transport other than a local process | absent |
| The emulator without a session | no public declaration in `TerminalEngine` |

## Order of work

Sizes are small (a day or less), medium (days) or large (a week or more).

| # | Item | Size | Code |
| --- | --- | --- | --- |
| 1 | Fix defects 1 to 5: no callback takeover, defined lifetime, typed events and errors, public renderer error | small | `Session.swift`, `Canvas.swift`, `Renderer.swift` |
| 2 | Remove the exclusivity cost in the source, so the package is as fast as the app | small | `TerminalEmulator.swift`, `TerminalDocument.swift` |
| 3 | Rename before the first tag; split the libraries into a manifest without Sparkle, the tool or the app; tag library versions | medium | `Package.swift`, `Bridge.h` |
| 4 | Move command-line flags, `EarlyChild`, `UserDefaults`, the zsh shim and `TERM_PROGRAM` out of the libraries into options the host passes | medium | `Session.swift`, `Renderer.swift`, `Spawn.c` |
| 5 | Make the existing package API public in a designed shape: scroll, search, selection and text, key events, paste, working directory, size, process ID, exit status | medium | `Session.swift`, `Canvas.swift`, `TerminalSnapshot.swift` |
| 6 | A transport protocol; the local process becomes one implementation | medium | `Session.swift`, `IO/` |
| 7 | A public headless engine with screen text and snapshots | medium | `TerminalEmulator.swift`, `TerminalSnapshot.swift` |
| 8 | Host-supplied font, theme, insets and cursor | large | `Font.swift`, `Theme.swift`, `CellPalette.swift`, `Renderer.swift`, `GlyphResidency.swift` |
| 9 | A view delegate for links, context menu, clipboard decision and bell; an attachable find bar | medium | `Canvas.swift`, `ClipboardAccess.swift`, `FindBar.swift` |
| 10 | Launch value with environment; a spawn that needs no helper, or a build plugin that embeds and signs it | medium | `Spawn.c`, `Launcher.c` |
| 11 | Swift 6 mode and `@MainActor` on the view types | medium | the three library targets |
| 12 | DocC, a comment on every public member, a SwiftUI wrapper, a second example with a custom transport | medium | new catalog, `Examples/` |
| 13 | Conformance evidence: an esctest run and a fuzzer in the tree | medium | `Tests/`, `tools/Dev` |
| 14 | Protocol items hosts notice: bell, OSC 52 read, OSC 9 and 777, title stack, XTVERSION, cursor blink | medium | `TerminalEmulator.swift` |
| 15 | Ligatures and shaping | large | `Font.swift`, `Renderer.swift`, `GlyphResidency.swift` |
| 16 | macOS 13 or 14, and Intel | medium | `Renderer.swift`, build settings |
| 17 | An iOS view | large | new target; the view split into shared and AppKit parts |
| 18 | Sixel, iTerm2 images, the rest of Kitty graphics | large | `KittyGraphics.swift`, new decoders |

Items 1 to 7 make the package usable wherever SwiftTerm's view with a custom
transport is used on macOS today. Item 17 is the main reason apps choose
SwiftTerm.

## What would make it better than both

Each builds on something the code already does.

| Item | Why neither has it | Size |
| --- | --- | --- |
| A written concurrency contract: every callback on the main actor, no call can deadlock, enforced by Swift 6 | SwiftTerm hosts must know which callbacks run with its lock held; libghostty-vt leaves all locking to the host | medium |
| `async` calls over bounded work: search, copy and resize that report progress and can be cancelled | SwiftTerm's reflow is one synchronous call under a lock; vt has incremental search that the host must schedule | small, after item 5 |
| Memory budgets as configuration: history bytes, glyph bytes per process, reflow reservation | SwiftTerm limits rows only; vt has no renderer | small |
| Stable row identities in the public screen type, so marks and annotations survive reflow | SwiftTerm uses row offsets; vt offers tracked references through C | medium |
| Accessibility checked with VoiceOver and open to host customization | SwiftTerm has none on macOS | small |
| Launch failures as a typed error with the failing stage | SwiftTerm reports a failed exec as exit code 127 | small |
| Mixed-Unicode throughput | Measured about three times SwiftTerm's | have it |

One option to weigh, not a recommendation: libghostty-vt could be the engine
under our session and view. It would bring a fuzzed parser and iOS, at the
cost of the bounded-reflow and row-identity model that several items above
rest on, and of a binary dependency.

## Not verified

- The session leak on release is derived from the strong capture; it was not
  run.
- Whether importing our `TerminalUI` module beside SwiftTerm fails to
  compile was not built.
- Whether `ghostty.h` can run a surface without spawning a command, and how
  complete it is on iOS.
- Shared GPU resources between views in SwiftTerm and in Ghostty.
- The planned libghostty renderer and widget libraries: announced in 2025,
  absent from the tree read here.
- VoiceOver with any of the three.
