# OSC 52 clipboard policy

The terminal supports a deliberately narrow OSC 52 surface:

- `OSC 52 ; c ; <RFC 4648 base64> ST` is a request to write the macOS general
  pasteboard. Accepted decoded payloads are capped at 1 MiB, with at most four outstanding
  requests per session. Only valid UTF-8 is accepted for the text pasteboard.
- The native default is an **Allow / Deny** sheet. `ClipboardAccess` is the
  only object that presents it or writes `NSPasteboard`; no preference grant is
  persisted.
- Selection `c` is the only supported target. Primary, secondary, select, and
  cut-buffer targets are not aliased to the general pasteboard.
- `OSC 52 ; … ; ?` never reads the pasteboard. It returns the defined empty
  `OSC 52 ; c ; ST` reply without asking the host. Malformed, oversized, or
  unsupported writes are ignored.

Xterm defines OSC 52 data as RFC 4648 base64, including `?` as the read form,
and describes the selection target set in its [control-sequence reference](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Operating-System-Commands).
AppKit owns the write through [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard), and the user decision uses
[NSAlert's sheet completion](https://developer.apple.com/documentation/appkit/nsalert/beginsheetmodal(for:completionhandler:)).

The core drains these requests independently of the replaceable render-snapshot
mailbox. Every request has a core-owned ID and a session UUID; resolution is
sent back to the owner queue, and a closed/stale session cannot write after a
late decision. The native owner presents one sheet at a time and accepts only
four total pending requests, so output floods neither block the PTY nor create
an unbounded prompt queue. A decision is rate limited to one prompt per second
per session; after an explicit Deny, the rest of that session is silently
denied. This state is discarded when the session ends and is not a persisted
grant. Session close or PTY input EOF dismisses an active sheet, rejects its
late callback, and advances another session's pending request without waiting
for user interaction.

Verification uses named private `NSPasteboard` fixtures only. It covers allow,
deny, stale-session suppression, prompt bounds, malformed and oversized core
input, and a real PTY query/reply proving that OSC 52 reads receive the empty
denial response without consulting a pasteboard.

The current parser buffers a bounded encoded OSC string before decoding it.
The specification's separate streaming base64 path remains implementation work.
