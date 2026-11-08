# `semantics.rs` mapping — Rust `a9b3c98`

This is a source-locked mapping of all 54 tests in
`crates/terminal-core/tests/semantics.rs` at immutable main commit
`a9b3c98`. “Green” means an actual Swift ABI/emulator oracle exercised the
observable behavior. Two Rust tests expose implementation controls rather than
an externally configurable protocol surface (`immutable_rows` and
`ascii_fast_path_matches_scalar`); their Swift mappings exercise the equivalent
observable guarantees without inventing a runtime toggle.

| Rust test | Swift evidence/status |
| --- | --- |
| `dec_special_graphics_complete_mapping_and_chunking` | Green — `TerminalSemanticRegressionTests.decCharsetPartitionsAndHistoryBounds`. |
| `deferred_wrap` | Green — `TerminalSemanticRegressionTests.deferredWrapLFAndUTF8`. |
| `every_byte_partition` | Green — `TerminalSemanticRegressionTests.bytePartitionsAgree`. |
| `malformed_utf8_maximal_subpart` | Green — `TerminalSemanticRegressionTests.utf8EOFEditingAndResetSemantics`. |
| `c1_not_reinterpreted` | Green — `TerminalSemanticRegressionTests.deferredWrapLFAndUTF8`. |
| `lf_is_not_cr` | Green — `TerminalSemanticRegressionTests.deferredWrapLFAndUTF8`. |
| `wide_repair_all_mutations` | Green — `TerminalDocumentOracleTests.horizontalInsertDeleteAndWideEdges`. |
| `wide_at_edge` | Green — `TerminalSemanticRegressionTests.displayClusterAndMalformedOSC`. |
| `combining_style_adjacency` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `unicode_clusters` | Green — `TerminalSemanticRegressionTests.clustersAndDiscardBound` exercises each source cluster through the ABI. |
| `alternate_idempotence_and_mixed` | Green — `TerminalSemanticRegressionTests.alternateAndStringSafety`. |
| `alternate_never_enters_history` | Green — `TerminalSemanticRegressionTests.alternateAndStringSafety`. |
| `ed2_vs_ed3` | Green — `TerminalSemanticRegressionTests.displayClusterAndMalformedOSC`. |
| `history_bounds` | Green — `TerminalSemanticRegressionTests.decCharsetPartitionsAndHistoryBounds` through the byte-limit ABI adapter. |
| `margins_no_history` | Green — `TerminalDocumentOracleTests.rectangularIndexIdentityAndNoHistory`. |
| `cursor_save_pending_and_pen` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `erase_background_only` | Green — `TerminalDocumentOracleTests.rectangularInsertDeleteAndEraseBackground`. |
| `color_syntax` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `overflow_invalidates_command` | Green — `TerminalSemanticRegressionTests.renditionSaveEraseAndOverflow`. |
| `string_discard_escape_cannot_inject` | Green — `TerminalSemanticRegressionTests.clustersAndDiscardBound` replays the 70 KiB bounded-discard fixture and post-ST suffix. |
| `string_escape_and_abort` | Green — `TerminalSemanticRegressionTests.alternateAndStringSafety`. |
| `sync_replies_deadline` | Green — `TerminalSchedulerOracleTests.synchronizedOutputUsesABIClockDeadline`. |
| `immutable_rows` | Green — `TerminalSemanticRegressionTests.snapshotsAreImmutableAndIngressIsPartitionIndependent` retains a binary-safe ABI snapshot across mutation; the Rust clone/COW mechanism has no separate ABI knob. |
| `keyboard_stacks_per_screen` | Green — `TerminalSchedulerOracleTests.keyboardFlagsAreScreenLocal`. |
| `input_modes_and_paste` | Green — `SwiftInputEncoderTests` and `SwiftCoreTests` through C input callbacks. |
| `resize_inactive_primary` | Green — `TerminalReflowSemanticTests`. |
| `reflow_roundtrip_text` | Green — `TerminalReflowSemanticTests`. |
| `random_byte_partition_and_invariants` | Green — `TerminalSemanticRegressionTests.randomPartitionsRetainInvariants` replays the source-seeded 20,000-byte transcript in 37-byte chunks and validates after each feed. |
| `parser_eof_drops_control` | Green — `TerminalSemanticRegressionTests.utf8EOFEditingAndResetSemantics`. |
| `geometry_rejected_without_mutation` | Green — `TerminalViewportOracleTests.publicationGateAndAtomicInvalidResize`. |
| `unicode_tables_are_pinned_to_18` | Green — `just swift-unicode18-corpus` strictly runs `SwiftUnicode.Segmenter` with the generated tables: 853 cases, 0 boundary failures. |
| `kitty_event_encoding` | Green — `SwiftInputEncoderTests`; compatibility ABI input path is covered by `SwiftCoreTests`. |
| `kitty_alternate_layout_and_modifier_events` | Green — `TerminalSemanticRegressionTests.physicalKeyMetadataUsesABI` via `terminal_input_with_metadata`. |
| `legacy_physical_keys_preserve_committed_text` | Green — `TerminalSemanticRegressionTests.physicalKeyMetadataUsesABI` via `terminal_input_with_metadata`. |
| `invalid_utf8_color_does_not_panic` | Green — `TerminalSemanticRegressionTests.displayClusterAndMalformedOSC`. |
| `ascii_fast_path_matches_scalar` | Green — `TerminalSemanticRegressionTests.snapshotsAreImmutableAndIngressIsPartitionIndependent` compares bulk and scalar ABI ingress for all three source fixtures; Swift intentionally has one parser path rather than a selectable fast-path flag. |
| `rep_yields_without_consuming_later_bytes` | Green — `TerminalSchedulerOracleTests.resumableREPDoesNotOvertakeSuffix`. |
| `scroll_closes_cluster_repair` | Green — `TerminalSemanticRegressionTests.displayClusterAndMalformedOSC`. |
| `interior_edit_preserves_wrap_chain` | Green — `TerminalSemanticRegressionTests.utf8EOFEditingAndResetSemantics`. |
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
| `ris_resets_both_cursor_appearances` | Green — `TerminalSemanticRegressionTests.utf8EOFEditingAndResetSemantics`. |
| `capped_grapheme_keeps_incremental_boundary_state` | Green — `TerminalSemanticRegressionTests.cappedGraphemeKeepsIncrementalBoundaryState`. |
| `widening_clipped_glyph_clears_clipping_flag` | Green — `TerminalSemanticRegressionTests.cursorAppearanceAndClippedWideRepair`. |

The source has 54 tests. This mapping records 54 green observable-behavior
mappings through the Swift ABI/emulator. It is a source-locked semantics gate,
not a claim of complete terminal-product parity beyond these fixtures.
