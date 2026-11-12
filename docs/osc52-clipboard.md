# OSC 52 clipboard policy

The terminal supports a deliberately narrow OSC 52 surface:

- `OSC 52 ; c ; <RFC 4648 base64> ST` is a request to write the macOS general
  pasteboard. Accepted decoded payloads are capped at 1 MiB, with at most four outstanding
  requests per session. Only valid UTF-8 is accepted for the text pasteboard.
- Writes are allowed without asking, in every pane. This is a personal
  terminal; an Allow / Deny sheet for every write was removed in 0.4.2.
  `ClipboardAccess` is the only object that writes `NSPasteboard`.
- Selection `c` is the only supported target. Primary, secondary, select, and
  cut-buffer targets are not aliased to the general pasteboard.
- `OSC 52 ; … ; ?` never reads the pasteboard. It returns the defined empty
  `OSC 52 ; c ; ST` reply without asking the host. Malformed, oversized, or
  unsupported writes are ignored.

Xterm defines OSC 52 data as RFC 4648 base64, including `?` as the read form,
and describes the selection target set in its [control-sequence reference](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Operating-System-Commands).
AppKit owns the write through [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard).

The core drains these requests independently of the replaceable render-snapshot
mailbox. Every request has a core-owned ID and a session UUID; resolution is
sent back to the owner queue, and a closed/stale session cannot write after a
late decision. The native owner handles one request at a time and accepts only
four total pending requests, so output floods neither block the PTY nor queue
unbounded payloads. Session close or PTY input EOF rejects a pending write's
late callback and advances another session's pending request.

Verification uses named private `NSPasteboard` fixtures only. It covers the
default allow, an injected deny, stale-session suppression, request bounds, malformed and oversized core
input, and a real PTY query/reply proving that OSC 52 reads receive the empty
denial response without consulting a pasteboard.

The parser recognizes selection `c` before streaming base64 payload chunks to a
decoder with four bytes of carry. Encoded input is capped at 1,398,104 bytes and
decoded output at 1 MiB, with fallible growth and canonical RFC 4648 padding.
Parser callbacks are individually bounded to 64 KiB even for larger caller
slices. Truncated, aborted and oversized requests never become host writes.
When the outstanding-request cap is full, decoding retains no output payload.
