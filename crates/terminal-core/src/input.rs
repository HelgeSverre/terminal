//! Encoding happens on the terminal owner using the modes at that event.
use crate::Terminal;
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeypadKey {
    Digit0,
    Digit1,
    Digit2,
    Digit3,
    Digit4,
    Digit5,
    Digit6,
    Digit7,
    Digit8,
    Digit9,
    Decimal,
    Divide,
    Multiply,
    Subtract,
    Add,
    Enter,
    Equal,
    Separator,
}
impl KeypadKey {
    pub const ALL: [Self; 18] = [
        Self::Digit0,
        Self::Digit1,
        Self::Digit2,
        Self::Digit3,
        Self::Digit4,
        Self::Digit5,
        Self::Digit6,
        Self::Digit7,
        Self::Digit8,
        Self::Digit9,
        Self::Decimal,
        Self::Divide,
        Self::Multiply,
        Self::Subtract,
        Self::Add,
        Self::Enter,
        Self::Equal,
        Self::Separator,
    ];
    pub fn from_index(index: usize) -> Option<Self> {
        Self::ALL.get(index).copied()
    }
    fn symbol(self, native: Option<char>) -> char {
        native
            .filter(|c| !c.is_control())
            .unwrap_or_else(|| char::from(b"0123456789./*-+\r=,"[self as usize]))
    }
    fn application(self) -> u8 {
        b"pqrstuvwxynojmkMXl"[self as usize]
    }
    fn kitty(self) -> u32 {
        57399 + self as u32
    }
}
#[derive(Debug, Clone, Copy)]
pub enum Key {
    Up,
    Down,
    Right,
    Left,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    Backspace,
    Tab,
    Enter,
    Escape,
    Function(u8),
    Character(char),
    Keypad(KeypadKey, Option<char>),
}
#[derive(Debug, Clone, Copy, Default)]
pub struct Modifiers {
    pub shift: bool,
    pub alt: bool,
    pub control: bool,
    pub super_key: bool,
}
impl Modifiers {
    fn kitty(self) -> u32 {
        1 + u32::from(self.shift)
            + 2 * u32::from(self.alt)
            + 4 * u32::from(self.control)
            + 8 * u32::from(self.super_key)
    }
}
impl Terminal {
    pub fn encode_key(&self, key: Key, mods: Modifiers, repeat: bool, release: bool) -> Vec<u8> {
        let flags = self.screen().keyboard_flags;
        if release && flags & 2 == 0 {
            return Vec::new();
        }
        let protected_legacy = matches!(key, Key::Enter | Key::Tab | Key::Backspace);
        let text_key = matches!(key, Key::Character(_))
            || matches!(key, Key::Keypad(k, _) if k != KeypadKey::Enter && !self.modes.application_keypad);
        let is_text = text_key && !mods.control && !mods.alt && !mods.super_key;
        if release && (is_text && flags & 8 == 0 || protected_legacy && flags & 8 == 0) {
            return Vec::new();
        }
        let enhanced = flags & 8 != 0
            || (!protected_legacy && flags & 2 != 0 && !is_text)
            || (flags & 1 != 0
                && (mods.control || mods.alt || matches!(key, Key::Escape | Key::Keypad(_, _))))
            || mods.super_key;
        if enhanced {
            let event = if flags & 2 != 0 {
                format!(
                    ":{}",
                    if release {
                        3
                    } else if repeat {
                        2
                    } else {
                        1
                    }
                )
            } else {
                String::new()
            };
            let modifier = mods.kitty();
            let functional = match key {
                Key::Up => Some((1, 'A')),
                Key::Down => Some((1, 'B')),
                Key::Right => Some((1, 'C')),
                Key::Left => Some((1, 'D')),
                Key::Home => Some((1, 'H')),
                Key::End => Some((1, 'F')),
                Key::Insert => Some((2, '~')),
                Key::Delete => Some((3, '~')),
                Key::PageUp => Some((5, '~')),
                Key::PageDown => Some((6, '~')),
                Key::Function(n) => Some(match n {
                    1 => (1, 'P'),
                    2 => (1, 'Q'),
                    3 => (13, '~'),
                    4 => (1, 'S'),
                    5 => (15, '~'),
                    6 => (17, '~'),
                    7 => (18, '~'),
                    8 => (19, '~'),
                    9 => (20, '~'),
                    10 => (21, '~'),
                    11 => (23, '~'),
                    12 => (24, '~'),
                    _ => (57363 + u32::from(n), 'u'),
                }),
                _ => None,
            };
            if let Some((number, final_byte)) = functional {
                return format!("\x1b[{number};{modifier}{event}{final_byte}").into_bytes();
            }
            let (code, text) = match key {
                Key::Character(c) => (
                    if c.is_ascii_alphabetic() {
                        c.to_ascii_lowercase() as u32
                    } else {
                        c as u32
                    },
                    Some(c),
                ),
                Key::Enter => (13, None),
                Key::Tab => (9, None),
                Key::Backspace => (127, None),
                Key::Escape => (27, None),
                Key::Keypad(key, text) => (
                    key.kitty(),
                    (key != KeypadKey::Enter).then(|| key.symbol(text)),
                ),
                _ => return Vec::new(),
            };
            let alternate = if flags & 4 != 0 && mods.shift && matches!(key, Key::Character(_)) {
                text.filter(|c| *c as u32 != code)
                    .map(|c| format!(":{}", c as u32))
                    .unwrap_or_default()
            } else {
                String::new()
            };
            let associated = if flags & 16 != 0 && !release && !mods.control && !mods.super_key {
                text.map(|c| format!(";{}", c as u32)).unwrap_or_default()
            } else {
                String::new()
            };
            return format!("\x1b[{code}{alternate};{modifier}{event}{associated}u").into_bytes();
        }
        if release {
            return Vec::new();
        }
        if let Key::Keypad(key, text) = key {
            if self.modes.application_keypad {
                let mut bytes = vec![27, b'O', key.application()];
                if mods.alt {
                    bytes.insert(0, 27);
                }
                return bytes;
            }
            let legacy = if key == KeypadKey::Enter {
                Key::Enter
            } else {
                Key::Character(key.symbol(text))
            };
            return self.encode_key(legacy, mods, repeat, false);
        }
        let modifier = mods.kitty();
        let prefix = if self.modes.application_cursor {
            "\x1bO"
        } else {
            "\x1b["
        };
        let arrow = match key {
            Key::Up => Some('A'),
            Key::Down => Some('B'),
            Key::Right => Some('C'),
            Key::Left => Some('D'),
            Key::Home => Some('H'),
            Key::End => Some('F'),
            _ => None,
        };
        if let Some(final_byte) = arrow {
            return if modifier == 1 {
                format!("{prefix}{final_byte}")
            } else {
                format!("\x1b[1;{modifier}{final_byte}")
            }
            .into_bytes();
        }
        let number = match key {
            Key::Insert => Some(2),
            Key::Delete => Some(3),
            Key::PageUp => Some(5),
            Key::PageDown => Some(6),
            Key::Function(n) => match n {
                5 => Some(15),
                6 => Some(17),
                7 => Some(18),
                8 => Some(19),
                9 => Some(20),
                10 => Some(21),
                11 => Some(23),
                12 => Some(24),
                _ => None,
            },
            _ => None,
        };
        if let Some(n) = number {
            return if modifier == 1 {
                format!("\x1b[{n}~")
            } else {
                format!("\x1b[{n};{modifier}~")
            }
            .into_bytes();
        }
        let mut bytes = match key {
            Key::Function(n @ 1..=4) => if modifier == 1 {
                format!("\x1bO{}", char::from(b'P' + n - 1))
            } else {
                format!("\x1b[1;{modifier}{}", char::from(b'P' + n - 1))
            }
            .into_bytes(),
            Key::Backspace => vec![127],
            Key::Enter => vec![13],
            Key::Tab => {
                if mods.shift {
                    b"\x1b[Z".to_vec()
                } else {
                    vec![9]
                }
            }
            Key::Escape => vec![27],
            Key::Character(c) => {
                if mods.control
                    && (c.is_ascii_alphabetic() || ('@'..='_').contains(&c) || c == ' ' || c == '?')
                {
                    vec![if c == '?' {
                        127
                    } else {
                        c.to_ascii_uppercase() as u8 & 31
                    }]
                } else {
                    c.to_string().into_bytes()
                }
            }
            _ => Vec::new(),
        };
        if mods.alt {
            bytes.insert(0, 27);
        }
        bytes
    }
    pub fn encode_paste(&self, text: &str) -> Option<Vec<u8>> {
        if text.len() > 1_048_576 {
            return None;
        }
        // Treat pasted LF as Enter, strip terminal control injection (including ESC).
        let clean: String = text
            .replace("\r\n", "\n")
            .chars()
            .filter(|c| !c.is_control() || matches!(c, '\n' | '\r' | '\t'))
            .map(|c| if c == '\n' { '\r' } else { c })
            .collect();
        Some(if self.modes.bracketed_paste {
            format!("\x1b[200~{clean}\x1b[201~").into_bytes()
        } else {
            clean.into_bytes()
        })
    }
    pub fn encode_focus(&self, focused: bool) -> Vec<u8> {
        if self.modes.focus {
            if focused {
                b"\x1b[I".to_vec()
            } else {
                b"\x1b[O".to_vec()
            }
        } else {
            Vec::new()
        }
    }
}
