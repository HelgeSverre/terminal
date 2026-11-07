use std::io::{self, Read};
use terminal_core::Terminal;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    let cols = args.get(1).map(|s| s.parse()).transpose()?.unwrap_or(80);
    let rows = args.get(2).map(|s| s.parse()).transpose()?.unwrap_or(24);
    let mut t = Terminal::new(cols, rows)?;
    let mut bytes = Vec::new();
    io::stdin().read_to_end(&mut bytes)?;
    let mut offset = 0;
    while offset < bytes.len() || t.has_pending_work() {
        let n = t.feed(&bytes[offset..], 0);
        for reply in t.take_replies() {
            eprintln!("reply: {:?}", String::from_utf8_lossy(&reply));
        }
        offset += n;
    }
    t.finish();
    println!("{}", serde_json::to_string_pretty(&t.snapshot(0))?);
    Ok(())
}
