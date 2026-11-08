//! Bounded seven-bit VT syntax and maximal-subpart UTF-8 decoding.
use serde::{Deserialize, Serialize};

pub const MAX_OSC: usize = 65_536;
// OSC 52 carries base64 text. Its 1 MiB decoded limit needs at most this many
// RFC 4648 bytes plus a small command/selection prefix. All other OSC strings
// retain the smaller parser-level cap.

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Csi {
    pub private: Option<u8>,
    pub params: Vec<Vec<Option<u32>>>,
    pub intermediates: Vec<u8>,
    pub final_byte: u8,
}
impl Csi {
    pub fn param(&self, index: usize, default: u32) -> u32 {
        self.params
            .get(index)
            .and_then(|p| p.first())
            .copied()
            .flatten()
            .unwrap_or(default)
    }
    pub fn count(&self, index: usize) -> usize {
        self.param(index, 1).max(1) as usize
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Operation {
    Print(char),
    Control(u8),
    Escape {
        intermediates: Vec<u8>,
        final_byte: u8,
    },
    Csi(Csi),
    Osc(Vec<u8>),
    Osc52Start,
    Osc52Data(Vec<u8>),
    Osc52End,
    Osc52Abort,
    Graphics(Vec<u8>),
    GraphicsAbort,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StringKind {
    Osc,
    Osc52,
    Apc,
    Unsupported,
}
#[derive(Debug, Default)]
enum State {
    #[default]
    Ground,
    Escape(Vec<u8>),
    Csi {
        command: Csi,
        ignore: bool,
        slots: usize,
    },
    String {
        kind: StringKind,
        bytes: Vec<u8>,
        discard: bool,
        escape: bool,
    },
}

#[derive(Debug, Default)]
pub struct VtParser {
    state: State,
    utf8: Vec<u8>,
    expected: usize,
}

impl VtParser {
    pub fn is_ground(&self) -> bool {
        matches!(self.state, State::Ground) && self.utf8.is_empty()
    }
    /// Copy ordinary string payload runs in bulk without changing byte semantics.
    pub fn advance_string_run(&mut self, input: &[u8], mut sink: impl FnMut(Operation)) -> usize {
        let State::String {
            kind,
            bytes,
            discard,
            escape: false,
        } = &mut self.state
        else {
            return 0;
        };
        if (*kind == StringKind::Apc && bytes.is_empty() && !*discard)
            || (*kind == StringKind::Osc && bytes.len() < 5)
        {
            return 0;
        }
        let count = input
            .iter()
            .position(|b| *b < 0x20 || *b == 0x7f)
            .unwrap_or(input.len());
        if count == 0 {
            return 0;
        }
        if *kind == StringKind::Osc52 {
            if !*discard {
                sink(Operation::Osc52Data(input[..count].to_vec()));
            }
        } else if !*discard {
            let limit = string_limit(*kind, bytes, input);
            if bytes.len() + count > limit {
                bytes.clear();
                *discard = true;
                if *kind == StringKind::Apc {
                    sink(Operation::GraphicsAbort);
                }
            } else {
                bytes.extend_from_slice(&input[..count]);
            }
        }
        count
    }
    pub fn advance(&mut self, bytes: &[u8], mut sink: impl FnMut(Operation)) {
        for &byte in bytes {
            self.byte(byte, &mut sink);
        }
    }
    pub fn finish(&mut self, mut sink: impl FnMut(Operation)) {
        if matches!(
            self.state,
            State::String {
                kind: StringKind::Osc52,
                ..
            }
        ) {
            sink(Operation::Osc52Abort);
        }
        if !self.utf8.is_empty() {
            sink(Operation::Print('\u{fffd}'));
        }
        self.utf8.clear();
        self.expected = 0;
        self.state = State::Ground;
    }
    fn byte(&mut self, byte: u8, sink: &mut impl FnMut(Operation)) {
        if matches!(self.state, State::Ground) && !self.utf8.is_empty() {
            let second_ok = self.utf8.len() != 1
                || match self.utf8[0] {
                    0xe0 => byte >= 0xa0,
                    0xed => byte <= 0x9f,
                    0xf0 => byte >= 0x90,
                    0xf4 => byte <= 0x8f,
                    _ => true,
                };
            if (0x80..=0xbf).contains(&byte) && second_ok {
                self.utf8.push(byte);
                if self.utf8.len() == self.expected {
                    if let Ok(s) = std::str::from_utf8(&self.utf8)
                        && let Some(ch) = s.chars().next().filter(|ch| !ch.is_control())
                    {
                        sink(Operation::Print(ch));
                    }
                    self.utf8.clear();
                }
                return;
            }
            self.utf8.clear();
            sink(Operation::Print('\u{fffd}'));
            // Reprocess the byte: an interrupting ESC/control must still act.
        }
        if byte == 0x18 || byte == 0x1a {
            if matches!(
                self.state,
                State::String {
                    kind: StringKind::Apc,
                    ..
                }
            ) {
                sink(Operation::GraphicsAbort);
            }
            if matches!(
                self.state,
                State::String {
                    kind: StringKind::Osc52,
                    ..
                }
            ) {
                sink(Operation::Osc52Abort);
            }
            self.state = State::Ground;
            return;
        }
        let state = std::mem::take(&mut self.state);
        self.state = match state {
            State::Ground => match byte {
                0x1b => State::Escape(Vec::new()),
                0..=0x1f | 0x7f => {
                    sink(Operation::Control(byte));
                    State::Ground
                }
                0x20..=0x7e => {
                    sink(Operation::Print(byte as char));
                    State::Ground
                }
                0xc2..=0xf4 => {
                    self.expected = if byte < 0xe0 {
                        2
                    } else if byte < 0xf0 {
                        3
                    } else {
                        4
                    };
                    self.utf8.push(byte);
                    State::Ground
                }
                _ => {
                    sink(Operation::Print('\u{fffd}'));
                    State::Ground
                }
            },
            State::Escape(mut intermediates) => match byte {
                0x1b => State::Escape(Vec::new()),
                0..=0x1f => {
                    sink(Operation::Control(byte));
                    State::Escape(intermediates)
                }
                0x7f => State::Escape(intermediates),
                b'[' if intermediates.is_empty() => State::Csi {
                    command: Csi::default(),
                    ignore: false,
                    slots: 1,
                },
                b']' if intermediates.is_empty() => State::String {
                    kind: StringKind::Osc,
                    bytes: Vec::new(),
                    discard: false,
                    escape: false,
                },
                b'_' if intermediates.is_empty() => State::String {
                    kind: StringKind::Apc,
                    bytes: Vec::new(),
                    discard: false,
                    escape: false,
                },
                b'P' | b'X' | b'^' if intermediates.is_empty() => State::String {
                    kind: StringKind::Unsupported,
                    bytes: Vec::new(),
                    discard: true,
                    escape: false,
                },
                0x20..=0x2f => {
                    if intermediates.len() < 5 {
                        intermediates.push(byte);
                    }
                    State::Escape(intermediates)
                }
                0x30..=0x7e => {
                    if intermediates.len() <= 4 {
                        sink(Operation::Escape {
                            intermediates,
                            final_byte: byte,
                        });
                    }
                    State::Ground
                }
                _ => State::Ground,
            },
            State::Csi {
                mut command,
                mut ignore,
                mut slots,
            } => {
                match byte {
                    0x1b => {
                        return {
                            self.state = State::Escape(Vec::new());
                        };
                    }
                    0..=0x1f => sink(Operation::Control(byte)),
                    0x7f => {}
                    0x40..=0x7e => {
                        command.final_byte = byte;
                        if !ignore {
                            sink(Operation::Csi(command));
                        }
                        return;
                    }
                    0x20..=0x2f => {
                        if command.intermediates.len() == 4 {
                            ignore = true;
                        } else {
                            command.intermediates.push(byte);
                        }
                    }
                    b'<'..=b'?'
                        if command.private.is_none()
                            && command.params.is_empty()
                            && command.intermediates.is_empty() =>
                    {
                        command.private = Some(byte)
                    }
                    b'0'..=b'9' | b';' | b':' if command.intermediates.is_empty() && !ignore => {
                        if command.params.is_empty() {
                            command.params.push(vec![None]);
                        }
                        if byte == b';' {
                            slots += 1;
                            if command.params.len() == 32 || slots > 128 {
                                ignore = true;
                            } else {
                                command.params.push(vec![None]);
                            }
                        } else if byte == b':' {
                            slots += 1;
                            if slots > 128 {
                                ignore = true;
                            } else if let Some(p) = command.params.last_mut() {
                                p.push(None);
                            }
                        } else if let Some(n) = command.params.last_mut().and_then(|p| p.last_mut())
                        {
                            if let Some(value) = n
                                .unwrap_or(0)
                                .checked_mul(10)
                                .and_then(|n| n.checked_add(u32::from(byte - b'0')))
                            {
                                *n = Some(value);
                            } else {
                                ignore = true;
                            }
                        }
                    }
                    _ => ignore = true,
                }
                State::Csi {
                    command,
                    ignore,
                    slots,
                }
            }
            State::String {
                mut kind,
                mut bytes,
                mut discard,
                mut escape,
            } => {
                if (escape && byte == b'\\')
                    || (matches!(kind, StringKind::Osc | StringKind::Osc52) && byte == 7)
                {
                    if !discard {
                        if kind == StringKind::Osc {
                            sink(Operation::Osc(bytes));
                        } else if kind == StringKind::Osc52 {
                            sink(Operation::Osc52End);
                        } else if kind == StringKind::Apc {
                            sink(Operation::Graphics(bytes));
                        }
                    }
                    State::Ground
                } else if byte == 0x1b {
                    State::String {
                        kind,
                        bytes,
                        discard,
                        escape: true,
                    }
                } else if escape && !discard && kind != StringKind::Apc {
                    if kind == StringKind::Osc52 {
                        sink(Operation::Osc52Abort);
                    }
                    // Supported incomplete string abandoned; this byte follows fresh ESC.
                    self.state = State::Escape(Vec::new());
                    self.byte(byte, sink);
                    return;
                } else {
                    if kind == StringKind::Apc && escape && !discard {
                        discard = true;
                        bytes.clear();
                        sink(Operation::GraphicsAbort);
                    }
                    escape = false;
                    if kind == StringKind::Apc && bytes.is_empty() && byte != b'G' {
                        discard = true;
                    }
                    if !discard && byte >= 0x20 && byte != 0x7f {
                        if kind == StringKind::Osc52 {
                            sink(Operation::Osc52Data(vec![byte]));
                            return self.state = State::String {
                                kind,
                                bytes,
                                discard,
                                escape,
                            };
                        }
                        let limit = string_limit(kind, &bytes, &[byte]);
                        if bytes.len() == limit {
                            bytes.clear();
                            discard = true;
                            if kind == StringKind::Apc {
                                sink(Operation::GraphicsAbort);
                            }
                        } else {
                            bytes.push(byte);
                            if kind == StringKind::Osc && bytes == b"52;c;" {
                                sink(Operation::Osc52Start);
                                bytes.clear();
                                kind = StringKind::Osc52;
                            }
                        }
                    }
                    State::String {
                        kind,
                        bytes,
                        discard,
                        escape,
                    }
                }
            }
        };
    }
}

fn string_limit(kind: StringKind, bytes: &[u8], next: &[u8]) -> usize {
    if kind == StringKind::Apc {
        return 8192;
    }
    if kind != StringKind::Osc {
        return MAX_OSC;
    }
    let _ = (bytes, next);
    MAX_OSC
}

#[cfg(test)]
mod tests {
    use super::{MAX_OSC, StringKind, string_limit};

    #[test]
    fn osc52_exception_does_not_expand_other_string_kinds() {
        let prefix = b"52;c;";
        assert_eq!(string_limit(StringKind::Osc, &[], prefix), MAX_OSC);
        assert_eq!(string_limit(StringKind::Unsupported, &[], prefix), MAX_OSC);
    }
}
