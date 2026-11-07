use std::{hint::black_box, time::Instant};
use terminal_core::Terminal;
fn replay(bytes: &[u8], history: usize) -> f64 {
    let mut t = Terminal::new(160, 50).unwrap();
    t.history_limit = history;
    let start = Instant::now();
    for chunk in bytes.chunks(65_536) {
        let mut offset = 0;
        while offset < chunk.len() {
            offset += t.feed(&chunk[offset..], 0);
            black_box(t.take_replies());
        }
    }
    t.finish();
    black_box(t.snapshot(0));
    assert!(t.check_invariants());
    bytes.len() as f64 / (1024.0 * 1024.0) / start.elapsed().as_secs_f64()
}
fn main() {
    let ascii = "The quick brown fox jumps over the lazy dog. 0123456789\r\n".repeat(20_000);
    let unicode = "猫 日本語 👩🏽‍💻 🇳🇴 e\u{301} emoji\r\n".repeat(10_000);
    let mut ascii_mib = Vec::new();
    let mut mixed_mib = Vec::new();
    for _ in 0..5 {
        ascii_mib.push(replay(ascii.as_bytes(), 0));
        mixed_mib.push(replay(unicode.as_bytes(), 0));
    }
    let mut t = Terminal::new(160, 50).unwrap();
    let line = "x".repeat(159) + "\r\n";
    for _ in 0..10_050 {
        t.feed(line.as_bytes(), 0);
    }
    let start = Instant::now();
    t.resize(120, 60).unwrap();
    black_box(t.snapshot(0));
    let reflow_ms = start.elapsed().as_secs_f64() * 1000.0;
    println!(
        "{}",
        serde_json::json!({"profile":"release","cols":160,"rows":50,"ascii_mib_per_s":ascii_mib,"mixed_mib_per_s":mixed_mib,"reflow_10000_rows_ms":reflow_ms,"unicode":"18.0.0","note":"headless full semantic replay including finish and snapshot; local machine; no GPU timing"})
    );
}
