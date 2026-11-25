# C05 VT semantics disposition — 2026-11-17

Source triage uses the downloaded run `44069317138` (320 passed, 206 failed,
41 known bugs, 567 total) and its checked-out esctest2 expectations. These are
implementation dispositions. The integrated rerun at `b945624` passed 447 of
567, the run at `556aa51` passed 460 the run at `25d3add` passed 473, and the run at `c9b2eca` passed 460 after title reports were removed; see [conformance](../conformance.md).

## Concrete defects repaired

| Baseline failing cases | Behavior implemented | Focused regression |
| --- | --- | --- |
| `CUB_StopsAtLeftMarginInScrollRegion`, `CUF_StopsAtRightMarginInScrollRegion` | Relative movement stops at the directional margin when starting within it, or the page border when starting outside it. | `relativeMovementStopsAtMarginsAndIndexOutsideDoesNotScroll` |
| `FF`, `IND`, `LF`, `NEL`, `RI`, `VT` `MovesDoesNotScrollOutsideLeftRight` | At a vertical margin outside the horizontal region, index neither scrolls nor crosses the vertical margin. NEL indexes before returning to the left margin, preserving its original column for the scrolling decision. | Same regression, exercising forward and reverse index; `nextLineUsesOriginalColumnToDecideWhetherToScroll` |
| `CBT_IgnoresRegion` | Backward tab searches to the page's left edge. Forward HT/CHT still stop at the right margin. An existing contradictory oracle assertion is corrected. | `privateModeSaveRestoreAndBackwardTabsIgnoreLeftMargin` |
| `DECSEL_*_Protection` | DECSEL passes selective erasure through to the document, preserving DECSCA protection. | `selectiveAndISOProtectionAreIndependent` |
| `DECSEL_doesNotRespectISOProtect`, `DECSED_doesNotRespectISOProtect`, `DECSERA_doesNotRespectISOProtect`, `ECH/ED/EL_respectsISOProtection` | SPA/EPA is independent of DECSCA. Ordinary ED/EL/ECH honor ISO protection; DEC selective erasure honors only DEC protection. Both scalar and batched print paths retain ISO protection. | Same regression |
| `ED_3`, `DECSED_3`, `DECSED_3_Protection` | Parameter 3 erases saved lines and leaves the visible page intact. | `eraseSavedLinesPreservesVisiblePage` |
| `DECCRA_*`, `DECERA_*`, `DECFRA_*`, `DECSERA_*` | Rectangular copy, erase, fill and selective erase. Defaults, origin offsets, page clipping, invalid rectangles, overlapping copies and single-page handling are implemented. Row identities remain destination-owned; cut wide characters are repaired. | `rectanglesCopyOverlapsAndIgnoreMarginsUntilOriginMode`, `rectanglesClipAndRepairWidePairs` |
| `DECIC_*`, `DECDC_*` | Insert/delete columns across the vertical margin region, bounded by horizontal margins; no operation outside the region. | `columnEditsAndHorizontalIndexRespectRectangularMargins` |
| `DECBI_*`, `DECFI_*` | Backward/forward index shifts the rectangle at a horizontal margin and moves normally outside horizontal margins. | Same regression |
| `DECRC/SCORC/DECSETTiteInhibit_SaveRestoreCursor_Reset`, `DECSTR_CursorStaysPut`, `DECSTR_DECSC` | Soft reset keeps the live cursor and resets saved cursor state to home. | `softResetPreservesLiveCursorAndResetsSavedCursor` |
| `DECSET_SaveRestoreCursor`, `DECSETTiteInhibit_*` | Mode 1048 calls the same save/restore implementation as DECSC/DECRC and ANSI save/restore. Saved rendition, charset, origin, protection and deferred wrap are restored; reverse wrap and insert mode remain independent. | Same regression |
| `DECSET_ALTBUF`, `DECSET_OPT_ALTBUF` | 47 preserves alternate contents and carries the live cursor across the swap; 1047 additionally clears the alternate screen when leaving it; 1049 saves/restores the primary cursor and clears on entry. | `alternateScreenModesRetainTheirDistinctContracts` |
| `REP_DefaultParam` | Omitted and zero counts both mean one repetition. | `reverseWrapModesAndRepeatDefault` |
| `XtermSave_SaveSetState`, `XtermSave_SaveResetState` | Private mode save/restore stores recognized mutable modes with bounded storage. | `privateModeSaveRestoreAndBackwardTabsIgnoreLeftMargin` |
| `DECALN_ClearsMargins` integration regression | DECALN resets horizontal as well as vertical margins. Previously incorrect CUB behavior had concealed the stale horizontal region. | `screenAlignmentClearsAllMargins` |
| `ED_0` integration regression after `ECH_respectsISOProtection` | DECSTR disables ISO erasure protection without erasing the page, so the runner's subsequent ED2 clears protected content from the preceding test. SPA enables protection again; EPA only stops marking new cells. | `softResetDisablesISOEraseProtectionWithoutErasingPage` |
| `CUB_AfterNoWrappedInlines` | Whole-row erase clears the erased row's soft-wrap connection. Keeping its old connection when retaining row identity let reverse CUB cross into a previous logical line after ED2. | `eraseWholeRowsClearsSoftWrapConnections` |
| `DECSET_MoreFix` | Mode 41 makes HT/CHT consume pending wrap before searching the next tab stop. With the mode disabled, a tab at the right edge retains pending wrap for subsequent printing. | `cursesTabModeConsumesDeferredWrapOnlyWhenEnabled` |

## Disposition of the recorded ten VT failures

The coordinator's `e0f79b3` run recorded 440 passes, 88 failures and 39 known
bugs. Its ten VT-owned failures have these individual dispositions:

| Cases | Count | Disposition |
| --- | ---: | --- |
| `DECALN_ClearsMargins`, `ED_0`, `NEL_MovesDoesNotScrollOutsideLeftRight` | 3 | Concrete defects repaired in follow-up commits, with focused regressions. |
| `CUB_AfterNoWrappedInlines` | 1 | Concrete whole-row erasure metadata defect repaired; reverse-wrap mode 45 itself was correctly checking the row's soft-wrap flag. |
| `DECSET_MoreFix` | 1 | Mode 41 is now implemented, including preservation of pending wrap when the mode is disabled. |
| `DECSED_doesNotRespectISOProtect`, `DECSEL_doesNotRespectISOProtect` | 2 | **Unexpected passes in the xterm harness**, not failed character assertions. Both bodies complete successfully, then `knownBug(terminal="xterm")` raises `InternalError("Should have failed")` because Helge does not reproduce xterm's historical ISO/DEC protection coupling. Keep the independent protection semantics; report these as XPASS in conformance evidence rather than reintroducing the xterm behavior. |
| `DECSET_DECCOLM`, `DECSET_Allow80To132`, `RIS_ResetDECCOLM` | 3 | Intentional policy exclusions: each case requires child-controlled 80/132-column resizing, which this task explicitly prohibits. |

The rerun confirmed these dispositions: the repaired cases pass, the two
ISO-protection cases are reported as unexpected passes, and the three DECCOLM
cases fail by policy.

## Reverse-wrap version expectations

Modern xterm distinguishes mode 45 (traversal of wrapped rows) and mode 1045
(unrestricted reverse traversal within margins). Both are implemented. Deferred
wrap followed by BS consumes the pending-wrap state without moving a column
when reverse wrapping is enabled. Cursor-backward traversal is bounded by page
height; full-page cycles in mode 1045 are reduced arithmetically.

The downloaded suite's `ReverseWraparound()` helper selects **45** unless
`--xterm-reverse-wrap` is at least **383**, when it selects **1045**. Its older
expectations require mode 45 to perform unrestricted traversal, which conflicts
with modern mode 45. Run with the modern version option when evaluating
`BS_ReverseWrapGoesToBottom`, `BS_ReverseWrapWithLeftRight`,
`BS_ReversewrapFromLeftEdgeToRightMargin`, `BS_WrapsInWraparoundMode` and
`DECSET_ReverseWraparound_*`. `BS/CUB_AfterNoWrappedInlines` and
`BS/CUB_AfterOneWrappedInline` are also version-sensitive; compare their modern
branch individually. The local regression explicitly covers wrapped traversal,
stopping at an unwrapped row, pending wrap and unrestricted mode 1045.

Save/restore retains xterm's existing choice to save deferred wrap rather than
restoring the DECAWM mode itself. The VT510 manual describes an autowrap flag;
esctest deliberately expects different DECAWM behavior when its terminal is
`xterm`. This package preserves that practical compatibility choice.

## Explicitly retained exclusions and unsupported legacy features

| Cases | Disposition |
| --- | --- |
| `DECSET_DECCOLM`, `DECSET_Allow80To132`, `RIS_ResetDECCOLM` | Child-driven 80/132-column window resizing remains prohibited by the implementation contract. These are intentional policy failures. |
| `DECSCL_Level2DoesntSupportDECRQM`, `DSCSCL_Level3_SupportsDECRQMDoesntSupportDECSLRM`, `DECSCL_Level4_SupportsDECSLRMDoesntSupportDECNCSM` | Historical hardware conformance-level switching is unsupported. The terminal exposes its actual modern feature set rather than disabling queries/margins according to a simulated VT generation; the last case also requests prohibited column resizing. |
| Identity, color, DECRQM/DECRQSS/DECDSR, window/title query failures | Owned by protocol discovery. Do not hide them under this C05 disposition or change identity to satisfy xterm-specific equality checks. |
| Window manipulation and raw C1 expectations | Preserve the inventory's explicit exclusions. |

Primary references used for semantics:
[VT510 DECSC](https://vt100.net/docs/vt510-rm/DECSC.html),
[VT510 DECFI](https://vt100.net/docs/vt510-rm/DECFI.html), and
[xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html).
The ISO reset behavior follows xterm's
[terminal reset implementation](https://github.com/ThomasDickey/xterm-snapshots/blob/master/charproc.c),
which turns off erasure protection during both soft and hard reset while
retaining soft reset's screen contents.
The checked-out esctest2 files supply exact before/after fixtures for each table
row above.

## Verification

The `TerminalVTSemanticsTests`, `TerminalDocumentOracleTests`,
`TerminalDocumentOwnershipTests`, `TerminalSemanticRegressionTests`,
`TerminalReflowSemanticTests`, `TerminalSchedulerOracleTests` and
`TerminalSelectionTests` suites ran in the full `just test` gate at `5d46b01`,
and esctest ran at `b945624`, `648a83c` and `556aa51`.
