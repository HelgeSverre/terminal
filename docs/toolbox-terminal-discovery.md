# Toolbox terminal discovery and image-drop investigation

Investigated 2026-11-16 against terminal commit `e2b28ef` and installed
JetBrains Toolbox `3.9.1.89198`; subsequently implemented and tested below.

## Toolbox discovery

The installed `Contents/lib/interop.jar` contains
`com.jetbrains.toolbox.interop.terminal.FoundationMacApplicationWorkspace`,
`MacTerminalContentType`, `MacTerminalHandlersKt`, and `MacTerminalsKt`.
Their class constants identify these discovery operations:

- `NSWorkspace` selectors `URLsForApplicationsToOpenContentType:`,
  `URLForApplicationToOpenContentType:`, and
  `URLForApplicationWithBundleIdentifier:`.
- Content types `com.apple.terminal.shell-script` and `public.unix-executable`.
- Reading `CFBundleDocumentTypes`, `CFBundleTypeRole`, and `LSItemContentTypes`
  from application bundles, including shell content types.

This is evidence of discovery through registered file handlers, rather than
requiring a new entry in a fixed terminal-name list. Apple documents
[NSWorkspace's type-handler discovery](https://developer.apple.com/documentation/appkit/nsworkspace/urlsforapplications%28toopen%3A%29-60rkm)
and [document-type declarations](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html).

Our `Resources/Terminal/Info.plist` declares the developer-tools app category
but no `CFBundleDocumentTypes`. Installed Ghostty and kitty both declare
`public.unix-executable` with role `Shell`. Installed cmux declares both types
above with role `Shell` and handler rank `Alternate`.

The implementation declares both document types with role `Shell` and rank
`Alternate`, avoiding a request for default-handler status. App delegate
open-file callbacks validate executable files and launch each in a new window,
with the containing directory as its initial working directory. Paths are
passed directly as argv, without evaluating them as shell text. The executable
or its shebang selects the interpreter. Nonexecutables and directories are
rejected with a standard application error. Finished commands retain their
output window. Apple documents [the open-file delegate callback](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopenfile%3A%29).

Early file-open events are queued until launch setup finishes and replace the
normal initial window. The unused early shell is hung up, forcibly ended if
needed, and reaped without decrementing the adopted-session child count.

`just terminal-file-smoke` copies the built app to a temporary bundle with a
unique identity, registers it, verifies discovery for both content types, then
uses `open -a` to deliver command files on cold and warm launches. Receipts
verify the same app PID, PTYs, working directory, and literal paths containing
spaces, quotes, Unicode and shell metacharacters. Cleanup terminates only the
fixture and unregisters its bundle. The user's installed app is not changed.
The installed Toolbox bytecode additionally confirms that it generates an
owner-executable `#!/bin/sh` script, removes it via `"$0"`, changes directory,
and hands the file to the selected app through Launch Services.

Installing a build with this metadata lets macOS discover it; the development
smoke does not register the installed app or change Toolbox's saved selection.

## Image-drop symptom

The reported text ends with `[<35;114;47M`. Our
`TerminalCanvasView.mouseMoved` emits button code 35 when all-motion mouse
tracking (1003) is active. `reportMouse` formats SGR reports as
`ESC [ < button ; column ; row M`. Thus this suffix matches a mouse-motion
report at column 114, row 47, with its leading ESC missing from visible text.
This identifies the protocol sequence; it does not establish where the ESC
was lost or why the receiving application treated the remainder as text.

The drop handler already shell-quotes file paths and calls `send(..., key: 1)`.
Cmd-V uses that same key. The session forwards it to the engine, where
`TerminalEmulator.encodeInput` routes key 1 to `TerminalInputEncoder.paste`.
That encoder adds `ESC[200~` and `ESC[201~` whenever the child has enabled
bracketed-paste mode. Therefore the current source does not support a claim
that drag-and-drop simply bypasses bracketed paste.

Initial hypotheses included disabled bracketed paste, an older installed
bundle, mouse-event parsing, and a mode transition near the drop. The quoted
path alone is expected terminal drop
payload; the receiving application decides whether to turn it into an image
attachment or a visible paste marker.

The subsequent `DropInputTests` calls the real drop handler with a private
pasteboard and then delivers a mouse-move event. The view/session/encoder
pipeline emits exactly `ESC[200~'quoted path'ESC[201~ESC[<35;114;47M` to a
recording transport: complete framing, followed by a separate intact report.

An opt-in `CodexInputProbeTests` launches the installed Codex 0.169.0 binary
as a real PTY child, without sending any prompt. A complete SGR mouse report
is invisible to its composer. Sending ESC separately, waiting 100 ms, then
sending `[<35;114;47M` reproduces the exact visible suffix.

Codex 0.169.0 uses [OpenAI's Crossterm fork at ed1cdab](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/Cargo.toml#L683),
whose [Unix reader](https://github.com/openai-oss-forks/crossterm/blob/ed1cdab335221515706178d68495bba2aed1924f/src/event/source/unix/mio.rs)
has a 20 ms lone-ESC ambiguity window. Once that expires, ESC is a key event
and the remaining characters can become text. This explains the reproduced
suffix, but does not prove why the original input was separated. Our writer
preserves transaction ordering; OS short writes and reads need not preserve
transaction boundaries. Do not claim that one raw-input transaction guarantees
one receiver read, or disable valid requested mouse reporting as a workaround.

The image-path probe also exposed a separate readiness question. Codex's
[startup draft](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/tui/src/startup_draft.rs)
uses a plain-text composer with image-path attachment disabled even though
bracketed paste is already enabled. The primary composer
[normalizes quoted paths and reads image dimensions](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/tui/src/bottom_pane/chat_composer.rs#L1289).
Terminal paste mode and the session header alone are therefore not evidence
that image attachment is ready. In the actual Codex 0.169.0 probe, an immediate
paste remained literal; the same quoted valid PNG attached successfully after
a two-second settling delay. The delay is an experimental control, not an app
readiness API. There is no capture of the original session's startup state,
so this reproduces an explanation rather than proving that original timing.
The terminal's normal paste encoder remains unchanged.

Run the optional receiver probe with the native Codex binary's absolute path
and an already trusted working directory:

```sh
TERMINAL_CODEX_INPUT_PROBE=/path/to/codex \
TERMINAL_CODEX_PROBE_CWD=/path/to/trusted/repository \
just unit-test --filter CodexInputProbeTests
```

It creates a private PNG, attaches it locally without submitting a prompt,
tests complete and split mouse reports, then closes and reaps its own child.
It is skipped by the normal test gate because Codex and account readiness are
external dependencies. `DropInputTests` provides the deterministic terminal
wire-format coverage in the normal gate.
