use crate::{Terminal, model::*, parser::Csi};
impl Terminal {
    pub(crate) fn control(&mut self, c: u8) {
        if !matches!(c, 0 | 7 | 0x7f) {
            self.open = None;
        }
        match c {
            8 => {
                let (left, _) = self.horizontal_margins();
                let minimum = if self.screen().cursor.col >= left {
                    left
                } else {
                    0
                };
                let c = &mut self.screen_mut().cursor;
                c.col = c.col.saturating_sub(1).max(minimum);
                c.pending_wrap = false;
            }
            9 => self.tab(1, false),
            10..=12 => {
                self.screen_mut().cursor.pending_wrap = false;
                self.index(false);
                if self.modes.newline {
                    self.carriage_return();
                }
            }
            13 => self.carriage_return(),
            14 => self.charset_slot = 1,
            15 => self.charset_slot = 0,
            _ => {}
        }
    }
    pub(crate) fn escape(&mut self, i: &[u8], f: u8) {
        self.open = None;
        match (i, f) {
            ([], b'7') => self.save(),
            ([], b'8') => self.restore(),
            ([], b'D') => {
                self.screen_mut().cursor.pending_wrap = false;
                self.index(false);
            }
            ([], b'E') => {
                self.screen_mut().cursor.pending_wrap = false;
                self.index(false);
                self.carriage_return();
            }
            ([], b'M') => {
                self.screen_mut().cursor.pending_wrap = false;
                self.index(true);
            }
            ([], b'H') => {
                let col = self.screen().cursor.col;
                self.tabs[col] = true;
            }
            ([], b'=') => self.modes.application_keypad = true,
            ([], b'>') => self.modes.application_keypad = false,
            ([], b'c') => self.hard_reset(),
            ([b'('], b'0') => self.charset[0] = true,
            ([b'('], b'B') => self.charset[0] = false,
            ([b')'], b'0') => self.charset[1] = true,
            ([b')'], b'B') => self.charset[1] = false,
            _ => {}
        }
    }
    fn save(&mut self) {
        let saved = Saved {
            cursor: self.screen().cursor.clone(),
            style: self.pen.clone(),
            origin: self.modes.origin,
            charset: self.charset,
            charset_slot: self.charset_slot,
        };
        self.screen_mut().saved = saved;
    }
    fn restore(&mut self) {
        let s = self.screen().saved.clone();
        self.pen = s.style;
        self.modes.origin = s.origin;
        self.charset = s.charset;
        self.charset_slot = s.charset_slot;
        let mut c = s.cursor;
        // DEC saved state does not include cursor appearance or visibility.
        c.visible = self.screen().cursor.visible;
        c.shape = self.screen().cursor.shape;
        c.row = c.row.min(self.height - 1);
        c.col = c.col.min(self.cols - 1);
        if self.modes.origin {
            c.row = c
                .row
                .clamp(self.screen().margins.0, self.screen().margins.1);
            let (left, right) = self.horizontal_margins();
            c.col = c.col.clamp(left, right);
        }
        self.screen_mut().cursor = c;
    }
    fn home(&mut self) {
        let row = if self.modes.origin {
            self.screen().margins.0
        } else {
            0
        };
        let col = if self.modes.origin {
            self.horizontal_margins().0
        } else {
            0
        };
        let c = &mut self.screen_mut().cursor;
        c.row = row;
        c.col = col;
        c.pending_wrap = false;
    }
    fn tab(&mut self, count: usize, reverse: bool) {
        let mut col = self.screen().cursor.col;
        let (margin_left, _) = self.horizontal_margins();
        let left = if col >= margin_left { margin_left } else { 0 };
        let right = self.write_bounds(col).1;
        for _ in 0..count.min(self.cols) {
            col = if reverse {
                (left..col).rev().find(|&c| self.tabs[c]).unwrap_or(left)
            } else {
                (col + 1..=right).find(|&c| self.tabs[c]).unwrap_or(right)
            };
        }
        let c = &mut self.screen_mut().cursor;
        c.col = col;
        c.pending_wrap = false;
    }
    pub(crate) fn csi(&mut self, c: Csi) {
        let n = c.count(0);
        let value = c.param(0, 0);
        let f = c.final_byte;
        if f == b'm' && c.private.is_none() {
            self.sgr(&c);
            return;
        }
        if f == b'u' && matches!(c.private, Some(b'>' | b'<' | b'=' | b'?')) {
            self.keyboard(&c);
            return;
        }
        // Publication-only queries preserve repair adjacency. Scrolling may preserve
        // pending wrap but must close the previous cluster's positional repair.
        let preserve = matches!(f, b'n' | b'c' | b'p' | b't');
        if !preserve {
            self.open = None;
        }
        let row = self.screen().cursor.row;
        let col = self.screen().cursor.col;
        let (top, bottom) = if self.modes.origin {
            self.screen().margins
        } else {
            (0, self.height - 1)
        };
        let (left, right) = if self.modes.origin {
            self.horizontal_margins()
        } else {
            (0, self.cols - 1)
        };
        match f {
            b'A' | b'B' | b'C' | b'D' | b'E' | b'F' | b'G' | b'H' | b'f' | b'd' | b'a' | b'e'
            | b'`' => {
                let cursor = &mut self.screen_mut().cursor;
                cursor.pending_wrap = false;
                match f {
                    b'A' | b'F' => cursor.row = cursor.row.saturating_sub(n).max(top),
                    b'B' | b'E' | b'e' => cursor.row = cursor.row.saturating_add(n).min(bottom),
                    b'C' | b'a' => cursor.col = cursor.col.saturating_add(n).min(right),
                    b'D' => cursor.col = cursor.col.saturating_sub(n).max(left),
                    b'G' | b'`' => cursor.col = left.saturating_add(n - 1).min(right),
                    b'd' => cursor.row = top.saturating_add(n - 1).min(bottom),
                    b'H' | b'f' => {
                        cursor.row = top.saturating_add(n - 1).min(bottom);
                        cursor.col = left.saturating_add(c.count(1) - 1).min(right);
                    }
                    _ => {}
                }
                if f == b'E' || f == b'F' {
                    cursor.col = left;
                }
            }
            b'I' => self.tab(n, false),
            b'Z' => self.tab(n, true),
            b'g' => match value {
                0 => self.tabs[col] = false,
                3 => {
                    self.tabs.fill(false);
                    self.tabs_cleared = true;
                }
                _ => {}
            },
            b'J' => {
                if value == 2 {
                    self.graphics.clear_screen(self.is_alternate);
                }
                if value == 3 {
                    self.history.clear();
                    self.history_bytes = 0;
                    self.history_epoch += 1;
                    self.prune_graphics();
                } else {
                    let erase = self.pen.erase();
                    let selective = c.private == Some(b'?');
                    for r in 0..self.height {
                        let span = match value {
                            0 if r == row => Some((col, self.cols)),
                            0 if r > row => Some((0, self.cols)),
                            1 if r == row => Some((0, col + 1)),
                            1 if r < row => Some((0, self.cols)),
                            2 => Some((0, self.cols)),
                            _ => None,
                        };
                        if let Some((a, b)) = span {
                            self.row_mut(r).erase(a, b, &erase, selective);
                        }
                    }
                    self.screen_mut().cursor.pending_wrap = false;
                }
            }
            b'K' => {
                let span = match value {
                    0 => (col, self.cols),
                    1 => (0, col + 1),
                    2 => (0, self.cols),
                    _ => (0, 0),
                };
                let erase = self.pen.erase();
                self.row_mut(row)
                    .erase(span.0, span.1, &erase, c.private == Some(b'?'));
                self.screen_mut().cursor.pending_wrap = false;
            }
            b'X' => {
                let end = col.saturating_add(n).min(self.cols);
                let erase = self.pen.erase();
                self.row_mut(row).erase(col, end, &erase, false);
                self.screen_mut().cursor.pending_wrap = false;
            }
            b'@' | b'P' => {
                let (left, right) = self.horizontal_margins();
                let erase = self.pen.erase();
                if (left..=right).contains(&col) {
                    self.row_mut(row)
                        .shift_within(col, right + 1, n, f == b'@', &erase);
                    self.screen_mut().cursor.pending_wrap = false;
                } else if f == b'@' {
                    self.screen_mut().cursor.pending_wrap = false;
                }
            }
            b'L' | b'M' => {
                let (t, b) = self.screen().margins;
                let (left, right) = self.horizontal_margins();
                if row >= t && row <= b && (left..=right).contains(&col) {
                    self.scroll(row, b, n, f == b'M', false);
                    self.screen_mut().cursor.col = left;
                }
                self.screen_mut().cursor.pending_wrap = false;
            }
            b'S' | b'T' => {
                let (t, b) = self.screen().margins;
                self.scroll(t, b, n, f == b'S', true);
            }
            b'r' if c.private.is_none() => {
                let t = n - 1;
                let value = c.param(1, self.height as u32);
                let b = if value == 0 {
                    self.height
                } else {
                    value as usize
                } - 1;
                if t < b && b < self.height {
                    self.screen_mut().margins = (t, b);
                    self.home();
                }
            }
            b's' if c.private.is_none() && self.modes.left_right_margins => {
                let left = n - 1;
                let value = c.param(1, self.cols as u32);
                let right = if value == 0 {
                    self.cols
                } else {
                    value as usize
                } - 1;
                if left < right && right < self.cols {
                    self.screen_mut().horizontal_margins = (left, right);
                    self.home();
                }
            }
            b's' if c.private.is_none() => self.save(),
            b'u' if c.private.is_none() => self.restore(),
            b'h' | b'l' => {
                for p in &c.params {
                    self.mode(
                        p.first().copied().flatten().unwrap_or(0),
                        f == b'h',
                        c.private == Some(b'?'),
                    );
                }
            }
            b'n' => match value {
                5 if c.private.is_none() => self.reply(b"\x1b[0n".to_vec()),
                6 => {
                    let r = row + 1
                        - if self.modes.origin {
                            self.screen().margins.0
                        } else {
                            0
                        };
                    self.reply(format!(
                        "\x1b[{}{};{}R",
                        if c.private == Some(b'?') { "?" } else { "" },
                        r,
                        col + 1 - left
                    ));
                }
                _ => {}
            },
            b'c' if c.private.is_none() => self.reply(b"\x1b[?62;22c".to_vec()),
            b'c' if c.private == Some(b'>') => self.reply(b"\x1b[>0;100;0c".to_vec()),
            b'p' if c.intermediates == *b"$" && c.private == Some(b'?') => {
                let status = self.mode_status(value).map_or(0, |b| if b { 1 } else { 2 });
                self.reply(format!("\x1b[?{value};{status}$y"));
            }
            b'p' if c.intermediates == *b"!" => self.soft_reset(),
            b'q' if c.intermediates == *b" " => self.screen_mut().cursor.shape = value.min(6) as u8,
            b'q' if c.intermediates == *b"\"" => self.protected = value == 1,
            b'b' => {
                if n > 1_048_576 {
                    self.rejected_rep += 1;
                } else if let Some(text) = self.repeat.clone() {
                    self.pending_repeat = Some(crate::RepeatWork {
                        text,
                        style: self.pen.clone(),
                        link: self.link.clone(),
                        flags: if self.protected { 2 } else { 0 },
                        remaining: n,
                    });
                }
            }
            b't' if value == 18 => self.reply(format!("\x1b[8;{};{}t", self.height, self.cols)),
            _ => {}
        }
    }
    fn mode(&mut self, n: u32, on: bool, private: bool) {
        if !private {
            match n {
                4 => self.modes.insert = on,
                20 => self.modes.newline = on,
                _ => {}
            }
            return;
        }
        match n {
            1 => self.modes.application_cursor = on,
            5 => self.modes.reverse_video = on,
            6 => {
                self.modes.origin = on;
                self.home();
            }
            7 => {
                self.modes.autowrap = on;
                if !on {
                    self.screen_mut().cursor.pending_wrap = false;
                }
            }
            25 => self.screen_mut().cursor.visible = on,
            69 => {
                self.modes.left_right_margins = on;
                if !on {
                    let right = self.cols - 1;
                    for screen in [&mut self.primary, &mut self.alternate] {
                        screen.horizontal_margins = (0, right);
                        screen.cursor.pending_wrap = false;
                    }
                }
            }
            9 | 1000 | 1002 | 1003 => self.modes.mouse = if on { n as u16 } else { 0 },
            1004 => self.modes.focus = on,
            1006 => self.modes.sgr_mouse = on,
            2004 => self.modes.bracketed_paste = on,
            47 | 1047 => {
                if n == 1047 && !on && self.is_alternate {
                    self.clear_active();
                }
                self.select_screen(on);
            }
            1048 => {
                if on {
                    self.save()
                } else {
                    self.restore()
                }
            }
            1049 => {
                if on && !self.is_alternate {
                    self.save();
                    self.select_screen(true);
                    self.clear_active();
                    self.home();
                } else if !on && self.is_alternate {
                    self.select_screen(false);
                    self.restore();
                }
            }
            2026 => {
                if on {
                    if self.sync_deadline.is_none() {
                        self.sync_deadline = Some(self.now.saturating_add(150));
                    }
                } else {
                    self.sync_deadline = None;
                }
            }
            _ => {}
        }
    }
    fn mode_status(&self, n: u32) -> Option<bool> {
        Some(match n {
            1 => self.modes.application_cursor,
            5 => self.modes.reverse_video,
            6 => self.modes.origin,
            7 => self.modes.autowrap,
            25 => self.screen().cursor.visible,
            69 => self.modes.left_right_margins,
            47 | 1047 | 1049 => self.is_alternate,
            1004 => self.modes.focus,
            1006 => self.modes.sgr_mouse,
            2004 => self.modes.bracketed_paste,
            2026 => self.sync_deadline.is_some(),
            9 | 1000 | 1002 | 1003 => self.modes.mouse == n as u16,
            _ => return None,
        })
    }
    fn select_screen(&mut self, alt: bool) {
        if self.is_alternate != alt {
            self.open = None;
            self.is_alternate = alt;
            self.screen_epoch += 1;
        }
    }
    fn clear_active(&mut self) {
        self.screen_mut().prompt_phase = PromptPhase::Inactive;
        self.screen_mut().prompt_redraw = false;
        self.screen_mut().prompt_start = None;
        self.screen_epoch += 1;
        self.graphics.clear_screen(self.is_alternate);
        for r in 0..self.height {
            let blank = self.blank();
            self.screen_mut().rows[r] = blank;
        }
        self.screen_mut().cursor.pending_wrap = false;
    }
    fn soft_reset(&mut self) {
        self.modes = Modes::default();
        self.pen = Style::default();
        self.link = None;
        self.protected = false;
        self.charset = [false; 2];
        self.charset_slot = 0;
        self.sync_deadline = None;
        self.repeat = None;
        self.pending_repeat = None;
        self.open = None;
        let h = self.height;
        let cols = self.cols;
        let s = self.screen_mut();
        s.margins = (0, h - 1);
        s.cursor.visible = true;
        s.cursor.pending_wrap = false;
        s.cursor.shape = 0;
        for s in [&mut self.primary, &mut self.alternate] {
            s.prompt_phase = PromptPhase::Inactive;
            s.prompt_redraw = false;
            s.prompt_start = None;
            s.horizontal_margins = (0, cols - 1);
            s.keyboard.clear();
            s.keyboard_flags = 0;
        }
    }
    fn hard_reset(&mut self) {
        self.graphics.clear();
        self.soft_reset();
        self.is_alternate = false;
        self.clear_active();
        self.home();
        self.primary.saved = Saved::default();
        self.is_alternate = true;
        self.clear_active();
        self.home();
        self.alternate.saved = Saved::default();
        self.is_alternate = false;
        self.history.clear();
        self.history_bytes = 0;
        self.tabs = (0..self.cols).map(|c| c > 0 && c % 8 == 0).collect();
        self.tabs_cleared = false;
        self.primary.cursor = Cursor {
            visible: true,
            ..Cursor::default()
        };
        self.alternate.cursor = Cursor {
            visible: true,
            ..Cursor::default()
        };
        self.document_epoch += 1;
        self.history_epoch += 1;
        self.viewport = crate::viewport::Viewport::FollowTail;
        self.palette = crate::default_palette();
        self.default_fg = [230, 230, 230];
        self.default_bg = [10, 10, 11];
    }
    fn keyboard(&mut self, c: &Csi) {
        let flags = c.param(0, 0) & 31;
        match c.private {
            Some(b'?') => self.reply(format!("\x1b[?{}u", self.screen().keyboard_flags)),
            Some(b'>') => {
                let s = self.screen_mut();
                if s.keyboard.len() == 32 {
                    s.keyboard.remove(0);
                }
                s.keyboard.push(s.keyboard_flags);
                s.keyboard_flags = flags;
            }
            Some(b'<') => {
                for _ in 0..c.count(0).min(32) {
                    let s = self.screen_mut();
                    s.keyboard_flags = s.keyboard.pop().unwrap_or(0);
                }
            }
            Some(b'=') => {
                let s = self.screen_mut();
                match c.param(1, 1) {
                    1 => s.keyboard_flags = flags,
                    2 => s.keyboard_flags |= flags,
                    3 => s.keyboard_flags &= !flags,
                    _ => {}
                }
            }
            _ => {}
        }
    }
    fn sgr(&mut self, c: &Csi) {
        if c.params.is_empty() {
            self.pen = Style::default();
            return;
        }
        let mut i = 0;
        while i < c.params.len() {
            let p = &c.params[i];
            let code = p[0].unwrap_or(0);
            match code {
                0 => self.pen = Style::default(),
                1 => self.pen.bold = true,
                2 => self.pen.faint = true,
                3 => self.pen.italic = true,
                4 => self.pen.underline = p.get(1).copied().flatten().unwrap_or(1).min(5) as u8,
                5 | 6 => self.pen.blink = true,
                7 => self.pen.inverse = true,
                8 => self.pen.conceal = true,
                9 => self.pen.strike = true,
                21 => self.pen.underline = 2,
                22 => {
                    self.pen.bold = false;
                    self.pen.faint = false;
                }
                23 => self.pen.italic = false,
                24 => self.pen.underline = 0,
                25 => self.pen.blink = false,
                27 => self.pen.inverse = false,
                28 => self.pen.conceal = false,
                29 => self.pen.strike = false,
                30..=37 => self.pen.foreground = Color::Indexed((code - 30) as u8),
                40..=47 => self.pen.background = Color::Indexed((code - 40) as u8),
                90..=97 => self.pen.foreground = Color::Indexed((code - 90 + 8) as u8),
                100..=107 => self.pen.background = Color::Indexed((code - 100 + 8) as u8),
                39 => self.pen.foreground = Color::Default,
                49 => self.pen.background = Color::Default,
                59 => self.pen.underline_color = Color::Default,
                38 | 48 | 58 => {
                    let mut color = None;
                    if p.len() > 1 {
                        if p[1] == Some(5) {
                            color = p
                                .get(2)
                                .copied()
                                .flatten()
                                .filter(|v| *v <= 255)
                                .map(|v| Color::Indexed(v as u8));
                        } else if p[1] == Some(2) {
                            let start = if p.len() >= 6 { 3 } else { 2 };
                            if let Some(rgb) = p.get(start..start + 3)
                                && rgb.iter().all(|v| v.is_some_and(|v| v <= 255))
                            {
                                color = Some(Color::Rgb(
                                    rgb[0].unwrap_or(0) as u8,
                                    rgb[1].unwrap_or(0) as u8,
                                    rgb[2].unwrap_or(0) as u8,
                                ));
                            }
                        }
                    } else if i + 1 < c.params.len() {
                        let mode = c.param(i + 1, 0);
                        let extra = if mode == 5 {
                            2
                        } else if mode == 2 {
                            4
                        } else {
                            1
                        };
                        if i + extra < c.params.len() {
                            if mode == 5 && c.param(i + 2, 256) <= 255 {
                                color = Some(Color::Indexed(c.param(i + 2, 0) as u8));
                            } else if mode == 2 && (i + 2..=i + 4).all(|j| c.param(j, 256) <= 255) {
                                color = Some(Color::Rgb(
                                    c.param(i + 2, 0) as u8,
                                    c.param(i + 3, 0) as u8,
                                    c.param(i + 4, 0) as u8,
                                ));
                            }
                            i += extra;
                        }
                    }
                    if let Some(color) = color {
                        match code {
                            38 => self.pen.foreground = color,
                            48 => self.pen.background = color,
                            _ => self.pen.underline_color = color,
                        }
                    }
                }
                53 => self.pen.overline = true,
                55 => self.pen.overline = false,
                _ => {}
            }
            i += 1;
        }
    }
    pub(crate) fn osc(&mut self, bytes: &[u8]) {
        let text = String::from_utf8_lossy(bytes);
        let Some((code, value)) = text.split_once(';') else {
            return;
        };
        match code {
            "133" => match value.split(';').next() {
                Some("A") => {
                    let screen = self.screen_mut();
                    screen.prompt_phase = PromptPhase::Drawing;
                    screen.prompt_redraw =
                        value.split(';').skip(1).any(|option| option == "redraw=1");
                    screen.prompt_start =
                        screen.rows.get(screen.cursor.row).map(|row| PromptAnchor {
                            row: row.id,
                            col: screen.cursor.col,
                            pending_wrap: screen.cursor.pending_wrap,
                        });
                }
                Some("B") => self.screen_mut().prompt_phase = PromptPhase::InputReady,
                Some("C" | "D") => {
                    self.screen_mut().prompt_phase = PromptPhase::Inactive;
                    self.screen_mut().prompt_redraw = false;
                    self.screen_mut().prompt_start = None;
                }
                _ => {}
            },
            "0" | "2" => {
                self.title = value
                    .chars()
                    .filter(|c| !c.is_control())
                    .scan(0, |len, c| {
                        *len += c.len_utf8();
                        (*len <= 4096).then_some(c)
                    })
                    .collect()
            }
            "7" => {
                if value.len() <= 8192 {
                    self.cwd = Some(value.to_owned());
                }
            }
            "8" => {
                if let Some((_, uri)) = value.split_once(';')
                    && uri.len() <= 8192
                {
                    self.link = if uri.is_empty() {
                        None
                    } else {
                        Some(uri.to_owned())
                    };
                }
            }
            "4" => {
                let parts: Vec<_> = value.split(';').collect();
                for pair in parts.as_chunks::<2>().0 {
                    if let Ok(index) = pair[0].parse::<usize>()
                        && index < 256
                    {
                        if pair[1] == "?" {
                            let [r, g, b] = self.palette[index];
                            self.reply(format!("\x1b]4;{index};rgb:{r:02x}{r:02x}/{g:02x}{g:02x}/{b:02x}{b:02x}\x1b\\"));
                        } else if let Some(color) = parse_color(pair[1]) {
                            self.palette[index] = color;
                        }
                    }
                }
            }
            "10" | "11" => {
                if value == "?" {
                    let [r, g, b] = if code == "10" {
                        self.default_fg
                    } else {
                        self.default_bg
                    };
                    self.reply(format!(
                        "\x1b]{code};rgb:{r:02x}{r:02x}/{g:02x}{g:02x}/{b:02x}{b:02x}\x1b\\"
                    ));
                } else if let Some(color) = parse_color(value) {
                    if code == "10" {
                        self.default_fg = color
                    } else {
                        self.default_bg = color
                    }
                }
            }
            "104" => {
                let defaults = crate::default_palette();
                if value.is_empty() {
                    self.palette = defaults;
                } else {
                    for index in value
                        .split(';')
                        .filter_map(|s| s.parse::<usize>().ok())
                        .filter(|i| *i < 256)
                    {
                        self.palette[index] = defaults[index];
                    }
                }
            }
            "52" if value
                .split_once(';')
                .is_some_and(|(_, payload)| payload == "?") =>
            {
                self.reply(b"\x1b]52;c;\x1b\\".to_vec())
            }
            "52" => {}
            _ => {}
        }
    }
}
fn parse_color(value: &str) -> Option<[u8; 3]> {
    if let Some(hex) = value
        .strip_prefix('#')
        .filter(|v| v.len() == 6 && v.is_ascii())
    {
        Some([
            u8::from_str_radix(&hex[0..2], 16).ok()?,
            u8::from_str_radix(&hex[2..4], 16).ok()?,
            u8::from_str_radix(&hex[4..6], 16).ok()?,
        ])
    } else if let Some(rgb) = value.strip_prefix("rgb:") {
        let p: Vec<_> = rgb.split('/').collect();
        if p.len() != 3 {
            return None;
        }
        let mut out = [0; 3];
        for (i, p) in p.iter().enumerate() {
            if p.is_empty() || p.len() > 4 {
                return None;
            }
            let n = u32::from_str_radix(p, 16).ok()?;
            out[i] = (n * 255 / ((1u32 << (p.len() * 4)) - 1)) as u8;
        }
        Some(out)
    } else {
        None
    }
}
