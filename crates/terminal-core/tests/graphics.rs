use base64::{Engine as _, engine::general_purpose::STANDARD};
use std::io::Write;
use terminal_core::Terminal;
fn feed(t: &mut Terminal, bytes: impl AsRef<[u8]>) {
    let bytes = bytes.as_ref();
    let mut offset = 0;
    while offset < bytes.len() || t.has_pending_work() {
        offset += t.feed(&bytes[offset..], 0);
    }
    assert!(t.check_invariants());
}
fn command(header: &str, payload: &[u8]) -> Vec<u8> {
    format!("\x1b_G{header};{}\x1b\\", STANDARD.encode(payload)).into_bytes()
}
fn query(t: &mut Terminal, header: &str, bytes: &[u8]) {
    feed(t, command(header, bytes));
}
fn rgba(t: &Terminal, id: u32) -> &[u8] {
    &t.graphics.resources.get(&id).unwrap().rgba
}
#[test]
fn kitty_detection_query_is_ordered_and_non_mutating() {
    let mut t = Terminal::new(80, 24).unwrap();
    query(&mut t, "a=q,t=d,f=24,s=1,v=1,i=123", &[1, 2, 3]);
    feed(&mut t, b"\x1b[c");
    assert_eq!(
        t.take_replies(),
        [b"\x1b_Gi=123;OK\x1b\\".to_vec(), b"\x1b[?62;22c".to_vec()]
    );
    assert!(t.graphics.resources.is_empty());
    assert!(t.snapshot(0).unwrap().images.is_empty());
}
#[test]
fn direct_rgb_rgba_and_placement() {
    let mut t = Terminal::new(80, 24).unwrap();
    query(
        &mut t,
        "a=T,t=d,f=24,s=2,v=1,i=1,p=7,c=10,r=4,C=1",
        &[255, 0, 0, 0, 255, 0],
    );
    assert_eq!(rgba(&t, 1), [255, 0, 0, 255, 0, 255, 0, 255]);
    let s = t.snapshot(0).unwrap();
    assert_eq!(s.images.len(), 1);
    assert_eq!((s.images[0].columns, s.images[0].rows), (10, 4));
    assert_eq!((s.cursor.row, s.cursor.col), (0, 0));
    assert!(String::from_utf8_lossy(&t.take_replies().concat()).contains("i=1,p=7;OK"));
    query(&mut t, "a=t,f=32,s=1,v=1,i=2", &[20, 30, 40, 128]);
    assert_eq!(rgba(&t, 2), [20, 30, 40, 128]);
    assert_eq!(t.snapshot(0).unwrap().images.len(), 1);
    query(&mut t, "a=p,i=2,C=1,c=3", &[]);
    assert_eq!(t.snapshot(0).unwrap().images.len(), 2);
}
#[test]
fn chunk_atomicity_and_final_cursor_position() {
    let mut t = Terminal::new(80, 24).unwrap();
    let pixels = vec![42; 6000];
    let encoded = STANDARD.encode(&pixels);
    feed(
        &mut t,
        format!(
            "\x1b_Ga=T,f=24,s=2000,v=1,i=99,C=1,m=1;{}\x1b\\",
            &encoded[..4096]
        ),
    );
    assert!(t.graphics.resources.is_empty());
    assert!(t.snapshot(0).unwrap().images.is_empty());
    assert!(t.take_replies().is_empty());
    feed(&mut t, b"\x1b[4;6H");
    feed(&mut t, format!("\x1b_Gm=0;{}\x1b\\", &encoded[4096..]));
    let s = t.snapshot(0).unwrap();
    assert_eq!((s.images[0].row, s.images[0].col), (3, 5));
    assert_eq!(rgba(&t, 99).len(), 8000);
    assert_eq!(t.take_replies().len(), 1);
}
#[test]
fn every_byte_partition_and_one_byte_reads() {
    let packet = command(
        "a=T,f=32,s=2,v=1,i=4294967295,C=1",
        &[1, 2, 3, 4, 5, 6, 7, 8],
    );
    for split in 0..=packet.len() {
        let mut t = Terminal::new(8, 3).unwrap();
        feed(&mut t, &packet[..split]);
        feed(&mut t, &packet[split..]);
        assert_eq!(rgba(&t, u32::MAX), [1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(t.snapshot(0).unwrap().images.len(), 1);
    }
    let mut t = Terminal::new(8, 3).unwrap();
    for byte in &packet {
        feed(&mut t, [*byte]);
    }
    assert_eq!(rgba(&t, u32::MAX), [1, 2, 3, 4, 5, 6, 7, 8]);
}
#[test]
fn replacements_delete_old_placements_and_generate_new_lifetime() {
    let mut t = Terminal::new(8, 3).unwrap();
    query(&mut t, "a=T,f=24,s=1,v=1,i=1,C=1", &[1, 2, 3]);
    let old = t.graphics.resources[&1].generation;
    query(&mut t, "a=t,f=24,s=1,v=1,i=1", &[4, 5, 6]);
    assert!(t.graphics.resources[&1].generation > old);
    assert!(t.snapshot(0).unwrap().images.is_empty());
    assert_eq!(rgba(&t, 1), [4, 5, 6, 255]);
    query(&mut t, "a=p,i=1,p=1,C=1", &[]);
    query(&mut t, "a=p,i=1,p=1,C=1", &[]);
    assert_eq!(t.snapshot(0).unwrap().images.len(), 1);
    query(&mut t, "a=d,d=i,i=1", &[]);
    assert!(t.snapshot(0).unwrap().images.is_empty());
    assert!(t.graphics.resources.contains_key(&1));
    query(&mut t, "a=d,d=I,i=1", &[]);
    assert!(!t.graphics.resources.contains_key(&1));
}
#[test]
fn screen_scope_clear_reset_and_scrolling() {
    let mut t = Terminal::new(8, 3).unwrap();
    query(&mut t, "a=T,f=24,s=1,v=1,i=1,C=1,c=2,r=2", &[1, 2, 3]);
    feed(&mut t, b"\x1b[?47h");
    assert!(t.snapshot(0).unwrap().images.is_empty());
    feed(&mut t, b"\x1b[?47l");
    assert_eq!(t.snapshot(0).unwrap().images.len(), 1);
    feed(&mut t, b"\x1b[3S");
    assert!(t.snapshot(0).unwrap().images.is_empty());
    assert_eq!(t.snapshot(3).unwrap().images.len(), 1);
    feed(&mut t, b"\x1b[3J");
    assert!(t.snapshot(0).unwrap().images.is_empty());
    feed(&mut t, b"\x1bc");
    assert!(t.graphics.resources.is_empty());
}
#[test]
fn png_and_zlib_are_decoded_with_alpha() {
    let mut png = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut png, 1, 1);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder
            .write_header()
            .unwrap()
            .write_image_data(&[120, 20, 30, 99])
            .unwrap();
    }
    let mut t = Terminal::new(8, 3).unwrap();
    query(&mut t, "a=T,f=100,i=1,C=1", &png);
    assert_eq!(rgba(&t, 1), [120, 20, 30, 99]);
    let mut compressed = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::fast());
    compressed.write_all(&[1, 2, 3, 4]).unwrap();
    query(
        &mut t,
        "a=t,f=32,s=1,v=1,o=z,i=2",
        &compressed.finish().unwrap(),
    );
    assert_eq!(rgba(&t, 2), [1, 2, 3, 4]);
}
#[test]
fn malformed_size_base64_and_file_transports_fail_without_replacing() {
    let mut t = Terminal::new(8, 3).unwrap();
    query(&mut t, "a=T,f=24,s=1,v=1,i=1,C=1", &[1, 2, 3]);
    let generation = t.graphics.resources[&1].generation;
    t.take_replies();
    for packet in [
        command("a=T,f=24,s=4294967295,v=4294967295,i=1", &[1, 2, 3]),
        command("a=T,f=24,s=2,v=2,i=1", &[1, 2, 3]),
        command("a=T,f=100,t=f,i=1", b"/etc/passwd"),
        b"\x1b_Ga=T,f=24,s=1,v=1,i=1;%%%\x1b\\".to_vec(),
    ] {
        feed(&mut t, packet);
        assert_eq!(t.graphics.resources[&1].generation, generation);
        assert_eq!(t.snapshot(0).unwrap().images.len(), 1);
    }
    let replies = String::from_utf8(t.take_replies().concat()).unwrap();
    assert!(replies.contains("E2BIG"));
    assert!(replies.contains("EINVAL"));
    assert!(replies.contains("ENOTSUP"));
}
#[test]
fn quiet_modes_and_unsupported_feature_queries() {
    let mut t = Terminal::new(8, 3).unwrap();
    query(&mut t, "a=q,f=24,s=1,v=1,i=1,q=1", &[1, 2, 3]);
    assert!(t.take_replies().is_empty());
    query(&mut t, "a=q,f=24,s=1,v=1,i=1,q=2", &[]);
    assert!(t.take_replies().is_empty());
    feed(&mut t, b"\x1b_Ga=q,i=10,e=T,U=1,C=1,t=d,f=24\x1b\\");
    let reply = String::from_utf8(t.take_replies().concat()).unwrap();
    assert!(reply.contains("e=T"));
    assert!(reply.contains("C=1"));
    assert!(!reply.contains("U=1"));
}
#[test]
fn cancel_and_oversized_apc_never_leak_payload() {
    let mut t = Terminal::new(8, 3).unwrap();
    feed(&mut t, b"\x1b_Ga=T,f=24,s=2,v=1,i=1,m=1;AQID\x1b\\");
    feed(&mut t, b"\x1b_Gm=0;BAUG\x18");
    assert!(t.graphics.resources.is_empty());
    feed(&mut t, b"\x1b_Ga=d,d=I,i=1\x1b\\");
    let mut oversized = b"\x1b_G".to_vec();
    oversized.extend(vec![b'x'; 100_000]);
    oversized.extend_from_slice(b"\x1b[2J\x1b\\Z");
    feed(&mut t, oversized);
    assert_eq!(t.primary.rows[0].copy_text(), "Z");
    assert!(t.graphics.accounted_bytes() < 100_000);
}
#[test]
fn dmscene_double_buffer_sequence() {
    let mut t = Terminal::new(80, 24).unwrap();
    for n in 0..20 {
        let id = 100 + n % 2;
        feed(&mut t, b"\x1b[?2026h\x1b[H");
        query(
            &mut t,
            &format!("a=T,t=d,f=24,s=2,v=1,i={id},p=1,c=80,r=23,C=1,q=2,m=0"),
            &[n as u8, 2, 3, 4, 5, 6],
        );
        if n > 0 {
            query(&mut t, &format!("a=d,d=I,i={},q=2", 100 + (n + 1) % 2), &[]);
        }
        assert!(t.snapshot(0).is_none());
        feed(&mut t, b"\x1b[?2026l");
        let snapshot = t.snapshot(0).unwrap();
        assert_eq!(snapshot.images.len(), 1);
        assert_eq!(snapshot.images[0].image, id);
        assert_eq!(t.graphics.resources.len(), 1);
        assert!(t.take_replies().is_empty());
    }
}

#[test]
fn delete_z_keeps_unrelated_cached_images_and_other_screen_references() {
    let mut t = Terminal::new(8, 3).unwrap();
    query(&mut t, "a=t,f=24,s=1,v=1,i=2", &[4, 5, 6]);
    query(&mut t, "a=T,f=24,s=1,v=1,i=1,C=1,z=7", &[1, 2, 3]);
    feed(&mut t, b"\x1b[?47h");
    query(&mut t, "a=p,i=1,C=1,z=7", &[]);
    query(&mut t, "a=d,d=Z,z=7", &[]);
    assert!(t.snapshot(0).unwrap().images.is_empty());
    assert!(t.graphics.resources.contains_key(&1));
    assert!(t.graphics.resources.contains_key(&2));
    feed(&mut t, b"\x1b[?47l");
    assert_eq!(t.snapshot(0).unwrap().images.len(), 1);
    query(&mut t, "a=d,d=Z,z=7", &[]);
    assert!(!t.graphics.resources.contains_key(&1));
    assert!(t.graphics.resources.contains_key(&2));
    query(&mut t, "a=d,d=I,i=2", &[]);
    assert!(t.graphics.resources.is_empty());
}

#[test]
fn zero_source_extent_means_remaining_pixels_and_queries_respect_quiet() {
    let mut t = Terminal::new(8, 3).unwrap();
    query(
        &mut t,
        "a=T,f=24,s=2,v=2,i=1,C=1,x=1,y=1,w=0,h=0",
        &[50; 12],
    );
    assert_eq!(t.snapshot(0).unwrap().images[0].source, [1, 1, 1, 1]);
    t.take_replies();
    feed(&mut t, b"\x1b_Ga=q,i=10,e=T,C=1,q=1\x1b\\");
    feed(&mut t, b"\x1b_Ga=q,i=10,e=T,C=1,q=2\x1b\\");
    assert!(t.take_replies().is_empty());
    query(&mut t, "a=t,f=24,s=99999,v=1,i=2,m=1", &[1, 2, 3]);
    assert!(String::from_utf8_lossy(&t.take_replies().concat()).contains("E2BIG"));
    assert!(t.graphics.accounted_bytes() < 1000);
}
