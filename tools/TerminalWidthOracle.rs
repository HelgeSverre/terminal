//! Development-only scalar oracle for the locked `unicode-width` dependency.
//!
//! It is intentionally not wired into the app or Cargo workspace. After
//! `cargo build -p terminal-core`, compile it with the already-built crate:
//! `rustc --edition 2024 tools/TerminalWidthOracle.rs --extern unicode_width=$(find target/debug/deps -name 'libunicode_width-*.rlib' -print -quit) -L dependency=target/debug/deps -o target/native/terminal-width-oracle`.

use std::io::{self, Write};
use unicode_width::UnicodeWidthStr;

fn main() -> io::Result<()> {
    let stdout = io::stdout();
    let mut output = io::BufWriter::new(stdout.lock());
    for scalar in 0..=0x10_FFFF {
        if let Some(character) = char::from_u32(scalar) {
            let mut encoded = [0; 4];
            let text = character.encode_utf8(&mut encoded);
            output.write_all(&[UnicodeWidthStr::width(text) as u8])?;
        }
    }
    output.flush()
}
