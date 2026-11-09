# Presented link activation

Cmd-click and accessibility Press share one asynchronous owner-validation path.
URL detection and allowed schemes remain in `VisibleLinkProjection`. Its immutable
activation carries the validated URL and presented row proofs; the terminal
owner never parses URLs or opens applications. Canvas opens the captured URL
only after acceptance. Cmd-hover remains an immediate presentation operation.

The shared presented-content resolver also serves selection. It validates the
issued snapshot ID, document, screen, geometry, row identity/revision, soft edges,
order and cell boundaries. Unrelated output and movement into retained history
can succeed; overwritten, evicted or geometrically stale targets reject.
Validation retains bounded metadata and advances in 256-row/approximately 1 ms
quanta. Tests check actual capacity admission, cancellation and unchanged selection.

Session admission now distinguishes ended input from explicit closure. A reaped
child leaves its final screen selectable, copyable and clickable; text input and
OSC 52 admission stay closed. Explicit pane closure cancels queued, pending and
undelivered interaction results. The real-PTY red/green fixture and 22-child
cleanup are retained in `session-eof-lifecycle-*/`.

## Verification

The optimized development candidate has executable SHA-256
`9abdcf5702daa0b48ce7136940ec23de5430ebf68b0239d837e4e4123033de23`.
`source-and-bundle.json` records its 71 source inputs and complete 27-entry bundle
manifest. Bundle bytes/modes/link targets were identical before and after GUI
testing. This is an ad-hoc development candidate, not a notarized installation.

| Route | Hanimex serve | Hanimex Vite |
|---|---|---|
| Synthetic AppKit Cmd-click through Canvas | Pass | Pass |
| External agent-desktop accessibility Press | Pass | Pass |

All four receipts verify exact loopback Chrome navigation, closure of only the
owned browser tab, normal terminal exit and no owned cleanup survivors. The
AppKit route uses the existing diagnostic `NSApp.sendEvent` harness and is not
physical HID proof. macOS output was muted before the runs and left muted.

The same frozen bundle passes the 16/16 native selection regression. Focused
presented-content, existing selection and real-PTY Session gates pass. The
projection gate also passes: ordinary 3,000-cell/30-link construction measured
1.66 ms in its single diagnostic run; dense and million-cell cases remain
diagnostics, not main-thread latency acceptance claims.

Source-only independent reviews cleared owner validation, UI/projection routing
and Session EOF/close lifecycle. Real VoiceOver, historical AX fetching and the
broader specification gates remain separate work. The installed user app was
not targeted during these tests.
