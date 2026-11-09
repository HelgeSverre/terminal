# Owner selection and copy

Selection now belongs to the terminal owner. The view submits hits from its
displayed snapshot and renders immutable selection segments. It no longer holds
back output snapshots or serializes copied cells independently.

Presented hits carry reset identity, screen, geometry, row identities/revisions
and boundaries. Selected-cell observations detect equal-byte overwrites without
invalidating unrelated edits on the same row. Whole-row movement and reflow
retain selected content; eviction and selected overwrites clear it visibly.
Primary and alternate selections remain separate.

Character, Unicode word, line and rectangular selection share this path. The
typed word-punctuation setting is validated once for Settings, AppleScript and
Session configuration. Copy captures immutable text in bounded owner turns,
with a 16 MiB result limit. Proof and copy-buffer credits remain held through
retirement. A 24,903,680-byte potential result is rejected without partial text;
paused-retirement tests verify backpressure and bounded retention.

AppKit alone writes the pasteboard. Explicit copy and permitted OSC 52 decisions
share ordering permits and external-clipboard-change checks. Named private
pasteboards isolate all clipboard tests from the user's clipboard.

Accessibility reports a contiguous physical UTF-16 range for linear selection,
including selected newlines and blank/clipped rows. Rectangles expose disjoint
ranges; their legacy singular range never encloses unselected text. Zero-width
linear endpoint markers preserve selected hard separators while painting no
cells. Same-row empty clicks remain unselected.

## Focused receipts

| Gate | Evidence |
|---|---|
| Final owner selection | `hard-boundary-source-receipt.json`, `hard-boundary-final.log`: pass, source hashes captured |
| Session and copy callback → PTY | `session-final-core6ae-*/`: pass, 19 owned children reaped |
| Final Session → AX round trip | `session-ax-range-final-*/`: pass on final integrated sources, independent publication/document counters; 19 owned children reaped |
| Private clipboard | `clipboard-access-tests.json`: all 26 checks pass, 12 owned children reaped |
| AX selection projection | `visible-links-final.*`: focused pass; exact source hashes recorded |
| Document ownership, oracle and reflow | `document-*-final-core6ae-*/`: pass, before/after hashes identical |
| Final native normal/editing/selection | `native-smoke.json`, `editing-smoke.json`, `selection-smoke.json`: 30/30, 14/14 and 16/16 pass |
| Private AppleScript fixture | `applescript-smoke.json`: preferences including word punctuation, bounded reads and command delivery pass; five PTY children and fixture exit |
| Tooling and syntax | `workflow-tests.log`, `lint.log`: pass |

The earlier Session/clipboard/document receipts identify the `6ae` selection
checkpoint. The later owner correction adds hard-newline endpoint publication;
its focused final receipt supersedes the prior `final-source-receipt.json`.
Earlier red receipts retain the pointer, empty-click, retirement and hard-newline
failures. A clipboard-fixture failure was corrected by selecting a nonempty
blank-cell range; an isolated AppKit probe found no difference between empty
`setData` and `setString`, so the canonical Data writer was retained.

Native integration exposed a separate proof-validation bug: the AX projection
compared the issued snapshot ID with the independently advancing document
revision. Real snapshots therefore rejected otherwise valid AX setters. The
corrected path checks its captured row/geometry proofs and leaves issuance
validation to the owner. A 191-versus-4 regression prevents fixtures from hiding
this distinction. Newline-only setters also resolve physical separators through
row boundaries, including completely blank rows.

`source-sha256.json` identifies the final integrated app inputs and exact
executable (`1ba249aca37b94dfed51ebac7c3f69d3b7340f53990c93464b5a895f024c3d45`).
All three native gates use that executable; the later automation build leaves
its hash identical. The selection runner records natural app exit and no cleanup
survivors. The installed app's live sessions were not targeted.

## Limits

Native tests inject AppKit events, not physical HID input. These checks do not
replace real VoiceOver, IME, multi-display or long-lived interaction validation.
Historical AX fetching and owner-side hyperlink activation proof remain separate
work. This is a development milestone, not full specification completion, and
does not change the installed notarized 0.2.0 app or frozen 0.2.1 release.
