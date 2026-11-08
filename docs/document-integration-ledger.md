# Terminal document integration ledger

This is a red/green ledger for the canonical `TerminalDocument` step in the
approved Swift-port plan. It is deliberately not a substitute for the frozen
86-case ledger: every row below maps directly to a Rust oracle that the rich
document must replay before this area can be marked green.

| Rust oracle | Required document behavior | Status |
| --- | --- | --- |
| `margins_origin_home_queries_validation_and_ansi_save_conflict` | screen-local margins, origin/CUP, saved cursor | green: `TerminalDocumentOracleTests.originHomeQueriesAndSaveConflict` |
| `regional_wrap_does_not_join_full_rows_or_touch_side_columns` | regional wrap preserves side cells | green: `TerminalDocumentOracleTests.regionalWrapAndMotions` |
| `rectangular_index_keeps_row_identity_side_cells_and_history` | regional scroll preserves row identity/history | green: `TerminalDocumentOracleTests.rectangularIndexIdentityAndNoHistory` |
| `rectangular_insert_delete_lines_and_bce` | blank cells inherit erase background | green: `TerminalDocumentOracleTests.rectangularInsertDeleteAndEraseBackground` |
| `horizontal_insert_delete_and_wide_edges` | insert/delete repairs wide pairs | green: `TerminalDocumentOracleTests.horizontalInsertDeleteAndWideEdges` |
| `rectangular_scroll_remaps_styles_links_clusters_and_protection` | rich payload survives rectangular scroll | green: `TerminalDocumentOracleTests.richRectangularScroll` |
| `screen_scope_reset_resize_and_margin_mode_disable` | screen-local reset/resize/margin policy | green: `TerminalDocumentOracleTests.screenScopeResetResizeAndMarginDisable` |
| `every_partition_and_ascii_scalar_paths_agree_with_rectangles` | protocol chunking reaches same document result | green: `TerminalDocumentOracleTests.chunkingAndRegionalTabs` |
| `carriage_return_backspace_and_tabs_respect_horizontal_region` | editing motions obey active region | green: `TerminalDocumentOracleTests.chunkingAndRegionalTabs` |
| `output_preserves_content_and_scroll_is_relative_to_current_anchor` | anchored viewport holds document identity | green: `TerminalViewportOracleTests.outputPreservesAnchor` |
| `eviction_clamps_once_without_leaving_anchored_mode` | history eviction atomically clamps anchor | green: `TerminalViewportOracleTests.evictionClampsOnce` |
| `alternate_has_no_history_and_retains_primary_view_for_return` | primary/alternate document separation | green: `TerminalViewportOracleTests.alternateRetainsPrimaryView` |
| `reflow_maps_leading_boundary_including_soft_wrap_and_wide_atoms` | resize maps wide-wrap anchor | green: `TerminalViewportOracleTests.richReflowMapsAnchorsAndWideAtoms` |
| `height_growth_clamps_to_legal_top_and_anchor_can_move_back_to_history` | resize remaps legal viewport top | green: `TerminalViewportOracleTests.heightGrowthAndEpochs` |
| `history_clear_and_reset_publish_distinct_identities_and_initial_colors` | reset/clear identity and palette transition | green: `TerminalViewportOracleTests.heightGrowthAndEpochs` |
| `publication_gate_does_not_rebase_anchor_and_invalid_resize_is_atomic` | failed resize leaves document/anchor intact | green: `TerminalViewportOracleTests.publicationGateAndAtomicInvalidResize` |
| `reflow_roundtrip_text` | rich reflow preserves logical text | green: `TerminalReflowSemanticTests` |
| `interior_edit_preserves_wrap_chain` | edit keeps soft-wrap chain validity | red |
| `osc133_prompt_*` reflow cases (10) | redraw=1 suffix clearing, anchor remapping, prefix/style/link and pending-wrap preservation | green: `TerminalPromptClearOracleTests` through Swift ABI |
| `display_clear.rs` cases (6) | prompt lifecycle/rebase, unmarked preservation, alternate no-op, modes/epochs and primary-only image cleanup | green: `TerminalPromptClearOracleTests` through Swift ABI |

`SwiftMarginGrid` and `SwiftReflow` are preparatory algorithms only. They may
not be marked green until the single document representation carries cell text,
kind, style, link, protection, flags, width continuations, row identity and
history/viewport ownership through the real emulator path.
