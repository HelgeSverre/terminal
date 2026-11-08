use terminal_core::{
    Terminal,
    input::{Key, Modifiers},
    model::*,
    parser::{Operation, VtParser},
};
fn feed(t: &mut Terminal, bytes: impl AsRef<[u8]>) {
    let bytes = bytes.as_ref();
    let mut i = 0;
    while i < bytes.len() || t.has_pending_work() {
        let n = t.feed(&bytes[i..], 0);
        assert!(n > 0 || t.has_pending_work() || i == bytes.len());
        i += n;
    }
}
fn terminal(cols: usize, rows: usize, bytes: impl AsRef<[u8]>) -> Terminal {
    let mut t = Terminal::new(cols, rows).unwrap();
    feed(&mut t, bytes);
    assert!(t.check_invariants());
    t
}
fn lines(t: &Terminal) -> Vec<String> {
    t.screen().rows.iter().map(|r| r.copy_text()).collect()
}
fn semantic(t: &Terminal) -> serde_json::Value {
    serde_json::json!({"main":t.primary.rows.iter().map(|r|RowDump::from(r.as_ref())).collect::<Vec<_>>(),"alt":t.alternate.rows.iter().map(|r|RowDump::from(r.as_ref())).collect::<Vec<_>>(),"history":t.history.iter().map(|r|RowDump::from(r.as_ref())).collect::<Vec<_>>(),"main_cursor":t.primary.cursor,"alt_cursor":t.alternate.cursor,"modes":t.modes,"pen":t.pen,"selected":t.is_alternate,"replies":t.replies,"title":t.title})
}
#[test]
fn dec_special_graphics_complete_mapping_and_chunking() {
    // DEC VT220 special graphics, using the Unicode mapping documented by
    // https://teratermproject.github.io/manual/5/en/about/emulations_dec_special.html
    let source = "_`abcdefghijklmnopqrstuvwxyz{|}~";
    let expected = "\u{a0}◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·";
    for designation in ["\x1b(0", "\x1b)0\x0e"] {
        let input = format!("{designation}{source}\x0f\x1b(B{source}");
        for split in 0..=input.len() {
            let mut t = Terminal::new(64, 2).unwrap();
            feed(&mut t, &input.as_bytes()[..split]);
            feed(&mut t, &input.as_bytes()[split..]);
            let row = &t.screen().rows[0];
            let cells = &row.cells;
            let mapped: String = cells[..32].iter().map(|c| row.text(*c)).collect();
            let ascii: String = cells[32..64].iter().map(|c| row.text(*c)).collect();
            assert_eq!(
                mapped, expected,
                "designation {designation:?}, split {split}"
            );
            assert_eq!(ascii, source);
            assert!(cells.iter().all(|c| c.kind == CellKind::Lead1));
            assert!(t.check_invariants());
        }
    }
}
#[test]
fn deferred_wrap() {
    for (bytes, expected, row, col, pending) in [
        ("abcd", vec!["abcd", ""], 0, 3, true),
        ("abcde", vec!["abcd", "e"], 1, 1, false),
        ("abcd\rZ", vec!["Zbcd", ""], 0, 1, false),
        ("abcd\x08Z", vec!["abZd", ""], 0, 3, false),
        ("abcd\x1b[31me", vec!["abcd", "e"], 1, 1, false),
        ("abcd\u{301}", vec!["abcd\u{301}", ""], 0, 3, true),
    ] {
        let t = terminal(4, 2, bytes);
        assert_eq!(lines(&t), expected, "{bytes:?}");
        assert_eq!(
            (
                t.screen().cursor.row,
                t.screen().cursor.col,
                t.screen().cursor.pending_wrap
            ),
            (row, col, pending)
        );
    }
}
#[test]
fn every_byte_partition() {
    let fixtures = [
        "a\x1b[38:2::12:34:56m猫👩🏽‍💻e\u{301}\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\\x1b[6n",
        "abcd\x1b[?1049hhello\x1b[?1049h!\x1b[?1049lZ",
        "a\x1bPstuff\x1b[31mignored\x1b\\b\x1b_unsupported\x07garbage\x1b\\c",
        "\x1b]2;title\x1b\\abcd\r\n猫猫cat\x1b[2;3HX\x1b[0J",
    ];
    for fixture in fixtures {
        let base = semantic(&terminal(8, 4, fixture));
        for split in 0..=fixture.len() {
            let mut t = Terminal::new(8, 4).unwrap();
            feed(&mut t, &fixture.as_bytes()[..split]);
            feed(&mut t, &fixture.as_bytes()[split..]);
            assert_eq!(semantic(&t), base, "split {split} fixture {fixture:?}");
        }
        let mut t = Terminal::new(8, 4).unwrap();
        for byte in fixture.bytes() {
            feed(&mut t, [byte]);
        }
        assert_eq!(semantic(&t), base);
    }
}
#[test]
fn malformed_utf8_maximal_subpart() {
    for bytes in [
        &b"\xe0\x80\x80"[..],
        &b"\xed\xa0\x80"[..],
        &b"\xf4\x90\x80\x80"[..],
        &b"\xc2A\xf0\x9f"[..],
    ] {
        let mut t = terminal(40, 2, bytes);
        t.finish();
        assert_eq!(lines(&t)[0], String::from_utf8_lossy(bytes));
    }
    let t = terminal(8, 2, b"\xe2\x1b[31mX");
    assert_eq!(lines(&t)[0], "�X");
    assert_eq!(
        t.screen().rows[0]
            .style(t.screen().rows[0].cells[1])
            .foreground,
        Color::Indexed(1)
    );
}
#[test]
fn c1_not_reinterpreted() {
    let t = terminal(20, 2, "a\u{009b}31mb");
    assert_eq!(lines(&t)[0], "a31mb");
}
#[test]
fn lf_is_not_cr() {
    assert_eq!(lines(&terminal(8, 3, "abc\nX")), ["abc", "   X", ""]);
    assert_eq!(lines(&terminal(8, 3, "abc\r\nX")), ["abc", "X", ""]);
}
#[test]
fn wide_repair_all_mutations() {
    for command in [
        "\x1b[2GZ",
        "\x1b[2G\x1b[X",
        "\x1b[2G\x1b[@",
        "\x1b[2G\x1b[P",
        "\x1b[2G\x1b[K",
        "\x1b[2G\x1b[1K",
    ] {
        let t = terminal(6, 3, format!("猫猫X{command}"));
        assert!(t.check_invariants(), "{command:?}");
    }
}
#[test]
fn wide_at_edge() {
    let t = terminal(4, 2, "abc猫");
    assert_eq!(lines(&t), ["abc", "猫"]);
    assert_eq!(t.primary.rows[0].cells[3].kind, CellKind::WrapSpacer);
    assert_eq!(t.primary.rows[0].soft_next, Some(t.primary.rows[1].id));
    let t = terminal(1, 2, "猫");
    assert_eq!(t.primary.rows[0].cells[0].kind, CellKind::Lead1);
    assert_eq!(t.primary.rows[0].cells[0].flags & 1, 1);
}
#[test]
fn combining_style_adjacency() {
    let t = terminal(8, 2, "a\x1b[31m\u{301}b");
    let row = &t.primary.rows[0];
    assert_eq!(row.text(row.cells[0]), "a\u{301}");
    assert_eq!(row.style(row.cells[0]).foreground, Color::Default);
    assert_eq!(row.style(row.cells[1]).foreground, Color::Indexed(1));
}
#[test]
fn unicode_clusters() {
    for text in ["👩🏽‍💻", "🇳🇴", "e\u{301}", "가", "猫"] {
        let t = terminal(8, 2, text);
        assert_eq!(t.primary.rows[0].text(t.primary.rows[0].cells[0]), text);
        assert!(t.check_invariants());
    }
}
#[test]
fn alternate_idempotence_and_mixed() {
    let t = terminal(8, 3, "abc\x1b[31m\x1b[?1049hALT\x1b[?1049h!\x1b[?1049lZ");
    assert_eq!(lines(&t)[0], "abcZ");
    assert_eq!(t.alternate.rows[0].copy_text(), "ALT!");
    assert_eq!(t.pen.foreground, Color::Indexed(1));
    let t = terminal(8, 3, "abc\x1b[?1049hALT\x1b[?47lX\x1b[?1049lY");
    assert_eq!(lines(&t)[0], "abcXY");
}
#[test]
fn alternate_never_enters_history() {
    let t = terminal(4, 2, "\x1b[?1049ha\r\nb\r\nc\r\nd");
    assert!(t.history.is_empty());
}
#[test]
fn ed2_vs_ed3() {
    let mut t = terminal(4, 2, "a\r\nb\r\nc");
    assert_eq!(t.history.len(), 1);
    feed(&mut t, "\x1b[2J");
    assert_eq!(t.history.len(), 1);
    feed(&mut t, "\x1b[3J");
    assert!(t.history.is_empty());
}
#[test]
fn history_bounds() {
    let mut t = Terminal::new(4, 2).unwrap();
    t.history_limit = 3;
    feed(&mut t, "a\r\nb\r\nc\r\nd\r\ne\r\nf");
    assert_eq!(t.history.len(), 3);
    t.history_byte_limit = 1;
    t.enforce_history();
    assert!(t.history.is_empty());
}
#[test]
fn margins_no_history() {
    let t = terminal(8, 4, "\x1b[2;3r\x1b[3;1Hx\n\ny");
    assert!(t.history.is_empty());
}
#[test]
fn cursor_save_pending_and_pen() {
    let t = terminal(4, 2, "\x1b[31mabcd\x1b7\x1b[0m\rX\x1b8e");
    assert_eq!(lines(&t), ["Xbcd", "e"]);
    assert_eq!(t.pen.foreground, Color::Indexed(1));
}
#[test]
fn erase_background_only() {
    let t = terminal(8, 2, "\x1b[1;4;31;44mhi\x1b[K");
    let row = &t.primary.rows[0];
    let s = row.style(row.cells[4]);
    assert_eq!(s.background, Color::Indexed(4));
    assert_eq!(s.foreground, Color::Default);
    assert!(!s.bold);
    assert_eq!(s.underline, 0);
}
#[test]
fn color_syntax() {
    for command in ["38;2;12;34;56", "38:2::12:34:56", "38:2:12:34:56"] {
        let t = terminal(8, 2, format!("\x1b[{command}mX"));
        assert_eq!(t.pen.foreground, Color::Rgb(12, 34, 56));
    }
}
#[test]
fn overflow_invalidates_command() {
    for value in ["4294967296", "999999999999999999999999999"] {
        let t = terminal(8, 2, format!("abc\x1b[{value}DZ"));
        assert_eq!(lines(&t)[0], "abcZ");
    }
}
#[test]
fn string_discard_escape_cannot_inject() {
    let t = terminal(8, 2, b"a\x1b_foo\x1b[2Jbar\x07oops\x1b\\b");
    assert_eq!(lines(&t)[0], "ab");
    let mut bytes = b"a\x1b]2;".to_vec();
    bytes.extend(vec![b'x'; 70_000]);
    bytes.extend_from_slice(b"\x1b[2J\x1b\\b");
    assert_eq!(lines(&terminal(8, 2, bytes))[0], "ab");
}
#[test]
fn string_escape_and_abort() {
    let t = terminal(8, 2, b"a\x1b]2;bad\x18b\x1b]2;good\x1b\\");
    assert_eq!(lines(&t)[0], "ab");
    assert_eq!(t.title, "good");
}
#[test]
fn sync_replies_deadline() {
    let mut t = terminal(8, 2, "a\x1b[?2026hX\x1b[6n");
    assert!(t.snapshot(0).is_none());
    assert!(!t.replies.is_empty());
    t.tick(100);
    feed(&mut t, "\x1b[?2026hY");
    t.tick(151);
    assert!(t.snapshot(0).is_some());
    assert_eq!(lines(&t)[0], "aXY");
}
#[test]
fn immutable_rows() {
    let t = terminal(8, 2, "abc");
    let old = t.primary.rows[0].clone();
    let mut t = t;
    feed(&mut t, "\rX");
    assert_eq!(old.copy_text(), "abc");
    assert_eq!(t.primary.rows[0].copy_text(), "Xbc");
}
#[test]
fn keyboard_stacks_per_screen() {
    let mut t = terminal(8, 2, "\x1b[>3u\x1b[?1049h\x1b[>8u");
    assert_eq!(t.screen().keyboard_flags, 8);
    feed(&mut t, "\x1b[?1049l");
    assert_eq!(t.screen().keyboard_flags, 3);
    feed(&mut t, "\x1b[<u");
    assert_eq!(t.screen().keyboard_flags, 0);
}
#[test]
fn input_modes_and_paste() {
    let mut t = terminal(8, 2, "");
    assert_eq!(
        t.encode_key(Key::Up, Modifiers::default(), false, false),
        b"\x1b[A"
    );
    feed(&mut t, "\x1b[?1h\x1b[?2004h");
    assert_eq!(
        t.encode_key(Key::Up, Modifiers::default(), false, false),
        b"\x1bOA"
    );
    assert_eq!(
        t.encode_paste("a\n\x1bb").unwrap(),
        b"\x1b[200~a\rb\x1b[201~"
    );
}
#[test]
fn resize_inactive_primary() {
    let mut t = terminal(8, 3, "abcdef\x1b7\x1b[?1049h猫猫");
    t.resize(4, 4).unwrap();
    assert!(t.check_invariants());
    feed(&mut t, "\x1b[?1049l");
    assert_eq!(t.primary.cursor.row, 1);
    assert_eq!(t.primary.cursor.col, 2);
    assert_eq!(t.primary.saved.cursor.row, 1);
    assert_eq!(t.primary.saved.cursor.col, 2);
}
#[test]
fn reflow_roundtrip_text() {
    let mut t = terminal(8, 4, "abcd猫efghij   ");
    let before = t.copy_all().trim_end_matches('\n').to_owned();
    t.resize(4, 8).unwrap();
    assert!(t.check_invariants());
    t.resize(8, 4).unwrap();
    assert!(t.check_invariants());
    assert_eq!(t.copy_all().trim_end_matches('\n'), before);
}
#[test]
fn random_byte_partition_and_invariants() {
    let mut seed = 0x55aa_u64;
    let mut bytes = Vec::new();
    for _ in 0..20_000 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        bytes.push(seed as u8);
    }
    let mut baseline = terminal(40, 10, &bytes);
    baseline.finish();
    let expected = semantic(&baseline);
    let mut t = Terminal::new(40, 10).unwrap();
    for chunk in bytes.chunks(37) {
        feed(&mut t, chunk);
        assert!(t.check_invariants());
    }
    t.finish();
    assert_eq!(semantic(&t), expected);
}
#[test]
fn parser_eof_drops_control() {
    let mut parser = VtParser::default();
    let mut ops = Vec::new();
    parser.advance(b"a\x1b[12;", |op| ops.push(op));
    parser.finish(|op| ops.push(op));
    assert_eq!(ops, [Operation::Print('a')]);
}
#[test]
fn geometry_rejected_without_mutation() {
    let mut t = terminal(8, 2, "abc");
    assert!(t.resize(4096, 4096).is_err());
    assert_eq!(t.cols, 8);
    assert_eq!(lines(&t)[0], "abc");
}
#[test]
fn unicode_tables_are_pinned_to_18() {
    assert_eq!(unicode_segmentation::UNICODE_VERSION, (18, 0, 0));
    assert_eq!(unicode_width::UNICODE_VERSION, (18, 0, 0));
}
#[test]
fn kitty_event_encoding() {
    let t = terminal(8, 2, "\x1b[=3u");
    assert_eq!(
        t.encode_key(Key::Up, Modifiers::default(), false, false),
        b"\x1b[1;1:1A"
    );
    assert_eq!(
        t.encode_key(Key::Up, Modifiers::default(), false, true),
        b"\x1b[1;1:3A"
    );
    assert_eq!(
        t.encode_key(Key::Enter, Modifiers::default(), false, false),
        b"\r"
    );
    assert_eq!(
        t.encode_key(Key::Enter, Modifiers::default(), false, true),
        b""
    );
    assert_eq!(
        t.encode_key(Key::Character('a'), Modifiers::default(), false, true),
        b""
    );
    assert_eq!(
        t.encode_key(
            Key::Character('c'),
            Modifiers {
                control: true,
                ..Modifiers::default()
            },
            false,
            false
        ),
        b"\x1b[99;5:1u"
    );
    let t = terminal(8, 2, "\x1b[=31u");
    assert_eq!(
        t.encode_key(
            Key::Character('A'),
            Modifiers {
                shift: true,
                ..Modifiers::default()
            },
            false,
            false
        ),
        b"\x1b[97:65;2:1;65u"
    );
    assert_eq!(
        t.encode_key(
            Key::Character('A'),
            Modifiers {
                shift: true,
                ..Modifiers::default()
            },
            false,
            true
        ),
        b"\x1b[97:65;2:3u"
    );
}
#[test]
fn invalid_utf8_color_does_not_panic() {
    let t = terminal(8, 2, "\x1b]10;#aéabc\x1b\\X");
    assert_eq!(lines(&t)[0], "X");
}
#[test]
fn ascii_fast_path_matches_scalar() {
    for input in [
        "abcd\x1b[31me fghi\r\n0123456789012345",
        "abc猫e\u{301} xyz\x1b[2G!!!\x1b[?7lmore than a row\x1b[?7hwrap now",
        "\u{600}xyz\x1b[4hINSERT\x1b[4lfast\x1b[?1049hALT\r\ntext\x1b[?1049lback",
    ] {
        let mut scalar = Terminal::new(4, 3).unwrap();
        scalar.ascii_fast_path = false;
        feed(&mut scalar, input);
        let fast = terminal(4, 3, input);
        assert_eq!(semantic(&scalar), semantic(&fast), "{input:?}");
    }
}
#[test]
fn rep_yields_without_consuming_later_bytes() {
    let mut t = Terminal::new(80, 24).unwrap();
    let bytes = b"X\x1b[10000bY";
    let used = t.feed(bytes, 0);
    assert!(used < bytes.len());
    assert!(t.has_pending_work());
    let mut consumed = used;
    while consumed < bytes.len() || t.has_pending_work() {
        consumed += t.feed(&bytes[consumed..], 1);
    }
    assert_eq!(t.copy_all().chars().filter(|c| *c == 'X').count(), 10001);
    assert!(t.copy_all().contains('Y'));
    assert!(t.check_invariants());
}
#[test]
fn scroll_closes_cluster_repair() {
    let t = terminal(4, 2, "ab\x1b[S\u{301}");
    assert_eq!(lines(&t)[0], "  \u{301}");
    assert_eq!(
        t.primary.rows[0].text(t.primary.rows[0].cells[2]),
        "\u{301}"
    );
}
#[test]
fn interior_edit_preserves_wrap_chain() {
    let mut t = terminal(4, 3, "abcdef");
    feed(&mut t, "\x1b[1;2HZ");
    assert_eq!(t.primary.rows[0].soft_next, Some(t.primary.rows[1].id));
}
#[test]
fn selective_erase_protects_whole_wide_glyph() {
    let t = terminal(8, 2, "\x1b[1\"q猫\x1b[0\"qabc\x1b[?2J");
    assert!(t.check_invariants());
    assert_eq!(lines(&t)[0], "猫");
}
#[test]
fn osc133_prompt_is_cleared_before_reflowed_shell_redraw() {
    let mut t = terminal(
        64,
        12,
        "\x1b]133;A;redraw=1\x07RESIZE_PROMPT\r\n> RESIZE_BUFFER\x1b[K\x1b[46CRESIZE_RPROMPT\x1b[60D",
    );
    let wide_redraw =
        "\r\r\x1b[A\x1b[JRESIZE_PROMPT\r\n> RESIZE_BUFFER\x1b[K\x1b[80CRESIZE_RPROMPT\x1b[94D";
    let narrow_redraw = "\r\r\x1b[A\x1b[JRESIZE_PROMPT\r\n> RESIZE_BUFFER";
    for _ in 0..5 {
        t.resize(111, 12).unwrap();
        feed(&mut t, wide_redraw);
        t.resize(17, 12).unwrap();
        feed(&mut t, narrow_redraw);
        assert!(t.check_invariants());
        assert_eq!(t.copy_all().matches("RESIZE_PROMPT").count(), 1);
    }
}
#[test]
fn plain_osc133_prompt_is_preserved_across_reflow() {
    let mut t = terminal(16, 5, "\x1b]133;A\x07PROMPT\r\n> BUFFER");
    assert!(!t.primary.prompt_redraw);
    t.resize(8, 5).unwrap();
    assert!(t.copy_all().contains("PROMPT"));
    assert!(t.copy_all().contains("BUFFER"));
    assert!(t.check_invariants());
}
#[test]
fn redrawable_prompt_reflow_preserves_prefix_before_mid_row_marker() {
    let mut t = terminal(
        16,
        4,
        "\x1b]8;;https://example.test\x1b\\\x1b[31mKEEP\x1b[0m\x1b]8;;\x1b\\  \x1b]133;A;redraw=1\x07PROMPT\r\n> BUFFER",
    );
    t.resize(8, 4).unwrap();
    assert!(t.copy_all().contains("KEEP  "));
    assert_eq!(
        t.primary.rows[0]
            .style(t.primary.rows[0].cells[0])
            .foreground,
        Color::Indexed(1)
    );
    assert_eq!(
        t.primary.rows[0]
            .link(t.primary.rows[0].cells[0])
            .as_deref(),
        Some("https://example.test")
    );
    assert!(!t.copy_all().contains("PROMPT"));
    assert!(t.check_invariants());
}
#[test]
fn redrawable_prompt_after_full_width_prefix_preserves_the_last_cell() {
    let mut t = terminal(4, 4, "KEEP\x1b]133;A;redraw=1\x07PROMPT");
    assert!(t.primary.prompt_start.unwrap().pending_wrap);
    t.resize(8, 4).unwrap();
    assert!(t.copy_all().contains("KEEP"));
    t.resize(4, 4).unwrap();
    t.resize(8, 4).unwrap();
    assert!(t.copy_all().contains("KEEP"));
    assert!(t.check_invariants());
}
#[test]
fn redrawable_prompt_after_full_width_wide_prefix_survives_shrink_and_grow() {
    let mut t = terminal(4, 4, "猫猫\x1b]133;A;redraw=1\x07PROMPT");
    assert!(t.primary.prompt_start.unwrap().pending_wrap);
    t.resize(8, 4).unwrap();
    assert!(t.copy_all().contains("猫猫"));
    t.resize(4, 4).unwrap();
    t.resize(8, 4).unwrap();
    assert!(t.copy_all().contains("猫猫"));
    assert!(t.check_invariants());
}
#[test]
fn redrawable_prompt_boundary_survives_shrink_then_grow() {
    let mut t = terminal(8, 4, "LASTCELL\x1b]133;A;redraw=1\x07PROMPT");
    assert!(t.primary.prompt_start.unwrap().pending_wrap);
    t.resize(4, 4).unwrap();
    t.resize(8, 4).unwrap();
    assert!(t.copy_all().contains("LASTCELL"));
    assert!(t.check_invariants());
}
#[test]
fn redrawable_primary_prompt_survives_alternate_screen_resize() {
    let mut t = terminal(
        16,
        5,
        "\x1b]133;A;redraw=1\x07PROMPT\r\n> BUFFER\x1b[?1049hALT",
    );
    t.resize(8, 5).unwrap();
    feed(&mut t, "\x1b[?1049l");
    assert!(t.copy_all().contains("PROMPT"));
    assert!(t.copy_all().contains("BUFFER"));
    assert!(t.check_invariants());
}
#[test]
fn pixel_only_resize_does_not_clear_redrawable_prompt() {
    let mut t = terminal(16, 5, "\x1b]133;A;redraw=1\x07PROMPT\r\n> BUFFER");
    t.resize_pixels(16, 5, 12, 24).unwrap();
    assert!(t.copy_all().contains("PROMPT"));
    assert!(t.copy_all().contains("BUFFER"));
    assert!(t.check_invariants());
}
#[test]
fn evicted_prompt_marker_is_not_rebound_to_live_row_zero() {
    let mut t = terminal(
        8,
        4,
        "\x1b]133;A;redraw=1\x07PROMPT\r\nrow one\r\nrow two\r\nrow three",
    );
    t.resize(8, 2).unwrap();
    assert!(t.primary.prompt_start.is_none());
    assert!(!t.primary.prompt_redraw);
    t.resize(8, 4).unwrap();
    assert!(t.primary.prompt_start.is_none());
    assert!(!t.primary.prompt_redraw);
    assert!(t.check_invariants());
}
#[test]
fn prompt_reflow_clear_keeps_pre_prompt_output_and_stops_after_command_start() {
    let mut t = terminal(16, 5, "OUTPUT\r\n\x1b]133;A;redraw=1\x07PROMPT\r\n> BUFFER");
    t.resize(8, 5).unwrap();
    assert!(t.copy_all().contains("OUTPUT"));
    assert!(!t.copy_all().contains("PROMPT"));
    feed(&mut t, "\x1b]133;C\x07RUNNING");
    t.resize(16, 5).unwrap();
    assert!(t.copy_all().contains("RUNNING"));
    assert!(t.check_invariants());
}
#[test]
fn saved_cursor_excludes_appearance() {
    let t = terminal(8, 2, "abc\x1b7\x1b[?25l\x1b[5 q\x1b8");
    assert!(!t.primary.cursor.visible);
    assert_eq!(t.primary.cursor.shape, 5);
    let t = terminal(8, 2, "\x1b8");
    assert!(t.primary.cursor.visible);
}
#[test]
fn ris_resets_both_cursor_appearances() {
    let mut t = terminal(8, 2, "\x1b[?25l\x1b[?1049h\x1b[?25l\x1bc");
    assert!(t.primary.cursor.visible);
    assert!(t.alternate.cursor.visible);
    feed(&mut t, "\x1b[?47h");
    assert!(t.screen().cursor.visible);
}
#[test]
fn capped_grapheme_keeps_incremental_boundary_state() {
    let input = format!("👩{}\u{200d}👩X", "\u{301}".repeat(100));
    let t = terminal(8, 2, input);
    let row = &t.primary.rows[0];
    assert_eq!(row.text(row.cells[2]), "X");
    assert_eq!(row.text(row.cells[0]).chars().count(), 64);
    assert_ne!(row.cells[0].flags & 4, 0);
}
#[test]
fn widening_clipped_glyph_clears_clipping_flag() {
    let mut t = terminal(1, 2, "猫");
    t.resize(4, 2).unwrap();
    let row = &t.primary.rows[0];
    assert_eq!(row.cells[0].kind, CellKind::Lead2);
    assert_eq!(row.cells[0].flags & 1, 0);
}
