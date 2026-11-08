use crate::MAX_OSC52_BYTES;

pub const MAX_ENCODED_BYTES: usize = MAX_OSC52_BYTES.div_ceil(3) * 4;

pub enum Outcome {
    Write(Vec<u8>),
    Query,
    Reject,
}

#[derive(Debug)]
pub struct Decoder {
    state: State,
    encoded: usize,
    carry: [u8; 4],
    carry_len: usize,
    output: Vec<u8>,
    accept: bool,
}

#[derive(Debug)]
enum State {
    Undecided,
    Data,
    Query,
    Finished,
    Reject,
}

impl Decoder {
    pub fn new(accept: bool) -> Self {
        Self {
            state: State::Undecided,
            encoded: 0,
            carry: [0; 4],
            carry_len: 0,
            output: Vec::new(),
            accept,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            match self.state {
                State::Undecided if byte == b'?' => self.state = State::Query,
                State::Undecided => {
                    self.state = State::Data;
                    self.push_base64(byte);
                }
                State::Data => self.push_base64(byte),
                State::Query | State::Finished | State::Reject => self.state = State::Reject,
            }
        }
    }

    pub fn finish(self) -> Outcome {
        match self.state {
            State::Query => Outcome::Query,
            State::Data | State::Finished if self.carry_len == 0 && self.accept => {
                Outcome::Write(self.output)
            }
            _ => Outcome::Reject,
        }
    }

    fn push_base64(&mut self, byte: u8) {
        if !matches!(self.state, State::Data)
            || self.encoded == MAX_ENCODED_BYTES
            || (byte != b'=' && base64_value(byte).is_none())
        {
            self.state = State::Reject;
            return;
        }
        self.encoded += 1;
        self.carry[self.carry_len] = byte;
        self.carry_len += 1;
        if self.carry_len == 4 {
            self.decode_block();
            self.carry_len = 0;
        }
    }

    fn decode_block(&mut self) {
        let [a, b, c, d] = self.carry;
        let Some(a) = base64_value(a) else {
            self.state = State::Reject;
            return;
        };
        let Some(b) = base64_value(b) else {
            self.state = State::Reject;
            return;
        };
        let (bytes, length) = if c == b'=' && d == b'=' {
            ([(a << 2) | (b >> 4), 0, 0], 1)
        } else if d == b'=' {
            let Some(c) = base64_value(c) else {
                self.state = State::Reject;
                return;
            };
            ([(a << 2) | (b >> 4), (b << 4) | (c >> 2), 0], 2)
        } else {
            let (Some(c), Some(d)) = (base64_value(c), base64_value(d)) else {
                self.state = State::Reject;
                return;
            };
            ([(a << 2) | (b >> 4), (b << 4) | (c >> 2), (c << 6) | d], 3)
        };
        if c == b'=' || d == b'=' {
            self.state = State::Reject;
            // This marker is reset below only after the final append. A second
            // block is therefore always rejected.
        }
        if !self.accept {
            if c == b'=' || d == b'=' {
                self.state = State::Finished;
            }
            return;
        }
        if self
            .output
            .len()
            .checked_add(length)
            .is_none_or(|n| n > MAX_OSC52_BYTES)
            || self.output.try_reserve(length).is_err()
        {
            self.state = State::Reject;
            return;
        }
        self.output.extend_from_slice(&bytes[..length]);
        if c == b'=' || d == b'=' {
            self.state = State::Finished;
        }
    }
}

fn base64_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}
