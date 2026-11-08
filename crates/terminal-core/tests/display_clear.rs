use terminal_core::{Terminal, display_clear::DisplayClear, model::PromptAnchor};
fn feed(t: &mut Terminal, text: &str) {
    let mut bytes = text.as_bytes();
    while !bytes.is_empty() || t.has_pending_work() {
        let count = t.feed(bytes, 0);
        assert!(count > 0 || t.has_pending_work());
        bytes = &bytes[count..];
    }
    assert!(t.check_invariants());
}
#[test]
fn prompt_clear_is_local_and_requests_redraw_without_resetting_terminal_modes() {
    let mut t = Terminal::new(8, 3).unwrap();
    feed(
        &mut t,
        "old\r\nold\r\nold\r\n\x1b]133;A\x07prompt>\x1b]133;B\x07\x1b[?2004h\x1b[>3u",
    );
    t.scroll_view(1);
    let before = t.view_snapshot().unwrap();
    assert_eq!(t.clear_display(), DisplayClear::RedrawPrompt);
    let after = t.view_snapshot().unwrap();
    assert!(after.following_tail && after.at_prompt);
    assert_eq!(after.history_rows, 0);
    assert_eq!((after.cursor.row, after.cursor.col), (0, 0));
    assert!(
        after
            .rows
            .iter()
            .flat_map(|r| &r.cells)
            .all(|c| c.text.is_empty())
    );
    assert_eq!(before.modes, after.modes);
    assert_eq!(t.primary.keyboard_flags, 3);
    assert_eq!(after.document_epoch, before.document_epoch);
    assert_eq!(after.history_epoch, before.history_epoch + 1);
    assert!(after.screen_epoch > before.screen_epoch);
    assert!(t.replies.is_empty()); // The host, not the reply queue, redraws the shell.
    assert!(t.check_invariants());
}
#[test]
fn prompt_clear_rebases_a_redrawable_prompt_anchor_for_later_reflow() {
    let mut t = Terminal::new(64, 12).unwrap();
    feed(
        &mut t,
        "\x1b]133;A;redraw=1\x07RESIZE_PROMPT\r\n> RESIZE_BUFFER\x1b[K\x1b[46CRESIZE_RPROMPT\x1b[60D",
    );
    assert!(t.primary.prompt_redraw);
    assert_eq!(t.clear_display(), DisplayClear::RedrawPrompt);
    assert_eq!(
        t.primary.prompt_start,
        Some(PromptAnchor {
            row: t.primary.rows[0].id,
            col: 0,
            pending_wrap: false,
        })
    );
    let wide_redraw =
        "\r\r\x1b[A\x1b[JRESIZE_PROMPT\r\n> RESIZE_BUFFER\x1b[K\x1b[80CRESIZE_RPROMPT\x1b[94D";
    let narrow_redraw = "\r\r\x1b[A\x1b[JRESIZE_PROMPT\r\n> RESIZE_BUFFER";
    for _ in 0..5 {
        t.resize(111, 12).unwrap();
        feed(&mut t, wide_redraw);
        t.resize(17, 12).unwrap();
        feed(&mut t, narrow_redraw);
        assert_eq!(t.copy_all().matches("RESIZE_PROMPT").count(), 1);
    }
    assert!(t.check_invariants());
}
#[test]
fn unmarked_program_preserves_cursor_row_and_everything_below_it() {
    let mut t = Terminal::new(8, 4).unwrap();
    feed(&mut t, "old\r\ncurrent\r\nbelow\x1b[2;4H");
    let current = t.primary.rows[1].id;
    assert_eq!(t.clear_display(), DisplayClear::Cleared);
    assert_eq!(t.primary.rows[0].id, current);
    assert_eq!(t.primary.rows[0].copy_text(), "current");
    assert_eq!(t.primary.rows[1].copy_text(), "below");
    assert_eq!((t.primary.cursor.row, t.primary.cursor.col), (0, 3));
    assert!(t.replies.is_empty());
    assert!(t.check_invariants());
}
#[test]
fn alternate_clear_does_nothing_including_retained_primary_view_and_graphics() {
    let mut t = Terminal::new(8, 2).unwrap();
    feed(&mut t, "old\r\nold\r\nlast\x1b]133;A\x07");
    t.scroll_view(1);
    let primary = t.view_snapshot().unwrap();
    feed(&mut t, "\x1b[?1049hALT");
    let old = serde_json::to_value(t.snapshot(0)).unwrap();
    assert_eq!(t.clear_display(), DisplayClear::IgnoredAlternate);
    assert_eq!(serde_json::to_value(t.snapshot(0)).unwrap(), old);
    feed(&mut t, "\x1b[?1049l");
    let returned = t.view_snapshot().unwrap();
    assert_eq!(returned.rows, primary.rows);
    assert_eq!(returned.scroll_offset, primary.scroll_offset);
}
#[test]
fn osc133_prompt_phase_requires_line_init_and_resets_on_command_or_reset() {
    let mut t = Terminal::new(8, 2).unwrap();
    for (marker, at_prompt, input_ready) in [
        ("A", true, false),
        ("B", true, true),
        ("C", false, false),
        ("A;k=v", true, false),
        ("B", true, true),
        ("D;0", false, false),
    ] {
        feed(&mut t, &format!("\x1b]133;{marker}\x07"));
        let snapshot = t.snapshot(0).unwrap();
        assert_eq!(snapshot.at_prompt, at_prompt);
        assert_eq!(snapshot.input_ready, input_ready);
    }
    feed(&mut t, "\x1b]133;A\x07\x1b]133;B\x07\x1b[?1049h");
    let alternate = t.snapshot(0).unwrap();
    assert!(!alternate.at_prompt && !alternate.input_ready);
    feed(&mut t, "\x1b[?1049l");
    let primary = t.snapshot(0).unwrap();
    assert!(primary.at_prompt && primary.input_ready);
    feed(&mut t, "\x1bc");
    let reset = t.snapshot(0).unwrap();
    assert!(!reset.at_prompt && !reset.input_ready);
    assert!(!t.primary.prompt_redraw);
    assert!(t.primary.prompt_start.is_none());
}
#[test]
fn clear_drops_primary_images_but_preserves_other_screen_resources() {
    let mut t = Terminal::new(8, 3).unwrap();
    feed(&mut t, "\x1b_Ga=T,f=24,s=1,v=1,i=1,C=1;AQID\x1b\\");
    feed(
        &mut t,
        "\x1b[?1049h\x1b_Ga=T,f=24,s=1,v=1,i=2,C=1;BAUG\x1b\\\x1b[?1049l",
    );
    assert_eq!(t.clear_display(), DisplayClear::Cleared);
    assert!(t.snapshot(0).unwrap().images.is_empty());
    feed(&mut t, "\x1b_Ga=p,i=1,C=1\x1b\\");
    assert!(t.snapshot(0).unwrap().images.is_empty());
    feed(&mut t, "\x1b[?47h");
    assert_eq!(t.snapshot(0).unwrap().images[0].image, 2);
}
