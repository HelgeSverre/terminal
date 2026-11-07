use serde::Serialize;
use std::collections::{BTreeMap, VecDeque};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub enum Color {
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Style {
    pub foreground: Color,
    pub background: Color,
    pub underline_color: Color,
    pub underline: u8,
    pub bold: bool,
    pub faint: bool,
    pub italic: bool,
    pub inverse: bool,
    pub conceal: bool,
    pub strike: bool,
    pub overline: bool,
    pub blink: bool,
}
impl Style {
    pub fn erase(&self) -> Self {
        Self {
            background: self.background,
            ..Self::default()
        }
    }
}
#[repr(u8)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub enum CellKind {
    #[default]
    Empty,
    Lead1,
    Lead2,
    Continuation,
    WrapSpacer,
}
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Cell {
    pub text: u32,
    pub style: u32,
    pub link: u32,
    pub kind: CellKind,
    pub flags: u8,
    pub reserved: u16,
}
const _: () = assert!(std::mem::size_of::<Cell>() == 16);
const _: () = assert!(std::mem::align_of::<Cell>() == 4);

#[derive(Debug, Clone, Copy)]
pub struct CellWidth {
    pub occupied: usize,
    pub nominal: usize,
}

#[derive(Debug, Clone)]
pub struct Row {
    pub id: u64,
    pub revision: u64,
    pub cells: Vec<Cell>,
    pub soft_next: Option<u64>,
    texts: BTreeMap<u32, String>,
    styles: BTreeMap<u32, Style>,
    links: BTreeMap<u32, String>,
}
impl Row {
    pub fn new(id: u64, cols: usize, style: &Style) -> Self {
        let mut row = Self {
            id,
            revision: 0,
            cells: vec![Cell::default(); cols],
            soft_next: None,
            texts: BTreeMap::new(),
            styles: BTreeMap::new(),
            links: BTreeMap::new(),
        };
        let sid = row.style_id(style);
        for cell in &mut row.cells {
            cell.style = sid;
        }
        row
    }
    fn vacant<T>(map: &BTreeMap<u32, T>) -> u32 {
        // Live entries are bounded by row width; reuse only absent row-local keys.
        (1..=u32::MAX).find(|id| !map.contains_key(id)).unwrap_or(0)
    }
    fn style_id(&mut self, style: &Style) -> u32 {
        if *style == Style::default() {
            return 0;
        }
        if let Some((&id, _)) = self.styles.iter().find(|(_, s)| *s == style) {
            return id;
        }
        let id = Self::vacant(&self.styles);
        self.styles.insert(id, style.clone());
        id
    }
    pub fn text(&self, cell: Cell) -> String {
        if cell.text & 0x8000_0000 != 0 {
            self.texts
                .get(&(cell.text & 0x7fff_ffff))
                .cloned()
                .unwrap_or_default()
        } else if matches!(cell.kind, CellKind::Lead1 | CellKind::Lead2) {
            char::from_u32(cell.text)
                .map(String::from)
                .unwrap_or_default()
        } else {
            String::new()
        }
    }
    pub fn style(&self, cell: Cell) -> Style {
        self.styles.get(&cell.style).cloned().unwrap_or_default()
    }
    pub fn link(&self, cell: Cell) -> Option<String> {
        self.links.get(&cell.link).cloned()
    }
    pub fn write(
        &mut self,
        col: usize,
        text: &str,
        width: CellWidth,
        style: &Style,
        link: Option<&str>,
        flags: u8,
    ) {
        let CellWidth {
            occupied: width,
            nominal,
        } = width;
        let mut chars = text.chars();
        let first = chars.next().unwrap_or(' ');
        let text = if chars.next().is_none() {
            first as u32
        } else {
            let id = Self::vacant(&self.texts);
            self.texts.insert(id, text.to_owned());
            id | 0x8000_0000
        };
        let style = self.style_id(style);
        let link = link
            .map(|s| {
                if let Some((&id, _)) = self.links.iter().find(|(_, v)| v.as_str() == s) {
                    id
                } else {
                    let id = Self::vacant(&self.links);
                    self.links.insert(id, s.to_owned());
                    id
                }
            })
            .unwrap_or(0);
        self.cells[col] = Cell {
            text,
            style,
            link,
            kind: if width == 2 {
                CellKind::Lead2
            } else {
                CellKind::Lead1
            },
            flags: (flags & !1) | u8::from(width < nominal),
            reserved: 0,
        };
        if width == 2 {
            self.cells[col + 1] = Cell {
                kind: CellKind::Continuation,
                style,
                link,
                flags,
                ..Cell::default()
            };
        }
        self.revision += 1;
        self.prune();
    }
    pub fn write_ascii(
        &mut self,
        col: usize,
        bytes: &[u8],
        style: &Style,
        link: Option<&str>,
        flags: u8,
    ) {
        self.erase(col, col + bytes.len(), &style.erase(), false);
        let sid = self.style_id(style);
        let link = link
            .map(|uri| {
                if let Some((&id, _)) = self.links.iter().find(|(_, s)| s.as_str() == uri) {
                    id
                } else {
                    let id = Self::vacant(&self.links);
                    self.links.insert(id, uri.to_owned());
                    id
                }
            })
            .unwrap_or(0);
        for (cell, &byte) in self.cells[col..col + bytes.len()].iter_mut().zip(bytes) {
            *cell = Cell {
                text: u32::from(byte),
                style: sid,
                link,
                kind: CellKind::Lead1,
                flags,
                reserved: 0,
            };
        }
        self.revision += 1;
        self.prune();
    }
    pub fn erase(&mut self, start: usize, end: usize, style: &Style, selective: bool) {
        let mut start = start.min(self.cells.len());
        let mut end = end.min(self.cells.len());
        if start < self.cells.len() && self.cells[start].kind == CellKind::Continuation {
            start = start.saturating_sub(1);
        }
        if end > 0 && self.cells[end - 1].kind == CellKind::Lead2 {
            end = (end + 1).min(self.cells.len());
        }
        let sid = self.style_id(style);
        for cell in &mut self.cells[start..end] {
            if !selective || cell.flags & 2 == 0 {
                *cell = Cell {
                    style: sid,
                    ..Cell::default()
                };
            }
        }
        self.revision += 1;
        if end == self.cells.len() {
            self.soft_next = None;
        }
        self.prune();
    }
    pub fn shift(&mut self, col: usize, count: usize, insert: bool, style: &Style) {
        self.shift_within(col, self.cells.len(), count, insert, style);
    }
    pub fn shift_within(
        &mut self,
        col: usize,
        end: usize,
        count: usize,
        insert: bool,
        style: &Style,
    ) {
        let len = end.min(self.cells.len());
        if col >= len {
            return;
        }
        let count = count.min(len - col);
        if count == 0 {
            return;
        }
        // A rectangular edge cannot retain half of a wide character outside it.
        if len < self.cells.len() && self.cells[len].kind == CellKind::Continuation {
            self.erase(len - 1, len, style, false);
        }
        // Repair the insertion/deletion boundary before moving physical cells.
        if self.cells[col].kind == CellKind::Continuation {
            self.erase(col, col + 1, style, false);
        }
        if insert {
            self.cells.copy_within(col..len - count, col + count);
            let sid = self.style_id(style);
            self.cells[col..col + count].fill(Cell {
                style: sid,
                ..Cell::default()
            });
        } else {
            if col + count < len && self.cells[col + count].kind == CellKind::Continuation {
                self.erase(col + count, col + count + 1, style, false);
            }
            self.cells.copy_within(col + count..len, col);
            let sid = self.style_id(style);
            self.cells[len - count..len].fill(Cell {
                style: sid,
                ..Cell::default()
            });
        }
        self.repair(style);
        self.soft_next = None;
        self.revision += 1;
        self.prune();
    }
    /// Copies a rectangular span while remapping all row-local resource handles.
    pub(crate) fn copy_span(&mut self, source: &Self, start: usize, end: usize, erase: &Style) {
        self.erase(start, end, erase, false);
        for col in start..end {
            let cell = source.cells[col];
            match cell.kind {
                CellKind::Lead1 | CellKind::Lead2
                    if cell.kind != CellKind::Lead2 || col + 1 < end =>
                {
                    self.write(
                        col,
                        &source.text(cell),
                        CellWidth {
                            occupied: if cell.kind == CellKind::Lead2 { 2 } else { 1 },
                            nominal: if cell.kind == CellKind::Lead2 || cell.flags & 1 != 0 {
                                2
                            } else {
                                1
                            },
                        },
                        &source.style(cell),
                        source.link(cell).as_deref(),
                        cell.flags,
                    );
                }
                CellKind::Empty | CellKind::WrapSpacer => {
                    let style = self.style_id(&source.style(cell));
                    self.cells[col] = Cell {
                        style,
                        ..Cell::default()
                    };
                }
                _ => {}
            }
        }
        self.soft_next = None;
        self.revision += 1;
        self.prune();
    }
    pub fn repair(&mut self, style: &Style) {
        let sid = self.style_id(style);
        for i in 0..self.cells.len() {
            let orphan = match self.cells[i].kind {
                CellKind::Lead2 => {
                    i + 1 == self.cells.len() || self.cells[i + 1].kind != CellKind::Continuation
                }
                CellKind::Continuation => i == 0 || self.cells[i - 1].kind != CellKind::Lead2,
                _ => false,
            };
            if orphan {
                self.cells[i] = Cell {
                    style: sid,
                    ..Cell::default()
                };
            }
        }
    }
    fn prune(&mut self) {
        self.texts
            .retain(|id, _| self.cells.iter().any(|c| c.text == (*id | 0x8000_0000)));
        self.styles
            .retain(|id, _| self.cells.iter().any(|c| c.style == *id));
        self.links
            .retain(|id, _| self.cells.iter().any(|c| c.link == *id));
    }
    pub fn copy_text(&self) -> String {
        let end = self
            .cells
            .iter()
            .rposition(|c| {
                matches!(c.kind, CellKind::Lead1 | CellKind::Lead2)
                    || self.style(*c).background != Color::Default
            })
            .map_or(0, |i| i + 1);
        self.cells[..end]
            .iter()
            .map(|&cell| match cell.kind {
                CellKind::Empty => " ".to_owned(),
                _ => self.text(cell),
            })
            .collect()
    }
    pub fn accounted_bytes(&self) -> usize {
        std::mem::size_of::<Self>()
            + self.cells.len() * 16
            + self
                .texts
                .values()
                .map(|s| s.capacity() + 48)
                .sum::<usize>()
            + self
                .links
                .values()
                .map(|s| s.capacity() + 48)
                .sum::<usize>()
            + self.styles.len() * (std::mem::size_of::<Style>() + 48)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Cursor {
    pub row: usize,
    pub col: usize,
    pub pending_wrap: bool,
    pub visible: bool,
    pub shape: u8,
}
#[derive(Debug, Clone, Default)]
pub struct Saved {
    pub cursor: Cursor,
    pub style: Style,
    pub origin: bool,
    pub charset: [bool; 2],
    pub charset_slot: usize,
}
#[derive(Debug, Clone)]
pub struct Screen {
    pub at_prompt: bool,
    pub rows: VecDeque<Arc<Row>>,
    pub cursor: Cursor,
    pub saved: Saved,
    pub margins: (usize, usize),
    pub horizontal_margins: (usize, usize),
    pub keyboard: Vec<u32>,
    pub keyboard_flags: u32,
}
impl Screen {
    pub fn new(rows: VecDeque<Arc<Row>>) -> Self {
        let bottom = rows.len() - 1;
        let right = rows
            .front()
            .map_or(0, |row| row.cells.len().saturating_sub(1));
        Self {
            at_prompt: false,
            rows,
            cursor: Cursor {
                visible: true,
                ..Cursor::default()
            },
            saved: Saved::default(),
            margins: (0, bottom),
            horizontal_margins: (0, right),
            keyboard: Vec::new(),
            keyboard_flags: 0,
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Modes {
    pub autowrap: bool,
    pub origin: bool,
    pub left_right_margins: bool,
    pub insert: bool,
    pub newline: bool,
    pub application_cursor: bool,
    pub application_keypad: bool,
    pub bracketed_paste: bool,
    pub focus: bool,
    pub mouse: u16,
    pub sgr_mouse: bool,
    pub reverse_video: bool,
}
impl Default for Modes {
    fn default() -> Self {
        Self {
            autowrap: true,
            origin: false,
            left_right_margins: false,
            insert: false,
            newline: false,
            application_cursor: false,
            application_keypad: false,
            bracketed_paste: false,
            focus: false,
            mouse: 0,
            sgr_mouse: false,
            reverse_video: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CellDump {
    pub text: String,
    pub kind: CellKind,
    pub style: Style,
    pub link: Option<String>,
    pub flags: u8,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RowDump {
    pub cells: Vec<CellDump>,
    pub soft_wrapped: bool,
}
impl From<&Row> for RowDump {
    fn from(row: &Row) -> Self {
        Self {
            cells: row
                .cells
                .iter()
                .map(|&c| CellDump {
                    text: row.text(c),
                    kind: c.kind,
                    style: row.style(c),
                    link: row.link(c),
                    flags: c.flags,
                })
                .collect(),
            soft_wrapped: row.soft_next.is_some(),
        }
    }
}
#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    pub at_prompt: bool,
    pub search: Vec<crate::search::SearchHighlight>,
    pub images: Vec<crate::graphics::ImagePlacement>,
    pub revision: u64,
    pub geometry_epoch: u64,
    pub document_epoch: u64,
    pub history_epoch: u64,
    pub screen_epoch: u64,
    pub scroll_offset: usize,
    pub following_tail: bool,
    pub viewport_clamp_revision: u64,
    pub cols: usize,
    pub rows: Vec<RowDump>,
    pub cursor: Cursor,
    pub modes: Modes,
    pub alternate: bool,
    pub title: String,
    pub history_rows: usize,
    pub history: Vec<String>,
    pub palette: Vec<[u8; 3]>,
    pub default_fg: [u8; 3],
    pub default_bg: [u8; 3],
}
