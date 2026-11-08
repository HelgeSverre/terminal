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
    assert!(terminal.complete_clipboard_request(requests[0].id, true));
    assert!(!terminal.complete_clipboard_request(requests[0].id, false));
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
        assert!(terminal.complete_clipboard_request(request.id, false));
    }
}
