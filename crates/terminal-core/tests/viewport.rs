use terminal_core::{Terminal, model::Snapshot};

fn feed(t: &mut Terminal, text: &str) {
    let mut bytes = text.as_bytes();
    while !bytes.is_empty() || t.has_pending_work() {
        let count = t.feed(bytes, 0);
        assert!(count > 0 || t.has_pending_work());
        bytes = &bytes[count..];
    }
    assert!(t.check_invariants());
}
fn lines(snapshot: &Snapshot) -> Vec<String> {
    snapshot
        .rows
        .iter()
        .map(|row| row.cells.iter().map(|cell| cell.text.as_str()).collect())
        .collect()
}
fn history() -> Terminal {
    let mut t = Terminal::new(8, 3).unwrap();
    feed(&mut t, "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive");
    t
}

#[test]
fn output_preserves_content_and_scroll_is_relative_to_current_anchor() {
    let mut t = history();
    t.scroll_view(2);
    let first = t.view_snapshot().unwrap();
    assert_eq!(lines(&first), ["one", "two", "three"]);
    assert!(!first.following_tail);
    feed(&mut t, "\r\nsix\r\nseven");
    let later = t.view_snapshot().unwrap();
    assert_eq!(lines(&first), lines(&later));
    assert_eq!(later.scroll_offset, first.scroll_offset + 2);
    t.scroll_view(-1);
    assert_eq!(lines(&t.view_snapshot().unwrap()), ["two", "three", "four"]);
    t.scroll_view(i64::MIN);
    assert!(t.view_snapshot().unwrap().following_tail);
    t.scroll_view(i64::MAX);
    assert_eq!(t.view_snapshot().unwrap().scroll_offset, t.history.len());
}

#[test]
fn eviction_clamps_once_without_leaving_anchored_mode() {
    let mut t = history();
    t.history_limit = 3;
    t.scroll_view(3);
    let before = t.view_snapshot().unwrap();
    feed(&mut t, "\r\nsix\r\nseven");
    let after = t.view_snapshot().unwrap();
    assert_eq!(lines(&after), ["two", "three", "four"]);
    assert!(!after.following_tail);
    assert_eq!(
        after.viewport_clamp_revision,
        before.viewport_clamp_revision + 1
    );
    assert_eq!(
        t.view_snapshot().unwrap().viewport_clamp_revision,
        after.viewport_clamp_revision
    );
    t.history_limit = 0;
    t.enforce_history();
    let empty_history = t.view_snapshot().unwrap();
    assert_eq!(empty_history.scroll_offset, 0);
    assert!(!empty_history.following_tail);
    t.scroll_view(-1);
    assert!(t.view_snapshot().unwrap().following_tail);
}

#[test]
fn alternate_has_no_history_and_retains_primary_view_for_return() {
    let mut t = history();
    t.scroll_view(2);
    let primary = t.view_snapshot().unwrap();
    feed(&mut t, "\x1b[?1049hALT");
    let alternate = t.view_snapshot().unwrap();
    assert!(alternate.following_tail && alternate.alternate);
    assert!(alternate.screen_epoch > primary.screen_epoch);
    t.scroll_view(100);
    t.follow_tail(); // Typing while alternate is selected does not lose primary.
    feed(&mut t, "\x1b[?1049l");
    let returned = t.view_snapshot().unwrap();
    assert_eq!(lines(&returned), lines(&primary));
    assert!(!returned.following_tail);
    feed(&mut t, "\x1b[?1049l"); // Idempotent selection does not replace identity.
    assert_eq!(
        t.view_snapshot().unwrap().screen_epoch,
        returned.screen_epoch
    );
    t.follow_tail();
    assert!(t.view_snapshot().unwrap().following_tail);
}

#[test]
fn reflow_maps_leading_boundary_including_soft_wrap_and_wide_atoms() {
    let mut t = Terminal::new(4, 2).unwrap();
    feed(&mut t, "abcdefghijkl\r\n猫猫猫猫\r\nlast");
    // Select the old 'efgh' row: widening joins it onto the first logical row.
    let index = t
        .history
        .iter()
        .position(|r| r.copy_text() == "efgh")
        .unwrap();
    t.set_view_offset(t.history.len() - index);
    t.resize(8, 2).unwrap();
    let wide = t.view_snapshot().unwrap();
    assert_eq!(lines(&wide)[0], "abcdefgh");
    assert!(!wide.following_tail);
    t.resize(4, 2).unwrap();
    assert_eq!(lines(&t.view_snapshot().unwrap())[0], "abcd");
    let index = t
        .history
        .iter()
        .position(|r| r.copy_text() == "猫猫")
        .unwrap();
    t.set_view_offset(t.history.len() - index);
    t.resize(3, 2).unwrap();
    assert_eq!(lines(&t.view_snapshot().unwrap())[0], "猫");
    assert!(t.check_invariants());
}

#[test]
fn height_growth_clamps_to_legal_top_and_anchor_can_move_back_to_history() {
    let mut t = history();
    t.scroll_view(1);
    t.resize(8, 6).unwrap();
    let grown = t.view_snapshot().unwrap();
    assert_eq!(grown.scroll_offset, 0);
    assert_eq!(lines(&grown)[0], "zero");
    assert!(!grown.following_tail);
    feed(&mut t, "\r\nsix");
    let later = t.view_snapshot().unwrap();
    assert_eq!(later.scroll_offset, 1);
    assert_eq!(lines(&later)[0], "zero");
}

#[test]
fn history_clear_and_reset_publish_distinct_identities_and_initial_colors() {
    let mut t = history();
    let fg = t.default_fg;
    let bg = t.default_bg;
    t.scroll_view(3);
    let old = t.view_snapshot().unwrap();
    feed(&mut t, "\x1b[3J");
    let clear = t.view_snapshot().unwrap();
    assert_eq!(clear.history_epoch, old.history_epoch + 1);
    assert_eq!(clear.document_epoch, old.document_epoch);
    assert!(!clear.following_tail);
    feed(&mut t, "\x1b]10;#ffffff\x07\x1bc");
    let reset = t.view_snapshot().unwrap();
    assert!(reset.following_tail);
    assert_eq!(reset.document_epoch, old.document_epoch + 1);
    assert!(reset.history_epoch > clear.history_epoch);
    assert!(reset.screen_epoch > clear.screen_epoch);
    assert_eq!((reset.default_fg, reset.default_bg), (fg, bg));
}

#[test]
fn publication_gate_does_not_rebase_anchor_and_invalid_resize_is_atomic() {
    let mut t = history();
    t.scroll_view(2);
    let before = t.view_snapshot().unwrap();
    feed(&mut t, "\x1b[?2026h\r\nsix");
    assert!(t.view_snapshot().is_none());
    assert!(t.resize(0, 3).is_err());
    feed(&mut t, "\x1b[?2026l");
    let after = t.view_snapshot().unwrap();
    assert_eq!(lines(&after), lines(&before));
    assert_eq!(after.geometry_epoch, before.geometry_epoch);
    assert_eq!(after.scroll_offset, before.scroll_offset + 1);
}
