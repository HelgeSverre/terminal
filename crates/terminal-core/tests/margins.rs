use terminal_core::{
    Terminal,
    model::{CellKind, Color, RowDump},
};
fn feed(t: &mut Terminal, bytes: impl AsRef<[u8]>) {
    let bytes = bytes.as_ref();
    let mut offset = 0;
    while offset < bytes.len() || t.has_pending_work() {
        let n = t.feed(&bytes[offset..], 0);
        assert!(n > 0 || t.has_pending_work() || offset == bytes.len());
        offset += n;
        assert!(t.check_invariants());
    }
}
fn seed() -> Terminal {
    let mut t = Terminal::new(8, 4).unwrap();
    feed(
        &mut t,
        b"\x1b[1;1Hab0000yz\x1b[2;1Hcd1111wx\x1b[3;1Hef2222uv\x1b[4;1Hgh3333st",
    );
    t
}
fn lines(t: &Terminal) -> Vec<String> {
    t.screen().rows.iter().map(|r| r.copy_text()).collect()
}
fn semantic(t: &Terminal) -> serde_json::Value {
    serde_json::json!({
        "main":t.primary.rows.iter().map(|r|RowDump::from(r.as_ref())).collect::<Vec<_>>(),
        "alt":t.alternate.rows.iter().map(|r|RowDump::from(r.as_ref())).collect::<Vec<_>>(),
        "history":t.history.iter().map(|r|RowDump::from(r.as_ref())).collect::<Vec<_>>(),
        "main_cursor":t.primary.cursor,"alt_cursor":t.alternate.cursor,
        "main_margins":t.primary.horizontal_margins,"alt_margins":t.alternate.horizontal_margins,
        "vertical":t.screen().margins,"modes":t.modes,"pen":t.pen,"selected":t.is_alternate,"replies":t.replies
    })
}
#[test]
fn margins_origin_home_queries_validation_and_ansi_save_conflict() {
    let mut t = Terminal::new(10, 5).unwrap();
    feed(&mut t, b"\x1b[?69h\x1b[3;8s\x1b[2;4r\x1b[?6h");
    assert_eq!(t.screen().horizontal_margins, (2, 7));
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (1, 2));
    feed(&mut t, b"\x1b[3;4H\x1b7\x1b[99B\x1b[99C\x1b[6n");
    assert_eq!(t.take_replies(), [b"\x1b[3;6R".to_vec()]);
    feed(&mut t, b"\x1b[8;3s\x1b[1;99s");
    assert_eq!(t.screen().horizontal_margins, (2, 7));
    feed(&mut t, b"\x1b[s\x1b8");
    assert_eq!(t.screen().horizontal_margins, (0, 9));
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (3, 5));
    feed(&mut t, b"\x1b[3;8s\x1b[0;0s\x1b[0;0r");
    assert_eq!(t.screen().horizontal_margins, (0, 9));
    assert_eq!(t.screen().margins, (0, 4));
    feed(&mut t, b"\x1b[?69l\x1b[?69$p\x1b[2;2H\x1b[s\x1b[4;4H\x1b[u");
    assert_eq!(t.take_replies(), [b"\x1b[?69;2$y".to_vec()]);
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (1, 1));
}
#[test]
fn regional_wrap_does_not_join_full_rows_or_touch_side_columns() {
    let mut t = seed();
    feed(&mut t, b"\x1b[?69h\x1b[3;6s\x1b[?6h12345");
    assert_eq!(lines(&t), ["ab1234yz", "cd5111wx", "ef2222uv", "gh3333st"]);
    assert!(t.primary.rows[0].soft_next.is_none());
    feed(&mut t, b"\x1b[1;1H\x1b[?7lABCDE");
    assert_eq!(t.primary.rows[0].copy_text(), "abABCEyz");
    feed(&mut t, "猫");
    assert_eq!(t.primary.rows[0].cells[5].flags & 1, 1);
    assert_eq!(t.primary.rows[0].text(t.primary.rows[0].cells[6]), "y");
    feed(&mut t, "\x1b[?7h\x1b[1;4H❤\u{fe0f}");
    assert_eq!(t.primary.rows[0].cells[5].kind, CellKind::Empty);
    assert_eq!(t.primary.rows[1].cells[2].kind, CellKind::Lead2);
    assert_eq!(
        t.primary.rows[1].text(t.primary.rows[1].cells[2]),
        "❤\u{fe0f}"
    );
    assert!(t.history.is_empty());
    let first_line = t.primary.rows[0].copy_text();
    assert_eq!(first_line, "abABC yz");
    t.resize(10, 4).unwrap();
    assert_eq!(t.primary.rows[0].copy_text(), first_line);
}
#[test]
fn rectangular_index_keeps_row_identity_side_cells_and_history() {
    let mut t = seed();
    let ids: Vec<_> = t.primary.rows.iter().map(|r| r.id).collect();
    feed(&mut t, b"\x1b[?69h\x1b[3;6s\x1b[2;4r\x1b[4;3H\n");
    assert_eq!(lines(&t), ["ab0000yz", "cd2222wx", "ef3333uv", "gh    st"]);
    assert_eq!(t.primary.rows.iter().map(|r| r.id).collect::<Vec<_>>(), ids);
    assert!(t.history.is_empty());
    let before = lines(&t);
    feed(&mut t, b"\x1b[4;1H\n\x1b[2;1H\x1bM");
    assert_eq!(lines(&t), before);
    assert_eq!(t.screen().cursor.row, 0);
    feed(&mut t, b"\x1b[2;3H\x1bM");
    assert_eq!(lines(&t), ["ab0000yz", "cd    wx", "ef2222uv", "gh3333st"]);
}
#[test]
fn rectangular_insert_delete_lines_and_bce() {
    let mut t = seed();
    feed(
        &mut t,
        b"\x1b[?69h\x1b[3;6s\x1b[2;4r\x1b[3;4H\x1b[44m\x1b[L",
    );
    assert_eq!(lines(&t), ["ab0000yz", "cd1111wx", "ef    uv", "gh2222st"]);
    assert_eq!(t.screen().cursor.col, 2);
    for c in 2..6 {
        assert_eq!(
            t.primary.rows[2]
                .style(t.primary.rows[2].cells[c])
                .background,
            Color::Indexed(4)
        );
    }
    feed(&mut t, b"\x1b[M");
    assert_eq!(lines(&t), ["ab0000yz", "cd1111wx", "ef2222uv", "gh    st"]);
    let before = lines(&t);
    feed(&mut t, b"\x1b[3;1H\x1b[L\x1b[M");
    assert_eq!(lines(&t), before);
}
#[test]
fn horizontal_insert_delete_and_wide_edges() {
    let mut t = Terminal::new(8, 3).unwrap();
    feed(&mut t, b"ABCDWXYZ\x1b[?69h\x1b[3;6s\x1b[4G\x1b[@");
    assert_eq!(t.primary.rows[0].copy_text(), "ABC DWYZ");
    feed(
        &mut t,
        b"\x1b[?69l\x1b[1GABCDWXYZ\x1b[?69h\x1b[3;6s\x1b[4G\x1b[2P",
    );
    assert_eq!(t.primary.rows[0].copy_text(), "ABCX  YZ");
    feed(&mut t, b"\x1b[8G!");
    assert!(t.screen().cursor.pending_wrap);
    feed(&mut t, b"\x1b[P");
    assert!(t.screen().cursor.pending_wrap);
    feed(&mut t, b"\x1b[@");
    assert!(!t.screen().cursor.pending_wrap);
    feed(
        &mut t,
        "\x1b[?69l\x1b[2J\x1b[2;2H猫\x1b[?69h\x1b[3;6s\x1b[S",
    );
    assert_eq!(t.primary.rows[0].cells[2].kind, CellKind::Empty);
    assert_eq!(t.primary.rows[1].cells[1].kind, CellKind::Empty);
}
#[test]
fn rectangular_scroll_remaps_styles_links_clusters_and_protection() {
    let mut t = Terminal::new(8, 3).unwrap();
    feed(
        &mut t,
        "\x1b[2;3H\x1b[38;2;10;20;30m\x1b[1\"q\x1b]8;;https://example.test/\x1b\\猫é\x1b]8;;\x1b\\\x1b[0m\x1b[?69h\x1b[3;7s",
    );
    let retained = t.primary.rows[1].clone();
    feed(&mut t, b"\x1b[S");
    let row = &t.primary.rows[0];
    assert_eq!(row.text(row.cells[2]), "猫");
    assert_eq!(row.text(row.cells[4]), "é");
    assert_eq!(row.style(row.cells[2]).foreground, Color::Rgb(10, 20, 30));
    assert_eq!(
        row.link(row.cells[2]).as_deref(),
        Some("https://example.test/")
    );
    assert_eq!(row.cells[2].flags & 2, 2);
    assert_eq!(row.cells[3].flags & 2, 2);
    assert_eq!(retained.text(retained.cells[2]), "猫");
    assert!(t.history.is_empty());
}
#[test]
fn screen_scope_reset_resize_and_margin_mode_disable() {
    let mut t = Terminal::new(8, 3).unwrap();
    feed(&mut t, b"\x1b[?69h\x1b[3;6s\x1b[?47h\x1b[2;7s\x1b[?47l");
    assert_eq!(t.primary.horizontal_margins, (2, 5));
    assert_eq!(t.alternate.horizontal_margins, (1, 6));
    feed(&mut t, b"\x1b[?69l");
    assert_eq!(t.primary.horizontal_margins, (0, 7));
    assert_eq!(t.alternate.horizontal_margins, (0, 7));
    feed(&mut t, b"\x1b[?69h\x1b[3;6s");
    t.resize(9, 4).unwrap();
    assert_eq!(t.primary.horizontal_margins, (0, 8));
    assert_eq!(t.alternate.horizontal_margins, (0, 8));
    feed(&mut t, b"\x1b[3;6s\x1b[!p");
    assert!(!t.modes.left_right_margins);
    assert_eq!(t.primary.horizontal_margins, (0, 8));
    feed(&mut t, b"\x1b[?69h\x1b[3;6s\x1bc");
    assert!(!t.modes.left_right_margins);
    assert_eq!(t.primary.horizontal_margins, (0, 8));
}
#[test]
fn every_partition_and_ascii_scalar_paths_agree_with_rectangles() {
    let fixture="abcdefgh\x1b[2;1Hijklmnop\x1b[3;1Hqrstuvwx\x1b[?69h\x1b[3;6s\x1b[?6h12345猫é\x1b[1;1H\x1b[@Z\x1b[2P\x1b[S\x1b[T\x1b[L\x1b[M\x1b[2;2H\r\n\x1b[6n\x1b[?69$p".as_bytes();
    let mut expected = Terminal::new(8, 4).unwrap();
    feed(&mut expected, fixture);
    for split in 0..=fixture.len() {
        let mut t = Terminal::new(8, 4).unwrap();
        feed(&mut t, &fixture[..split]);
        feed(&mut t, &fixture[split..]);
        assert_eq!(semantic(&t), semantic(&expected), "split {split}");
    }
    let mut scalar = Terminal::new(8, 4).unwrap();
    scalar.ascii_fast_path = false;
    feed(&mut scalar, fixture);
    assert_eq!(semantic(&scalar), semantic(&expected));
}

#[test]
fn carriage_return_backspace_and_tabs_respect_horizontal_region() {
    let mut t = Terminal::new(20, 3).unwrap();
    feed(&mut t, b"\x1b[?69h\x1b[5;13s\x1b[1;7H\r\x08");
    assert_eq!(t.screen().cursor.col, 4);
    feed(&mut t, b"\t");
    assert_eq!(t.screen().cursor.col, 8);
    feed(&mut t, b"\t");
    assert_eq!(t.screen().cursor.col, 12);
    feed(&mut t, b"\x1b[2Z");
    assert_eq!(t.screen().cursor.col, 4);
    feed(&mut t, b"\x1b[1;2H\r");
    assert_eq!(t.screen().cursor.col, 0);
    feed(&mut t, b"\x1b[?6h\x1b[1;2H");
    assert_eq!(t.screen().cursor.col, 5);
    feed(&mut t, b"\x1b[2G");
    assert_eq!(t.screen().cursor.col, 5);
}
