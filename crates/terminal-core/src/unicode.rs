//! Constant-memory extended grapheme boundary state, Unicode 18 / UAX #29 rev 49.
// Keep the upstream generated UCD file unmodified. It includes word/sentence
// tables as well; those unused generated symbols deliberately remain private.
#[allow(dead_code)]
#[path = "../../../vendor/unicode-segmentation/src/tables.rs"]
mod tables;
use GraphemeCat::*;
use tables::grapheme::{GraphemeCat, grapheme_category};

#[derive(Debug, Clone)]
pub(crate) struct Segmenter {
    previous: Option<GraphemeCat>,
    regional_odd: bool,
    ep_extend_tail: bool,
    zwj_after_ep: bool,
    linker_tail: bool,
}
impl Segmenter {
    pub fn new(text: &str) -> Self {
        let mut state = Self {
            previous: None,
            regional_odd: false,
            ep_extend_tail: false,
            zwj_after_ep: false,
            linker_tail: false,
        };
        for ch in text.chars() {
            state.push(ch);
        }
        state
    }
    /// Returns true when this scalar starts a new cluster, then updates state.
    pub fn push(&mut self, ch: char) -> bool {
        let cat = grapheme_category(ch).2;
        let boundary = match (self.previous, cat) {
            (None, _) => true,
            (Some(GC_CR), GC_LF) => false,
            (Some(GC_Control | GC_CR | GC_LF), _) | (_, GC_Control | GC_CR | GC_LF) => true,
            (Some(GC_L), GC_L | GC_V | GC_LV | GC_LVT) => false,
            (Some(GC_LV | GC_V), GC_V | GC_T) => false,
            (Some(GC_LVT | GC_T), GC_T) => false,
            (_, GC_Extend | GC_ZWJ | GC_SpacingMark) | (Some(GC_Prepend), _) => false,
            (_, GC_InCB_Consonant) if self.linker_tail => false,
            (Some(GC_ZWJ), GC_Extended_Pictographic) if self.zwj_after_ep => false,
            (Some(GC_Regional_Indicator), GC_Regional_Indicator) if self.regional_odd => false,
            _ => true,
        };
        if boundary {
            self.regional_odd = false;
            self.ep_extend_tail = false;
            self.zwj_after_ep = false;
            self.linker_tail = false;
        }
        self.regional_odd = cat == GC_Regional_Indicator && !self.regional_odd;
        let after_ep = self.ep_extend_tail;
        self.zwj_after_ep = cat == GC_ZWJ && after_ep;
        self.ep_extend_tail = cat == GC_Extended_Pictographic || cat == GC_Extend && after_ep;
        if tables::is_incb_linker(ch) {
            self.linker_tail = true;
        } else if !(matches!(cat, GC_Extend | GC_ZWJ) && ch != '\u{200c}') {
            self.linker_tail = false;
        }
        self.previous = Some(cat);
        boundary
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn official_unicode_18_break_tests() {
        let data = include_str!("../tests/fixtures/GraphemeBreakTest-18.0.0.txt");
        let mut count = 0;
        for (line_no, line) in data.lines().enumerate() {
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let mut state = Segmenter::new("");
            let mut boundary = true;
            for token in line.split_whitespace() {
                match token {
                    "÷" => boundary = true,
                    "×" => boundary = false,
                    _ => {
                        let code = u32::from_str_radix(token, 16).unwrap();
                        let ch = char::from_u32(code).unwrap();
                        assert_eq!(
                            state.push(ch),
                            boundary,
                            "line {} U+{code:04X}",
                            line_no + 1
                        );
                    }
                }
            }
            count += 1;
        }
        assert!(count > 700);
    }
}
