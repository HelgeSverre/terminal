# Toolbox terminal discovery and image-drop investigation

Investigated 2026-11-16 against terminal commit `e2b28ef` and installed
JetBrains Toolbox `3.9.1.89198`. This is an investigation, not an implementation.

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

The proposed integration is to declare both document types with role `Shell`
and rank `Alternate`, then support opening the handed-off script/executable
in a new terminal session. This avoids requesting default-handler status.
There is no matching application open-file delegate handler in our current
app. Existing `--execute` support does not implement Launch Services file-open
delivery. Apple documents [the open-file delegate callback](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopenfile%3A%29).

Do not add registration alone: appearing in the selector is insufficient if
the app cannot execute the delivered file. Verify cold and warm launches,
paths containing spaces, working directory, and command completion behavior
against Toolbox before declaring integration complete.

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

Remaining possibilities include bracketed paste being disabled at the time,
an older installed bundle, mouse-event parsing in the receiver, and a mode
transition near the drop. The quoted path alone is expected terminal drop
payload; the receiving application decides whether to turn it into an image
attachment or a visible paste marker.

No live reproduction or PTY byte capture was performed, and Helge's running
terminal was left untouched. The source inspection narrows the cause but
does not establish a verified image-drop fix. Next: reproduce in a separately
built app, capture paste boundaries and subsequent mouse bytes, and compare
the same input in another terminal. Do not change the paste encoder on this
evidence alone.
