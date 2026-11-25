# Swift replacement audit and next ownership steps

Source review: `a723946`, followed by the graphics/snapshot corrections in
`ce3e949`, geometry guards in `a810c21`/`d174f7e`, and reply admission in
`2d85516`. This is a scoped release plan, not a declaration of full parity.
The Rust snapshot branch remains the behavioral reference and rollback source.
Items below describe the audited gaps and their required closure evidence;
concurrent protocol work must be assessed at its committed checkpoint.

## Required before replacement

1. **Finish protocol-state parity.** `SwiftTerminalCore.setMode` omits mouse
   tracking modes 9/1000/1002/1003 and SGR mouse 1006, while snapshot metadata
   hardcodes them off. `Canvas.reportMouse` consumes those fields, so this is
   an actual application regression. Kitty `>u`/`<u` need the Rust bounded
   per-screen push/pop stack; `=u` needs set/add/remove semantics. RIS must
   reset input modes and repeat state, while preserving title/directory as
   Rust does. Mutable tab stops and their clear/set commands are also absent.
   Use byte-exact ABI transcripts against the retained Rust implementation;
   the existing 54-case ledger does not cover these missing transitions.
2. **Close the graphics review findings.** The new mandatory graphics ABI
   suite covers lifecycle, row anchors, snapshots, cropped/aspect placement,
   explicit/anonymous IDs, PNG samples, chunking and dmscene. Independent
   review additionally identified the 4096 per-axis limit and unsupported
   transport fields/quiet values. The follow-up now has independent failing
   controls and a passing 17-group ABI suite, recorded in
   `reports/swift-graphics-parity/transport-followup.json`. PNG text/profile
   metadata is filtered before ImageIO. Bounded placement IDs may retire
   lazily before graphics commands; visibility still rejects missing anchors.
   Successful dmscene alone is insufficient resource/protocol evidence.
3. **Freeze and validate the final integrated source.** Run the mandatory
   suites, the 270-record compatibility comparison, native host/accessibility/
   automation checks, and the actual application stress cases. Height-only
   resize now deliberately preserves row identities like Rust; distinguish
   intentional fixes from accidental changes when comparing old Swift output.
4. **Meet the user's performance gate on the replacement candidate.** Each
   of short ASCII, long ASCII, ANSI and Unicode must reach at least 70% of
   matched Rust throughput; 80% is the stretch goal. Keep earlier `868` results
   source-specific. Require complete 8 GB primary-history ingestion within
   the chosen timeout, bounded history, responsive interaction and clean
   process exit. A timeout after reading only a prefix is a failed full-file
   test even when the history cap holds.
5. **Publish a current evidence ledger.** At this audit, `swift-port-parity.md` says
   715/853 Unicode and unintegrated search; `swift-oracle-ledger.json` still
   marks implemented cases unported. Replace those current-status claims with
   links to source-frozen evidence, keeping historical measurements labeled.
   The old differential tool's hardcoded Swift source list omits current
   dependencies; consume `tools/swift-sources.json` before using it as a gate.

## Small, independent work assignments

| Owner scope | Concrete result | Required interface evidence |
| --- | --- | --- |
| Protocol state: emulator, screen-local keyboard state, input tests | Mouse negotiation, keyboard stacks, reset and tabs have one authoritative state; metadata and input encoding read it | Exact replies/input bytes and state transitions; primary/alternate and reset cases |
| Graphics: graphics store and ABI tests | Checked transport admission, immutable image generations and row-ID placements; no graphics position guessed from live row numbers | Malformed input is atomic; bounded upload, expiry/abort, eviction, resize, clear and dmscene |
| Test/build tooling: source manifest, recipes, differential runner, status ledger | One source graph; no obsolete margin/reflow/JSON bridge implementations in app build; all claimed gates reproducible | Graph verification and actual invoked tests, not orphan executables |
| Root: final artifact and runs | One frozen candidate with native correctness, full SQL completion and four-workload ratios | Source/executable hashes, input sizes, exact accepted bytes, final drain, matched run order and cleanup |

These tasks can proceed independently except shared source-graph edits, which
need one writer at a time. No parallel worker should edit the emulator while
its protocol owner is implementing state transitions.

## Meaningful naming without another rewrite

The glossary already defines **terminal emulator**, **terminal document**,
**history**, **viewport**, **snapshot**, **image resource** and **image placement**.
Use those terms rather than Core/Engine/Manager. Perform mechanical names and
file moves in a separate commit after correctness work:

| Existing source | Intended name / disposition |
| --- | --- |
| `SwiftTerminalCore.swift` / `SwiftTerminalCore` | `TerminalEmulator.swift` / `TerminalEmulator`; keep ordered VT interpretation together |
| Bottom-of-file C exports and borrowed cell allocation | `Compatibility/TerminalABI.swift`; temporary adapter, with original symbols intact |
| `TerminalDocument.swift`, `DocumentReflow.swift` | Keep these meaningful names; reflow is the document's implementation, not a second public model |
| `SwiftGraphics.swift` | `KittyGraphics.swift`; keep protocol validation, decoded resources and placements together |
| `SwiftSearchViewport.swift` | `HistorySearch.swift`; its worker matches immutable pages, while viewport policy belongs to the document |
| `SwiftInputEncoder.swift` | `TerminalInput.swift`; negotiated byte encoding belongs together |
| `SwiftUnicode.swift`, generated grapheme tables | `TerminalText.swift`, `Unicode18GraphemeTables.swift`; preserve pinned behavior |
| Width and lowercase tables | Keep distinct width/search owners and explicit Unicode versions; search lowercase is pinned to Rust Unicode17, not Unicode18 |
| Snapshot value declarations currently inside `Session.swift` | `TerminalSnapshot.swift`; the session schedules publication but does not own the presentation schema |
| Standalone `SwiftMargins`, `SwiftReflow`, `SwiftSnapshotBridge` | Remove superseded models after moving useful scenarios to the actual document/bridge gate |

Start with `native/Emulation`, `native/Compatibility`, and `native/Presentation`
only where they describe actual ownership. Keep one Swift compiler module
initially. Do not combine file moves, package splitting and semantic edits.

## The next deepening seam after acceptance

The large full-grid JSON round trip is gone. The app still copies terminal
strings into C views, copies them back into Swift snapshot cells, and encodes/
decodes metadata JSON. A later direct immutable Swift snapshot should replace
that adapter in `Session`, while retaining it for the Rust oracle and C tests.
Move snapshot value definitions first, then expose a typed snapshot operation
on the emulator. It must select owner or explicit-offset content once and own
rows, image data/generations, metadata and search decorations through consumer
release. No mutable row storage or actor hop per character crosses this seam.

Viewport identity, history limits and their clamp/epoch effects are still split
between `TerminalDocument`/`TerminalHistory` and the emulator. Deepen the
document with operations that commit content and retention before resolving
its viewport. Avoid a forwarding viewport class or a generic mutable-grid
callback: both leave the difficult ordering rules with callers. Keep the
existing value/COW row storage and unified printing transaction.

These ownership changes are valuable cleanup; they are not substitutes for
the release gates above and need not block a replacement that already passes
correctness and the agreed real-application performance criteria.
