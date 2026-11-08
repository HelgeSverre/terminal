# `semantics.rs` mapping — Rust `a9b3c98`

This is a source-locked mapping of all 54 tests in
`crates/terminal-core/tests/semantics.rs` at immutable main commit
`a9b3c98`. “Green” means an actual Swift ABI/emulator oracle exercised the
observable behavior. “Gap” is deliberately not counted as parity; it records
either an unimplemented observable behavior or a Rust-only internal toggle
that the current C ABI cannot express.

| Rust test | Swift evidence/status |
| --- | --- |
| `dec_special_graphics_complete_mapping_and_chunking` | Gap — DEC G0/G1 charset designation is not implemented. |
| `deferred_wrap` | Green — `TerminalSemanticRegressionTests.deferredWrapLFAndUTF8`. |
| `every_byte_partition` | Partial — fixture-wide semantic equality is not yet replayed; the frozen five-fixture partition gate is green separately. |
| `malformed_utf8_maximal_subpart` | Gap — full maximal-subpart fixture remains unported. |
| `c1_not_reinterpreted` | Green — `TerminalSemanticRegressionTests.deferredWrapLFAndUTF8`. |
| `lf_is_not_cr` | Green — `TerminalSemanticRegressionTests.deferredWrapLFAndUTF8`. |
| `wide_repair_all_mutations` | Green — `TerminalDocumentOracleTests.horizontalInsertDeleteAndWideEdges`. |
| `wide_at_edge` | Partial — edge placement is covered by margin scenarios; exact WrapSpacer fixture still needs a dedicated replay. |
| `combining_style_adjacency` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `unicode_clusters` | Partial — Swift Unicode smoke covers representative clusters; Unicode 18 corpus remains incomplete. |
| `alternate_idempotence_and_mixed` | Green — `TerminalSemanticRegressionTests.alternateAndStringSafety`. |
| `alternate_never_enters_history` | Green — `TerminalSemanticRegressionTests.alternateAndStringSafety`. |
| `ed2_vs_ed3` | Partial — viewport history-clear oracle covers ED3; ED2 distinction needs a direct replay. |
| `history_bounds` | Gap — row limit exists, but the Rust byte-limit control has no ABI adapter. |
| `margins_no_history` | Green — `TerminalDocumentOracleTests.rectangularIndexIdentityAndNoHistory`. |
| `cursor_save_pending_and_pen` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `erase_background_only` | Green — `TerminalDocumentOracleTests.rectangularInsertDeleteAndEraseBackground`. |
| `color_syntax` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `overflow_invalidates_command` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `string_discard_escape_cannot_inject` | Green — `TerminalSemanticRegressionTests.alternateAndStringSafety` covers APC injection; oversized discard limit remains separately unmeasured. |
| `string_escape_and_abort` | Green — `TerminalSemanticRegressionTests.alternateAndStringSafety`. |
| `sync_replies_deadline` | Green — `TerminalSchedulerOracleTests.synchronizedOutputUsesABIClockDeadline`. |
| `immutable_rows` | ABI gap — immutable row sharing is an internal ownership property; snapshots remain value projections but no retained-row ABI exists. |
| `keyboard_stacks_per_screen` | Green — `TerminalSchedulerOracleTests.keyboardFlagsAreScreenLocal`. |
| `input_modes_and_paste` | Green — `SwiftInputEncoderTests` and `SwiftCoreTests` through C input callbacks. |
| `resize_inactive_primary` | Green — `TerminalReflowSemanticTests`. |
| `reflow_roundtrip_text` | Green — `TerminalReflowSemanticTests`. |
| `random_byte_partition_and_invariants` | Gap — random 20,000-byte transcript/invariant replay is not yet ported. |
| `parser_eof_drops_control` | ABI gap — parser operation stream is not exported; terminal EOF behavior needs a transcript adapter. |
| `geometry_rejected_without_mutation` | Green — `TerminalViewportOracleTests.publicationGateAndAtomicInvalidResize`. |
| `unicode_tables_are_pinned_to_18` | Gap — generated tables are present but official corpus is not fully passing. |
| `kitty_event_encoding` | Green — `SwiftInputEncoderTests`; compatibility ABI input path is covered by `SwiftCoreTests`. |
| `kitty_alternate_layout_and_modifier_events` | ABI gap — C input accepts legacy key IDs/text only, not physical-key metadata. |
| `legacy_physical_keys_preserve_committed_text` | ABI gap — C input accepts committed text, not Rust `KeyMetadata`. |
| `invalid_utf8_color_does_not_panic` | Partial — no-panic string handling is covered; exact OSC 10 malformed-color case still needs replay. |
| `ascii_fast_path_matches_scalar` | Internal-toggle gap — Swift has no separately selectable ASCII path. |
| `rep_yields_without_consuming_later_bytes` | Green — `TerminalSchedulerOracleTests.resumableREPDoesNotOvertakeSuffix`. |
| `scroll_closes_cluster_repair` | Gap — exact cluster-repair scroll transcript remains unported. |
| `interior_edit_preserves_wrap_chain` | Gap — tracked red in `document-integration-ledger.md`. |
| `selective_erase_protects_whole_wide_glyph` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `osc133_prompt_is_cleared_before_reflowed_shell_redraw` | Green — `TerminalPromptClearOracleTests`. |
| `plain_osc133_prompt_is_preserved_across_reflow` | Green — `TerminalPromptClearOracleTests`. |
| `redrawable_prompt_reflow_preserves_prefix_before_mid_row_marker` | Green — `TerminalPromptClearOracleTests`. |
| `redrawable_prompt_after_full_width_prefix_preserves_the_last_cell` | Green — `TerminalPromptClearOracleTests`. |
| `redrawable_prompt_after_full_width_wide_prefix_survives_shrink_and_grow` | Green — `TerminalPromptClearOracleTests`. |
| `redrawable_prompt_boundary_survives_shrink_then_grow` | Green — `TerminalPromptClearOracleTests`. |
| `redrawable_primary_prompt_survives_alternate_screen_resize` | Green — `TerminalPromptClearOracleTests`. |
| `pixel_only_resize_does_not_clear_redrawable_prompt` | Green — `TerminalPromptClearOracleTests`. |
| `evicted_prompt_marker_is_not_rebound_to_live_row_zero` | Green — `TerminalPromptClearOracleTests`. |
| `prompt_reflow_clear_keeps_pre_prompt_output_and_stops_after_command_start` | Green — `TerminalPromptClearOracleTests`. |
| `saved_cursor_excludes_appearance` | Green — `TerminalSemanticRegressionTests.cursorAppearanceAndClippedWideRepair`. |
| `ris_resets_both_cursor_appearances` | Partial — RIS resets active ABI appearance; exact both-screen replay remains to add. |
| `capped_grapheme_keeps_incremental_boundary_state` | Gap — 64-scalar cluster cap/flag behavior is not implemented. |
| `widening_clipped_glyph_clears_clipping_flag` | Green — `TerminalSemanticRegressionTests.cursorAppearanceAndClippedWideRepair`. |

The source has 54 tests. This mapping records 35 green test mappings, 6
partial mappings, and 13 gaps/ABI gaps. It is not a parity claim.
