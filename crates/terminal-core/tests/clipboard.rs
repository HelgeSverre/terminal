use base64::{Engine as _, engine::general_purpose::STANDARD};
use terminal_core::{MAX_OSC52_BYTES, MAX_OUTSTANDING_OSC52_REQUESTS, Terminal};

fn feed(terminal: &mut Terminal, bytes: &[u8]) {
    let mut offset = 0;
    while offset < bytes.len() {
        let used = terminal.feed(&bytes[offset..], 0);
        assert!(used > 0);
        offset += used;
    }
}

fn feed_chunked(terminal: &mut Terminal, bytes: &[u8], chunk: usize) {
    for chunk in bytes.chunks(chunk) {
        feed(terminal, chunk);
    }
}

#[test]
fn osc52_is_bounded_write_only_and_correlated() {
    let mut terminal = Terminal::new(80, 24).unwrap();
    let encoded = STANDARD.encode(b"private fixture");
    feed(
        &mut terminal,
        format!("\x1b]52;c;{encoded}\x1b\\").as_bytes(),
    );
    let requests = terminal.take_clipboard_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].data, b"private fixture");
    assert!(terminal.complete_clipboard_request(requests[0].id));
    assert!(!terminal.complete_clipboard_request(requests[0].id));
    assert!(terminal.take_replies().is_empty());
}

#[test]
fn osc52_denies_reads_and_rejects_malformed_or_oversized_writes() {
    let mut terminal = Terminal::new(80, 24).unwrap();
    feed(&mut terminal, b"\x1b]52;c;?\x1b\\");
    assert_eq!(terminal.take_replies(), [b"\x1b]52;c;\x1b\\".to_vec()]);
    for input in [
        "\x1b]52;p;aGVsbG8=\x1b\\".to_owned(),
        "\x1b]52;c;not base64!\x1b\\".to_owned(),
        format!(
            "\x1b]52;c;{}\x1b\\",
            STANDARD.encode(vec![0; MAX_OSC52_BYTES + 1])
        ),
    ] {
        feed(&mut terminal, input.as_bytes());
    }
    assert!(terminal.take_clipboard_requests().is_empty());
}

#[test]
fn osc52_bounds_outstanding_requests_under_output_flood() {
    let mut terminal = Terminal::new(80, 24).unwrap();
    for _ in 0..MAX_OUTSTANDING_OSC52_REQUESTS + 8 {
        feed(&mut terminal, b"\x1b]52;c;eA==\x1b\\");
    }
    let requests = terminal.take_clipboard_requests();
    assert_eq!(requests.len(), MAX_OUTSTANDING_OSC52_REQUESTS);
    for request in requests {
        assert!(terminal.complete_clipboard_request(request.id));
    }
}

#[test]
fn osc52_streams_every_short_partition_and_strictly_rejects_bad_endings() {
    let encoded = STANDARD.encode(b"chunk-safe payload");
    let sequence = format!("\x1b]52;c;{encoded}\x1b\\");
    for split in 1..=sequence.len() {
        let mut terminal = Terminal::new(80, 24).unwrap();
        feed_chunked(&mut terminal, sequence.as_bytes(), split);
        assert_eq!(
            terminal.take_clipboard_requests()[0].data,
            b"chunk-safe payload"
        );
    }
    for malformed in [
        "\x1b]52;c;YQ=\x1b\\",
        "\x1b]52;c;YQ===\x1b\\",
        "\x1b]52;c;YQ==x\x1b\\",
        "\x1b]52;c;YQ\x1b\\",
        "\x1b]52;c;YQ==\x1bX",
    ] {
        let mut terminal = Terminal::new(80, 24).unwrap();
        feed_chunked(&mut terminal, malformed.as_bytes(), 1);
        assert!(
            terminal.take_clipboard_requests().is_empty(),
            "{malformed:?}"
        );
    }
}

#[test]
fn osc52_maximum_payload_is_chunked_and_oversize_is_discarded() {
    let maximum = vec![b'x'; MAX_OSC52_BYTES];
    let maximum = format!("\x1b]52;c;{}\x1b\\", STANDARD.encode(&maximum));
    let mut terminal = Terminal::new(80, 24).unwrap();
    feed_chunked(&mut terminal, maximum.as_bytes(), 257);
    let request = terminal.take_clipboard_requests().pop().unwrap();
    assert_eq!(request.data.len(), MAX_OSC52_BYTES);
    let oversized = vec![b'x'; MAX_OSC52_BYTES + 1];
    let oversized = format!("\x1b]52;c;{}\x07VISIBLE", STANDARD.encode(&oversized));
    feed_chunked(&mut terminal, oversized.as_bytes(), 503);
    assert!(terminal.take_clipboard_requests().is_empty());
    assert!(terminal.screen().rows[0].copy_text().contains("VISIBLE"));
}
