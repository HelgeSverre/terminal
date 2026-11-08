//! Single-writer terminal state, independent of the platform and renderer.
mod commands;
pub mod display_clear;
pub mod ffi;
pub mod graphics;
pub mod input;
mod margins;
pub mod model;
mod osc52;
pub mod parser;
mod resize;
pub mod search;
mod unicode;
mod viewport;
use model::*;
use parser::{Operation, VtParser};
use std::{
    collections::{BTreeSet, VecDeque},
    sync::Arc,
};
use unicode::Segmenter;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("geometry must be 1..=4096 with at most 1,048,576 cells")]
    Geometry,
}
#[derive(Debug, Clone)]
struct OpenCluster {
    row: usize,
    col: usize,
    text: String,
    width: usize,
    style: Style,
    link: Option<String>,
    flags: u8,
    capped: bool,
    segmenter: Segmenter,
    scalar_count: usize,
}
#[derive(Debug)]
struct RepeatWork {
    text: String,
    style: Style,
    link: Option<String>,
    flags: u8,
    remaining: usize,
}
/// A bounded, write-only OSC 52 request for the native host.
///
/// The terminal core owns both the ID and its outstanding lifetime. It never
/// accesses a platform clipboard itself.
#[derive(Debug, PartialEq, Eq)]
pub struct ClipboardWriteRequest {
    pub id: u64,
    pub data: Vec<u8>,
}

pub const MAX_OSC52_BYTES: usize = 1_024 * 1_024;
pub const MAX_OUTSTANDING_OSC52_REQUESTS: usize = 4;
#[derive(Debug)]
pub struct Terminal {
    pub graphics: graphics::AttachmentStore,
    pub cell_width_px: u32,
    pub cell_height_px: u32,
    parser: VtParser,
    pub ascii_fast_path: bool,
    pub cols: usize,
    pub height: usize,
    pub primary: Screen,
    pub alternate: Screen,
    pub is_alternate: bool,
    pub modes: Modes,
    pub pen: Style,
    pub link: Option<String>,
    pub protected: bool,
    pub charset: [bool; 2],
    pub charset_slot: usize,
    pub history: VecDeque<Arc<Row>>,
    pub history_limit: usize,
    pub history_byte_limit: usize,
    history_bytes: usize,
    next_row: u64,
    open: Option<OpenCluster>,
    repeat: Option<String>,
    pending_repeat: Option<RepeatWork>,
    pub replies: VecDeque<Vec<u8>>,
    reply_bytes: usize,
    pub revision: u64,
    pub geometry_epoch: u64,
    pub document_epoch: u64,
    pub history_epoch: u64,
    pub screen_epoch: u64,
    viewport: viewport::Viewport,
    viewport_clamp_revision: u64,
    search_hit: Option<search::SearchHit>,
    pub title: String,
    pub cwd: Option<String>,
    pub tabs: Vec<bool>,
    pub tabs_cleared: bool,
    pub sync_deadline: Option<u64>,
    now: u64,
    pub palette: Vec<[u8; 3]>,
    pub default_fg: [u8; 3],
    pub default_bg: [u8; 3],
    pub rejected_rep: u64,
    clipboard_requests: VecDeque<ClipboardWriteRequest>,
    outstanding_clipboard_requests: BTreeSet<u64>,
    next_clipboard_request_id: u64,
    osc52: Option<osc52::Decoder>,
}
impl Terminal {
    pub fn new(cols: usize, rows: usize) -> Result<Self, Error> {
        Self::validate_geometry(cols, rows)?;
        let mut next = 1;
        let mut grid = || {
            (0..rows)
                .map(|_| {
                    let r = Arc::new(Row::new(next, cols, &Style::default()));
                    next += 1;
                    r
                })
                .collect()
        };
        let primary = Screen::new(grid());
        let alternate = Screen::new(grid());
        Ok(Self {
            graphics: graphics::AttachmentStore::default(),
            cell_width_px: 8,
            cell_height_px: 16,
            parser: VtParser::default(),
            ascii_fast_path: true,
            cols,
            height: rows,
            primary,
            alternate,
            is_alternate: false,
            modes: Modes::default(),
            pen: Style::default(),
            link: None,
            protected: false,
            charset: [false; 2],
            charset_slot: 0,
            history: VecDeque::new(),
            history_limit: 50_000,
            history_byte_limit: 64 * 1024 * 1024,
            history_bytes: 0,
            next_row: next,
            open: None,
            repeat: None,
            pending_repeat: None,
            replies: VecDeque::new(),
            reply_bytes: 0,
            revision: 0,
            geometry_epoch: 1,
            document_epoch: 1,
            history_epoch: 1,
            screen_epoch: 1,
            viewport: viewport::Viewport::FollowTail,
            viewport_clamp_revision: 0,
            search_hit: None,
            title: String::new(),
            cwd: None,
            tabs: (0..cols).map(|c| c > 0 && c % 8 == 0).collect(),
            tabs_cleared: false,
            sync_deadline: None,
            now: 0,
            palette: default_palette(),
            default_fg: [230, 230, 230],
            default_bg: [10, 10, 11],
            rejected_rep: 0,
            clipboard_requests: VecDeque::new(),
            outstanding_clipboard_requests: BTreeSet::new(),
            next_clipboard_request_id: 1,
            osc52: None,
        })
    }
    pub fn validate_geometry(cols: usize, rows: usize) -> Result<(), Error> {
        if !(1..=4096).contains(&cols)
            || !(1..=4096).contains(&rows)
            || cols.checked_mul(rows).is_none_or(|n| n > 1_048_576)
        {
            Err(Error::Geometry)
        } else {
            Ok(())
        }
    }
    pub fn screen(&self) -> &Screen {
        if self.is_alternate {
            &self.alternate
        } else {
            &self.primary
        }
    }
    fn screen_mut(&mut self) -> &mut Screen {
        if self.is_alternate {
            &mut self.alternate
        } else {
            &mut self.primary
        }
    }
    fn row_mut(&mut self, row: usize) -> &mut Row {
        Arc::make_mut(&mut self.screen_mut().rows[row])
    }
    pub(crate) fn blank(&mut self) -> Arc<Row> {
        let id = self.next_row;
        self.next_row += 1;
        Arc::new(Row::new(id, self.cols, &self.pen.erase()))
    }
    /// Returns the accepted prefix. Reply pressure pauses before the next byte.
    pub fn feed(&mut self, bytes: &[u8], now_ms: u64) -> usize {
        self.now = now_ms;
        self.graphics.tick(now_ms);
        self.tick(now_ms);
        self.run_repeat_quantum();
        if self.pending_repeat.is_some() {
            return 0;
        }
        let mut parser = std::mem::take(&mut self.parser);
        let mut consumed = 0;
        let limit = bytes.len().min(65_536);
        while consumed < limit {
            if self.reply_bytes >= 32_768 {
                break;
            }
            let string_run =
                parser.advance_string_run(&bytes[consumed..limit], |op| self.apply(op));
            if string_run > 0 {
                consumed += string_run;
                continue;
            }
            let byte = bytes[consumed];
            if self.ascii_fast_path
                && parser.is_ground()
                && !self.modes.insert
                && !self.charset[self.charset_slot]
                && (0x20..=0x7e).contains(&byte)
            {
                let run = bytes[consumed..limit]
                    .iter()
                    .position(|b| !(0x20..=0x7e).contains(b))
                    .unwrap_or(limit - consumed);
                self.print_ascii(&bytes[consumed..consumed + run]);
                consumed += run;
            } else {
                parser.advance(&[byte], |op| self.apply(op));
                consumed += 1;
            }
            if self.pending_repeat.is_some() {
                self.run_repeat_quantum();
                break;
            }
        }
        self.parser = parser;
        if consumed > 0 {
            self.revision += 1;
        }
        consumed
    }
    pub fn has_pending_work(&self) -> bool {
        self.pending_repeat.is_some()
    }
    fn run_repeat_quantum(&mut self) {
        let Some(mut work) = self.pending_repeat.take() else {
            return;
        };
        let count = work.remaining.min(4096);
        let width = work.text.as_str().width().clamp(1, 2);
        for _ in 0..count {
            self.place(
                &work.text,
                width,
                &work.style,
                work.link.as_deref(),
                work.flags,
            );
        }
        work.remaining -= count;
        if work.remaining > 0 {
            self.pending_repeat = Some(work);
        }
        self.revision += 1;
    }
    pub fn finish(&mut self) {
        let mut parser = std::mem::take(&mut self.parser);
        parser.finish(|op| self.apply(op));
        self.parser = parser;
        self.graphics.abort();
        self.open = None;
        self.sync_deadline = None;
        self.revision += 1;
    }
    pub fn tick(&mut self, now_ms: u64) {
        self.now = now_ms;
        if self.sync_deadline.is_some_and(|d| now_ms >= d) {
            self.sync_deadline = None;
            self.revision += 1;
        }
    }
    pub fn take_replies(&mut self) -> Vec<Vec<u8>> {
        self.reply_bytes = 0;
        self.replies.drain(..).collect()
    }
    /// Transfers queued clipboard writes to the host without using snapshots.
    pub fn take_clipboard_requests(&mut self) -> Vec<ClipboardWriteRequest> {
        self.clipboard_requests.drain(..).collect()
    }
    /// Completes a host request by its core-owned ID. Permission policy and
    /// clipboard side effects belong to the host; the core emits no reply.
    pub fn complete_clipboard_request(&mut self, id: u64) -> bool {
        self.outstanding_clipboard_requests.remove(&id)
    }
    pub(crate) fn request_clipboard_write(&mut self, data: Vec<u8>) {
        if self.outstanding_clipboard_requests.len() >= MAX_OUTSTANDING_OSC52_REQUESTS {
            return;
        }
        let id = self.next_clipboard_request_id;
        self.next_clipboard_request_id = self.next_clipboard_request_id.wrapping_add(1);
        if id == 0 || !self.outstanding_clipboard_requests.insert(id) {
            return;
        }
        self.clipboard_requests
            .push_back(ClipboardWriteRequest { id, data });
    }
    fn reply(&mut self, reply: impl Into<Vec<u8>>) {
        let reply = reply.into();
        self.reply_bytes += reply.len();
        self.replies.push_back(reply);
    }
    fn apply(&mut self, op: Operation) {
        match op {
            Operation::Print(ch) => self.print(ch),
            Operation::Control(c) => self.control(c),
            Operation::Escape {
                intermediates,
                final_byte,
            } => self.escape(&intermediates, final_byte),
            Operation::Csi(c) => self.csi(c),
            Operation::Osc(s) => self.osc(&s),
            Operation::Osc52Start => {
                self.osc52 = Some(osc52::Decoder::new(
                    self.outstanding_clipboard_requests.len() < MAX_OUTSTANDING_OSC52_REQUESTS,
                ));
            }
            Operation::Osc52Data(bytes) => {
                if let Some(decoder) = &mut self.osc52 {
                    decoder.push(&bytes);
                }
            }
            Operation::Osc52End => {
                let Some(decoder) = self.osc52.take() else {
                    return;
                };
                match decoder.finish() {
                    osc52::Outcome::Write(data) => self.request_clipboard_write(data),
                    osc52::Outcome::Query => self.reply(b"\x1b]52;c;\x1b\\".to_vec()),
                    osc52::Outcome::Reject => {}
                }
            }
            Operation::Osc52Abort => self.osc52 = None,
            Operation::GraphicsAbort => self.graphics.abort(),
            Operation::Graphics(packet) => {
                let cursor = self.screen().cursor.clone();
                let context = graphics::GraphicsContext {
                    screen: self.is_alternate,
                    row: self.screen().rows[cursor.row].id,
                    col: cursor.col as u32,
                    cell_width: self.cell_width_px,
                    cell_height: self.cell_height_px,
                };
                let result = self.graphics.command(&packet, context, self.now);
                if let Some(reply) = result.reply {
                    self.reply(reply);
                }
                if let Some([cols, rows]) = result.advance {
                    self.open = None;
                    let max_row = self.height - 1;
                    let max_col = self.cols - 1;
                    let c = &mut self.screen_mut().cursor;
                    c.row = c.row.saturating_add(rows as usize).min(max_row);
                    c.col = c.col.saturating_add(cols as usize).min(max_col);
                    c.pending_wrap = false;
                }
            }
        }
    }
    fn print_ascii(&mut self, bytes: &[u8]) {
        // The first scalar uses the reference path, preserving possible adjacency
        // with a Unicode Prepend cluster. Subsequent ASCII pairs always break.
        self.print(bytes[0] as char);
        let mut offset = 1;
        while offset < bytes.len() {
            if self.screen().cursor.pending_wrap && self.modes.autowrap {
                self.wrap();
            }
            let row = self.screen().cursor.row;
            let col = self.screen().cursor.col;
            let right = self.write_bounds(col).1;
            let count = if self.modes.autowrap {
                (bytes.len() - offset).min(right + 1 - col)
            } else {
                (bytes.len() - offset).min(right + 1 - col).max(1)
            };
            let style = self.pen.clone();
            let link = self.link.clone();
            let flags = if self.protected { 2 } else { 0 };
            self.row_mut(row).write_ascii(
                col,
                &bytes[offset..offset + count],
                &style,
                link.as_deref(),
                flags,
            );
            self.after_placement(row, col + count - 1, 1);
            let last = String::from(bytes[offset + count - 1] as char);
            self.open = Some(OpenCluster {
                row,
                col: col + count - 1,
                text: last.clone(),
                width: 1,
                style,
                link,
                flags,
                capped: false,
                segmenter: Segmenter::new(&last),
                scalar_count: 1,
            });
            self.repeat = Some(last);
            offset += count;
        }
    }
    fn print(&mut self, mut ch: char) {
        if self.charset[self.charset_slot] {
            ch = dec_line(ch);
        }
        if let Some(mut open) = self.open.take()
            && !open.segmenter.push(ch)
        {
            if open.capped || open.scalar_count == 64 || open.text.len() + ch.len_utf8() > 1024 {
                open.capped = true;
                open.flags |= 4;
                self.row_mut(open.row).cells[open.col].flags |= 4;
            } else {
                let mut candidate = std::mem::take(&mut open.text);
                candidate.push(ch);
                open.scalar_count += 1;
                let new_width = candidate.as_str().width().clamp(1, 2);
                let right = self.write_bounds(open.col).1;
                let occupied = new_width.min(self.cols);
                if occupied > open.width && open.col + occupied > right + 1 && self.modes.autowrap {
                    let erase = open.style.erase();
                    self.row_mut(open.row)
                        .erase(open.col, open.col + open.width, &erase, false);
                    if self.write_bounds(open.col) == (0, self.cols - 1) {
                        self.row_mut(open.row).cells[open.col].kind = CellKind::WrapSpacer;
                    }
                    self.screen_mut().cursor.pending_wrap = true;
                    self.wrap();
                    self.place(
                        &candidate,
                        new_width,
                        &open.style,
                        open.link.as_deref(),
                        open.flags,
                    );
                    return;
                }
                let actual = occupied.min(right + 1 - open.col);
                let erase = open.style.erase();
                let (left, margin_right) = self.horizontal_margins();
                if actual > open.width
                    && self.modes.insert
                    && (left..=margin_right).contains(&open.col)
                {
                    self.row_mut(open.row).shift_within(
                        open.col + open.width,
                        right + 1,
                        actual - open.width,
                        true,
                        &erase,
                    );
                }
                self.row_mut(open.row).erase(
                    open.col,
                    open.col + open.width.max(actual),
                    &erase,
                    false,
                );
                self.row_mut(open.row).write(
                    open.col,
                    &candidate,
                    CellWidth {
                        occupied: actual,
                        nominal: new_width,
                    },
                    &open.style,
                    open.link.as_deref(),
                    open.flags,
                );
                open.text = candidate;
                open.width = actual;
                self.after_placement(open.row, open.col, actual);
                self.repeat = Some(open.text.clone());
            }
            self.open = Some(open);
            return;
        }
        if ch.is_control() {
            return;
        }
        let mut encoded = [0; 4];
        let text = ch.encode_utf8(&mut encoded);
        // Default-ignorables without an attachable base are consumed.
        if text.width() == 0
            && matches!(ch, '\u{200b}'..='\u{200f}'|'\u{202a}'..='\u{202e}'|'\u{2060}'..='\u{206f}'|'\u{fe00}'..='\u{fe0f}'|'\u{e0100}'..='\u{e01ef}')
        {
            return;
        }
        let width = ch.width().unwrap_or(0).clamp(1, 2);
        let style = self.pen.clone();
        let link = self.link.clone();
        self.place(
            text,
            width,
            &style,
            link.as_deref(),
            if self.protected { 2 } else { 0 },
        );
    }
    fn place(&mut self, text: &str, nominal: usize, style: &Style, link: Option<&str>, flags: u8) {
        let cursor = self.screen().cursor.clone();
        if cursor.pending_wrap && self.modes.autowrap {
            self.wrap();
        }
        let mut col = self.screen().cursor.col;
        let (left, right) = self.write_bounds(col);
        if nominal == 2 && col + 2 > right + 1 && right > left && self.modes.autowrap {
            let row = self.screen().cursor.row;
            self.row_mut(row).erase(col, col + 1, &style.erase(), false);
            if (left, right) == (0, self.cols - 1) {
                self.row_mut(row).cells[col].kind = CellKind::WrapSpacer;
            }
            self.wrap();
            col = self.screen().cursor.col;
        }
        let row = self.screen().cursor.row;
        let right = self.write_bounds(col).1;
        let width = nominal.min(right + 1 - col);
        if self.modes.insert {
            let (left, margin_right) = self.horizontal_margins();
            if (left..=margin_right).contains(&col) {
                self.row_mut(row)
                    .shift_within(col, margin_right + 1, width, true, &style.erase());
            }
        }
        self.row_mut(row)
            .erase(col, col + width, &style.erase(), false);
        self.row_mut(row).write(
            col,
            text,
            CellWidth {
                occupied: width,
                nominal,
            },
            style,
            link,
            flags,
        );
        self.after_placement(row, col, width);
        self.open = Some(OpenCluster {
            row,
            col,
            text: text.to_owned(),
            width,
            style: style.clone(),
            link: link.map(str::to_owned),
            flags,
            capped: false,
            segmenter: Segmenter::new(text),
            scalar_count: text.chars().count(),
        });
        self.repeat = Some(text.to_owned());
    }
    fn after_placement(&mut self, row: usize, col: usize, width: usize) {
        let last = self.write_bounds(col).1;
        let edge = col + width > last;
        let autowrap = self.modes.autowrap;
        let cursor = &mut self.screen_mut().cursor;
        cursor.row = row;
        cursor.col = (col + width).min(last);
        cursor.pending_wrap = edge && autowrap;
    }
    fn wrap(&mut self) {
        let old_row = self.screen().cursor.row;
        let old_id = self.screen().rows[old_row].id;
        let (left, right) = self.write_bounds(self.screen().cursor.col);
        self.index(false);
        self.screen_mut().cursor.col = left;
        self.screen_mut().cursor.pending_wrap = false;
        let new_id = self.screen().rows[self.screen().cursor.row].id;
        let link = (left == 0 && right + 1 == self.cols && old_id != new_id).then_some(new_id);
        for row in &mut self.screen_mut().rows {
            if row.id == old_id {
                Arc::make_mut(row).soft_next = link;
                return;
            }
        }
        if let Some(row) = self.history.back_mut().filter(|r| r.id == old_id) {
            Arc::make_mut(row).soft_next = link;
        }
    }
    fn index(&mut self, reverse: bool) {
        let (top, bottom) = self.screen().margins;
        let row = self.screen().cursor.row;
        let (left, right) = self.horizontal_margins();
        let inside = (left..=right).contains(&self.screen().cursor.col);
        if reverse {
            if row == top && inside {
                self.scroll(top, bottom, 1, false, false);
            } else {
                self.screen_mut().cursor.row = row.saturating_sub(1);
            }
        } else if row == bottom && inside {
            self.scroll(top, bottom, 1, true, true);
        } else {
            self.screen_mut().cursor.row = (row + 1).min(self.height - 1);
        }
    }
    fn scroll(&mut self, top: usize, bottom: usize, count: usize, up: bool, history: bool) {
        let (left, right) = self.horizontal_margins();
        if left != 0 || right + 1 != self.cols {
            self.scroll_rectangle(top, bottom, left, right, count, up);
            return;
        }
        for _ in 0..count.min(bottom - top + 1) {
            let blank = self.blank();
            let screen = self.screen_mut();
            let removed = if up {
                let r = screen.rows.remove(top);
                screen.rows.insert(bottom, blank);
                r
            } else {
                let r = screen.rows.remove(bottom);
                screen.rows.insert(top, blank);
                r
            };
            if let Some(row) = removed.as_ref()
                && !(up && history && !self.is_alternate && top == 0 && bottom == self.height - 1)
            {
                self.graphics.remove_anchor(row.id);
            }
            if up
                && history
                && !self.is_alternate
                && top == 0
                && bottom == self.height - 1
                && let Some(mut row) = removed
            {
                if self.history_limit > 0
                    && self.history_byte_limit > 0
                    && row.has_stale_resources()
                {
                    Arc::make_mut(&mut row).compact_resources();
                }
                self.history_bytes += row.accounted_bytes();
                self.history.push_back(row);
            }
        }
        self.enforce_history();
        self.repair_scroll_links(top, bottom);
    }
    pub fn enforce_history(&mut self) {
        while self.history.len() > self.history_limit
            || self.history_bytes > self.history_byte_limit
        {
            if let Some(r) = self.history.pop_front() {
                self.graphics.remove_anchor(r.id);
                self.history_bytes = self.history_bytes.saturating_sub(r.accounted_bytes());
            } else {
                break;
            }
        }
    }
    fn repair_scroll_links(&mut self, top: usize, bottom: usize) {
        let screen = self.screen_mut();
        for i in [top.saturating_sub(1), bottom.saturating_sub(1), bottom] {
            let next = screen.rows.get(i + 1).map(|r| r.id);
            if screen.rows[i].soft_next.is_some() && screen.rows[i].soft_next != next {
                Arc::make_mut(&mut screen.rows[i]).soft_next = None;
            }
        }
        let next = self.primary.rows.front().map(|r| r.id);
        if let Some(row) = self.history.back_mut()
            && row.soft_next.is_some()
            && row.soft_next != next
        {
            Arc::make_mut(row).soft_next = None;
        }
    }
    fn repair_links(&mut self) {
        // Only confirmed adjacency can remain linked after row editing.
        for screen in [&mut self.primary, &mut self.alternate] {
            for i in 0..screen.rows.len() {
                let next = screen.rows.get(i + 1).map(|r| r.id);
                if screen.rows[i].soft_next.is_some() && screen.rows[i].soft_next != next {
                    Arc::make_mut(&mut screen.rows[i]).soft_next = None;
                }
            }
        }
        let next = self.primary.rows.front().map(|r| r.id);
        if let Some(row) = self.history.back_mut()
            && row.soft_next.is_some()
            && row.soft_next != next
        {
            Arc::make_mut(row).soft_next = None;
        }
    }
    /// Snapshot owns all resolved strings/styles; no mutable actor pointers cross the ABI.
    pub fn snapshot(&self, scroll: usize) -> Option<Snapshot> {
        if self.sync_deadline.is_some() {
            return None;
        }
        let scroll = if self.is_alternate {
            0
        } else {
            scroll.min(self.history.len())
        };
        let rows = if self.is_alternate {
            self.alternate
                .rows
                .iter()
                .map(|r| RowDump::from(r.as_ref()))
                .collect()
        } else {
            self.history
                .iter()
                .chain(&self.primary.rows)
                .skip(self.history.len() - scroll)
                .take(self.height)
                .map(|r| RowDump::from(r.as_ref()))
                .collect()
        };
        let images = self.image_placements(scroll);
        Some(Snapshot {
            at_prompt: self.screen().at_prompt,
            search: self.search_highlights(scroll),
            images,
            revision: self.revision,
            geometry_epoch: self.geometry_epoch,
            document_epoch: self.document_epoch,
            history_epoch: self.history_epoch,
            screen_epoch: self.screen_epoch,
            scroll_offset: scroll,
            following_tail: scroll == 0,
            viewport_clamp_revision: self.viewport_clamp_revision,
            cols: self.cols,
            rows,
            cursor: self.screen().cursor.clone(),
            modes: self.modes.clone(),
            alternate: self.is_alternate,
            title: self.title.clone(),
            history_rows: self.history.len(),
            history: Vec::new(),
            palette: self.palette.clone(),
            default_fg: self.default_fg,
            default_bg: self.default_bg,
        })
    }
    fn image_placements(&self, scroll: usize) -> Vec<graphics::ImagePlacement> {
        if !self.graphics.has_placements() {
            return Vec::new();
        }
        let start = if self.is_alternate {
            0
        } else {
            self.history.len() - scroll
        };
        let positions = if self.is_alternate {
            self.alternate
                .rows
                .iter()
                .enumerate()
                .map(|(n, r)| (r.id, n as i64))
                .collect()
        } else {
            self.history
                .iter()
                .chain(&self.primary.rows)
                .enumerate()
                .map(|(n, r)| (r.id, n as i64 - start as i64))
                .collect()
        };
        self.graphics
            .visible(self.is_alternate, &positions, self.height)
    }
    pub(crate) fn prune_graphics(&mut self) {
        if self.graphics.has_placements() {
            let ids = self
                .history
                .iter()
                .chain(&self.primary.rows)
                .chain(&self.alternate.rows)
                .map(|r| r.id)
                .collect();
            self.graphics.prune_anchors(&ids);
        }
    }
    pub fn copy_all(&self) -> String {
        let rows: Vec<_> = if self.is_alternate {
            self.alternate.rows.iter().collect()
        } else {
            self.history.iter().chain(&self.primary.rows).collect()
        };
        let mut text = String::new();
        for (i, row) in rows.iter().enumerate() {
            text.push_str(&row.copy_text());
            if i + 1 < rows.len() && row.soft_next != Some(rows[i + 1].id) {
                text.push('\n');
            }
        }
        text
    }
    pub fn check_invariants(&self) -> bool {
        [&self.primary, &self.alternate].into_iter().all(|s| {
            s.rows.len() == self.height
                && s.cursor.row < self.height
                && s.cursor.col < self.cols
                && s.margins.0 <= s.margins.1
                && s.margins.1 < self.height
                && s.horizontal_margins.0 <= s.horizontal_margins.1
                && s.horizontal_margins.1 < self.cols
                && s.rows.iter().all(|r| {
                    r.cells.len() == self.cols
                        && r.soft_next != Some(r.id)
                        && r.cells.iter().enumerate().all(|(i, c)| match c.kind {
                            CellKind::Lead2 => r
                                .cells
                                .get(i + 1)
                                .is_some_and(|c| c.kind == CellKind::Continuation),
                            CellKind::Continuation => {
                                i > 0 && r.cells[i - 1].kind == CellKind::Lead2
                            }
                            _ => true,
                        })
                })
        })
    }
}
fn default_palette() -> Vec<[u8; 3]> {
    let mut p = vec![
        [27, 28, 31],
        [239, 68, 68],
        [34, 197, 94],
        [250, 204, 21],
        [96, 165, 250],
        [192, 132, 252],
        [34, 211, 238],
        [212, 212, 216],
        [107, 111, 118],
        [248, 113, 113],
        [74, 222, 128],
        [253, 224, 71],
        [147, 197, 253],
        [216, 180, 254],
        [103, 232, 249],
        [250, 250, 250],
    ];
    for r in [0, 95, 135, 175, 215, 255] {
        for g in [0, 95, 135, 175, 215, 255] {
            for b in [0, 95, 135, 175, 215, 255] {
                p.push([r, g, b]);
            }
        }
    }
    for n in 0..24 {
        let v = 8 + n * 10;
        p.push([v, v, v]);
    }
    p
}
fn dec_line(c: char) -> char {
    match c {
        '_' => '\u{a0}',
        '`' => '◆',
        'a' => '▒',
        'b' => '␉',
        'c' => '␌',
        'd' => '␍',
        'e' => '␊',
        'f' => '°',
        'g' => '±',
        'h' => '␤',
        'i' => '␋',
        'j' => '┘',
        'k' => '┐',
        'l' => '┌',
        'm' => '└',
        'n' => '┼',
        'o' => '⎺',
        'p' => '⎻',
        'q' => '─',
        'r' => '⎼',
        's' => '⎽',
        't' => '├',
        'u' => '┤',
        'v' => '┴',
        'w' => '┬',
        'x' => '│',
        'y' => '≤',
        'z' => '≥',
        '{' => 'π',
        '|' => '≠',
        '}' => '£',
        '~' => '·',
        _ => c,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalar_width_fast_path_matches_clamped_str_width_for_all_scalars() {
        for scalar in 0..=char::MAX as u32 {
            let Some(ch) = char::from_u32(scalar) else {
                continue;
            };
            let mut bytes = [0; 4];
            let text = ch.encode_utf8(&mut bytes);
            assert_eq!(
                ch.width().unwrap_or(0).clamp(1, 2),
                text.width().clamp(1, 2),
                "U+{scalar:04X}"
            );
        }
    }
}
