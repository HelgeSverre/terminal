//! Bounded Kitty direct image transport. Images remain separate from text cells.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::Serialize;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    io::{Cursor, Read},
    sync::Arc,
};
pub const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;
pub const IMAGE_BUDGET: usize = 64 * 1024 * 1024;
const MAX_PLACEMENTS: usize = 256;
#[derive(Debug, Clone)]
pub struct ImageData {
    pub id: u32,
    pub generation: u64,
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}
#[derive(Debug, Clone)]
struct Placement {
    image: u32,
    id: u32,
    serial: u64,
    screen: bool,
    row: u64,
    col: u32,
    source: [u32; 4],
    cells: [u32; 2],
    offset: [u32; 2],
    natural: bool,
    z: i32,
}
#[derive(Debug, Clone, Serialize)]
pub struct ImagePlacement {
    pub image: u32,
    pub generation: u64,
    pub width: u32,
    pub height: u32,
    pub source: [u32; 4],
    pub row: i64,
    pub col: u32,
    pub columns: u32,
    pub rows: u32,
    pub offset: [u32; 2],
    pub natural: bool,
    pub z: i32,
    pub placement: u64,
}
#[derive(Debug, Clone, Copy)]
pub struct GraphicsContext {
    pub screen: bool,
    pub row: u64,
    pub col: u32,
    pub cell_width: u32,
    pub cell_height: u32,
}
#[derive(Debug, Clone, Default)]
struct Command {
    keys: BTreeMap<u8, String>,
}
impl Command {
    fn parse(header: &[u8]) -> Result<Self, GraphicsError> {
        if header.len() > 1024 {
            return Err(GraphicsError::TooLarge);
        }
        let mut keys = BTreeMap::new();
        for field in header.split(|b| *b == b',').filter(|f| !f.is_empty()) {
            if field.len() < 3
                || field[1] != b'='
                || !field[0].is_ascii_alphabetic()
                || field.len() > 16
                || keys.len() == 32
            {
                return Err(GraphicsError::Invalid);
            }
            let value = std::str::from_utf8(&field[2..]).map_err(|_| GraphicsError::Invalid)?;
            if keys.insert(field[0], value.to_owned()).is_some() {
                return Err(GraphicsError::Invalid);
            }
        }
        Ok(Self { keys })
    }
    fn number(&self, key: u8, default: u32) -> Result<u32, GraphicsError> {
        self.keys
            .get(&key)
            .map(|v| v.parse().map_err(|_| GraphicsError::Invalid))
            .unwrap_or(Ok(default))
    }
    fn signed(&self, key: u8, default: i32) -> Result<i32, GraphicsError> {
        self.keys
            .get(&key)
            .map(|v| v.parse().map_err(|_| GraphicsError::Invalid))
            .unwrap_or(Ok(default))
    }
    fn character(&self, key: u8, default: u8) -> Result<u8, GraphicsError> {
        match self.keys.get(&key) {
            None => Ok(default),
            Some(v) if v.len() == 1 => Ok(v.as_bytes()[0]),
            _ => Err(GraphicsError::Invalid),
        }
    }
    fn id(&self) -> u32 {
        self.number(b'i', 0).unwrap_or(0)
    }
    fn response(&self, result: Result<(), GraphicsError>) -> Option<Vec<u8>> {
        let id = self.id();
        if id == 0 {
            return None;
        }
        let quiet = self.number(b'q', 0).unwrap_or(2);
        if quiet == 2 || quiet == 1 && result.is_ok() {
            return None;
        }
        let placement = self.number(b'p', 0).unwrap_or(0);
        let suffix = if placement == 0 {
            String::new()
        } else {
            format!(",p={placement}")
        };
        Some(
            format!(
                "\x1b_Gi={id}{suffix};{}\x1b\\",
                result.map_or_else(|e| e.to_string(), |_| "OK".to_owned())
            )
            .into_bytes(),
        )
    }
}
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum GraphicsError {
    #[error("EINVAL:invalid graphics command or image data")]
    Invalid,
    #[error("ENOTSUP:unsupported graphics feature or transport")]
    Unsupported,
    #[error("E2BIG:image exceeds configured limits")]
    TooLarge,
    #[error("ENOSPC:image storage budget exhausted")]
    NoSpace,
    #[error("ENOENT:image not found")]
    NotFound,
}
#[derive(Debug)]
struct Upload {
    command: Command,
    bytes: Vec<u8>,
    started: u64,
    last_chunk: u64,
}
#[derive(Debug, Default)]
pub struct AttachmentStore {
    pub resources: HashMap<u32, Arc<ImageData>>,
    placements: Vec<Placement>,
    pending: Option<Upload>,
    serial: u64,
    total_bytes: usize,
}
#[derive(Debug, Default)]
pub struct GraphicsOutcome {
    pub reply: Option<Vec<u8>>,
    pub advance: Option<[u32; 2]>,
}
impl AttachmentStore {
    pub fn accounted_bytes(&self) -> usize {
        self.total_bytes
            + self.pending.as_ref().map_or(0, |p| p.bytes.capacity())
            + self.placements.len() * std::mem::size_of::<Placement>()
    }
    pub fn abort(&mut self) {
        self.pending = None;
    }
    pub fn tick(&mut self, now: u64) {
        if self.pending.as_ref().is_some_and(|p| {
            now.saturating_sub(p.last_chunk) > 10_000 || now.saturating_sub(p.started) > 60_000
        }) {
            self.pending = None;
        }
    }
    pub fn clear(&mut self) {
        self.resources.clear();
        self.placements.clear();
        self.pending = None;
        self.total_bytes = 0;
    }
    pub fn clear_screen(&mut self, screen: bool) {
        self.placements.retain(|p| p.screen != screen);
    }
    pub fn remove_anchor(&mut self, row: u64) {
        self.placements.retain(|p| p.row != row);
    }
    pub fn prune_anchors(&mut self, retained: &HashSet<u64>) {
        self.placements.retain(|p| retained.contains(&p.row));
    }
    pub fn has_placements(&self) -> bool {
        !self.placements.is_empty()
    }
    pub fn visible(
        &self,
        screen: bool,
        positions: &HashMap<u64, i64>,
        height: usize,
    ) -> Vec<ImagePlacement> {
        let mut out: Vec<_> = self
            .placements
            .iter()
            .filter(|p| p.screen == screen)
            .filter_map(|p| {
                let row = *positions.get(&p.row)?;
                if row >= height as i64 || row + i64::from(p.cells[1]) <= 0 {
                    return None;
                }
                let image = self.resources.get(&p.image)?;
                Some(ImagePlacement {
                    image: p.image,
                    generation: image.generation,
                    width: image.width,
                    height: image.height,
                    source: p.source,
                    row,
                    col: p.col,
                    columns: p.cells[0],
                    rows: p.cells[1],
                    offset: p.offset,
                    natural: p.natural,
                    z: p.z,
                    placement: p.serial,
                })
            })
            .collect();
        out.sort_by_key(|p| (p.z, p.image, p.placement));
        out
    }
    pub fn command(
        &mut self,
        packet: &[u8],
        context: GraphicsContext,
        now: u64,
    ) -> GraphicsOutcome {
        let Some(body) = packet.strip_prefix(b"G") else {
            return GraphicsOutcome::default();
        };
        let split = body.iter().position(|b| *b == b';').unwrap_or(body.len());
        let Ok(command) = Command::parse(&body[..split]) else {
            self.abort();
            return GraphicsOutcome::default();
        };
        let payload = if split < body.len() {
            &body[split + 1..]
        } else {
            &[]
        };
        if command.character(b'a', b't') == Ok(b'q') && command.keys.contains_key(&b'e') {
            return GraphicsOutcome {
                reply: self.feature_query(&command),
                advance: None,
            };
        }
        let more_value = command_more(&command);
        let continuation =
            self.pending.is_some() && command.keys.keys().all(|k| matches!(k, b'm' | b'q'));
        let mut upload = if continuation {
            match self.pending.take() {
                Some(mut p) => {
                    if let Some(q) = command.keys.get(&b'q') {
                        p.command.keys.insert(b'q', q.clone());
                    }
                    p
                }
                None => return GraphicsOutcome::default(),
            }
        } else {
            self.pending = None;
            match command.character(b'a', b't') {
                Ok(b'd') => {
                    let result = self.delete(&command, context);
                    return GraphicsOutcome {
                        reply: command.response(result),
                        advance: None,
                    };
                }
                Ok(b'p') => {
                    let id = command.id();
                    let result = self
                        .resources
                        .get(&id)
                        .cloned()
                        .ok_or(GraphicsError::NotFound)
                        .and_then(|image| self.place(&command, &image, context));
                    return match result {
                        Ok(advance) => GraphicsOutcome {
                            reply: command.response(Ok(())),
                            advance,
                        },
                        Err(e) => GraphicsOutcome {
                            reply: command.response(Err(e)),
                            advance: None,
                        },
                    };
                }
                Ok(b't' | b'T' | b'q') => {}
                _ => {
                    return GraphicsOutcome {
                        reply: command.response(Err(GraphicsError::Unsupported)),
                        advance: None,
                    };
                }
            }
            Upload {
                command,
                bytes: Vec::new(),
                started: now,
                last_chunk: now,
            }
        };
        let more = match more_value {
            Ok(v) => v,
            Err(e) => {
                return GraphicsOutcome {
                    reply: upload.command.response(Err(e)),
                    advance: None,
                };
            }
        };
        let result = (|| {
            validate_transport(&upload.command)?;
            if upload.command.number(b'f', 32)? != 100 {
                image_size(
                    upload.command.number(b's', 0)?,
                    upload.command.number(b'v', 0)?,
                )?;
            }
            if payload.len() > 4096 || more && payload.contains(&b'=') {
                return Err(GraphicsError::Invalid);
            }
            let bytes = STANDARD
                .decode(payload)
                .map_err(|_| GraphicsError::Invalid)?;
            if upload.bytes.len() + bytes.len() > MAX_IMAGE_BYTES {
                return Err(GraphicsError::TooLarge);
            }
            upload
                .bytes
                .try_reserve(bytes.len())
                .map_err(|_| GraphicsError::NoSpace)?;
            upload.bytes.extend_from_slice(&bytes);
            upload.last_chunk = now;
            Ok(())
        })();
        if let Err(error) = result {
            return GraphicsOutcome {
                reply: upload.command.response(Err(error)),
                advance: None,
            };
        }
        if more {
            self.pending = Some(upload);
            return GraphicsOutcome::default();
        }
        let result = self.finish_upload(&upload, context);
        match result {
            Ok(advance) => GraphicsOutcome {
                reply: upload.command.response(Ok(())),
                advance,
            },
            Err(e) => GraphicsOutcome {
                reply: upload.command.response(Err(e)),
                advance: None,
            },
        }
    }
    fn feature_query(&self, c: &Command) -> Option<Vec<u8>> {
        if c.id() == 0 || c.number(b'q', 0).ok()? != 0 {
            return None;
        }
        let action = c.character(b'e', 0).ok()?;
        if !matches!(action, b't' | b'T' | b'p' | b'd') {
            return c.response(Ok(()));
        }
        let mut keys = String::new();
        for (&key, value) in &c.keys {
            if matches!(key, b'a' | b'i' | b'I' | b'm' | b'q' | b'e') {
                continue;
            }
            let supported = match key {
                b'f' => matches!(value.as_str(), "24" | "32" | "100"),
                b't' => value == "d",
                b'o' => value == "z",
                b'C' => value == "1",
                b's' | b'v' | b'c' | b'r' | b'x' | b'y' | b'w' | b'h' | b'X' | b'Y' | b'z' => true,
                _ => false,
            };
            if supported {
                keys.push_str(&format!(",{}={value}", key as char));
            }
        }
        Some(format!("\x1b_Gi={},e={}{};OK\x1b\\", c.id(), action as char, keys).into_bytes())
    }
    fn finish_upload(
        &mut self,
        upload: &Upload,
        context: GraphicsContext,
    ) -> Result<Option<[u32; 2]>, GraphicsError> {
        let c = &upload.command;
        let (width, height, rgba) = decode_image(c, &upload.bytes)?;
        if c.character(b'a', b't')? == b'q' {
            if c.id() == 0 {
                return Err(GraphicsError::Invalid);
            }
            return Ok(None);
        }
        let mut id = c.id();
        if id == 0 {
            id = (1..=u32::MAX)
                .rev()
                .find(|id| !self.resources.contains_key(id))
                .ok_or(GraphicsError::NoSpace)?;
        }
        let generation = self.serial.checked_add(1).ok_or(GraphicsError::NoSpace)?;
        let image = Arc::new(ImageData {
            id,
            generation,
            width,
            height,
            rgba,
        });
        // Validate layout before replacing a live image. A malformed transfer is atomic.
        if c.character(b'a', b't')? == b'T' {
            let _ = placement(c, &image, context, generation)?;
        }
        let replaced = self.resources.get(&id).map_or(0, |i| i.rgba.len());
        while self.total_bytes - replaced + image.rgba.len() > IMAGE_BUDGET
            || !self.resources.contains_key(&id) && self.resources.len() >= 64
        {
            let candidate = self
                .resources
                .values()
                .filter(|i| i.id != id && !self.placements.iter().any(|p| p.image == i.id))
                .min_by_key(|i| i.generation)
                .map(|i| i.id)
                .ok_or(GraphicsError::NoSpace)?;
            if let Some(old) = self.resources.remove(&candidate) {
                self.total_bytes -= old.rgba.len();
            }
        }
        self.serial = generation;
        self.total_bytes = self.total_bytes - replaced + image.rgba.len();
        self.resources.insert(id, image.clone());
        self.placements.retain(|p| p.image != id);
        if c.character(b'a', b't')? == b'T' {
            self.place(c, &image, context)
        } else {
            Ok(None)
        }
    }
    fn place(
        &mut self,
        c: &Command,
        image: &ImageData,
        context: GraphicsContext,
    ) -> Result<Option<[u32; 2]>, GraphicsError> {
        let serial = self.serial.checked_add(1).ok_or(GraphicsError::NoSpace)?;
        let (p, advance) = placement(c, image, context, serial)?;
        if p.id != 0 {
            self.placements
                .retain(|old| old.image != p.image || old.id != p.id);
        }
        if self.placements.len() >= MAX_PLACEMENTS {
            return Err(GraphicsError::NoSpace);
        }
        self.serial = serial;
        self.placements.push(p);
        Ok(advance)
    }
    fn delete(&mut self, c: &Command, context: GraphicsContext) -> Result<(), GraphicsError> {
        let kind = c.character(b'd', b'a')?;
        let id = c.id();
        let placement = c.number(b'p', 0)?;
        let z = c.signed(b'z', 0)?;
        if !matches!(kind, b'a' | b'A' | b'i' | b'I' | b'z' | b'Z') {
            return Err(GraphicsError::Unsupported);
        }
        let mut selected = HashSet::new();
        if kind == b'I' && placement == 0 {
            selected.insert(id);
        }
        self.placements.retain(|p| {
            let remove = match kind {
                b'i' | b'I' => p.image == id && (placement == 0 || p.id == placement),
                b'z' | b'Z' => p.screen == context.screen && p.z == z,
                _ => p.screen == context.screen,
            };
            if remove {
                selected.insert(p.image);
            }
            !remove
        });
        if kind.is_ascii_uppercase() {
            let live: HashSet<_> = self.placements.iter().map(|p| p.image).collect();
            self.resources
                .retain(|&key, _| live.contains(&key) || !selected.contains(&key));
            self.total_bytes = self.resources.values().map(|i| i.rgba.len()).sum();
        }
        Ok(())
    }
}
fn command_more(c: &Command) -> Result<bool, GraphicsError> {
    match c.number(b'm', 0)? {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(GraphicsError::Invalid),
    }
}
fn validate_transport(c: &Command) -> Result<(), GraphicsError> {
    if c.keys.contains_key(&b'I')
        || c.number(b'U', 0)? != 0
        || c.number(b'P', 0)? != 0
        || c.number(b'Q', 0)? != 0
    {
        return Err(GraphicsError::Unsupported);
    }
    if c.character(b't', b'd')? != b'd' || !matches!(c.number(b'f', 32)?, 24 | 32 | 100) {
        return Err(GraphicsError::Unsupported);
    }
    if c.keys.contains_key(&b'o') && c.character(b'o', 0)? != b'z' {
        return Err(GraphicsError::Unsupported);
    }
    if c.number(b'q', 0)? > 2 {
        return Err(GraphicsError::Invalid);
    }
    Ok(())
}
fn image_size(width: u32, height: u32) -> Result<usize, GraphicsError> {
    if width == 0 || height == 0 || width > 4096 || height > 4096 {
        return Err(GraphicsError::TooLarge);
    }
    let size = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(4))
        .filter(|n| *n <= MAX_IMAGE_BYTES)
        .ok_or(GraphicsError::TooLarge)?;
    Ok(size)
}
fn decode_image(c: &Command, encoded: &[u8]) -> Result<(u32, u32, Vec<u8>), GraphicsError> {
    let inflated;
    let bytes = if c.keys.contains_key(&b'o') {
        let decoder = flate2::read::ZlibDecoder::new(encoded);
        let mut out = Vec::new();
        decoder
            .take((MAX_IMAGE_BYTES + 1) as u64)
            .read_to_end(&mut out)
            .map_err(|_| GraphicsError::Invalid)?;
        if out.len() > MAX_IMAGE_BYTES {
            return Err(GraphicsError::TooLarge);
        }
        inflated = out;
        inflated.as_slice()
    } else {
        encoded
    };
    let format = c.number(b'f', 32)?;
    if format == 100 {
        let mut decoder = png::Decoder::new_with_limits(
            Cursor::new(bytes),
            png::Limits {
                bytes: MAX_IMAGE_BYTES,
            },
        );
        decoder.set_ignore_text_chunk(true);
        decoder.set_ignore_iccp_chunk(true);
        decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
        let mut reader = decoder.read_info().map_err(|_| GraphicsError::Invalid)?;
        let width = reader.info().width;
        let height = reader.info().height;
        let size = image_size(width, height)?;
        let n = reader
            .output_buffer_size()
            .filter(|n| *n <= MAX_IMAGE_BYTES)
            .ok_or(GraphicsError::TooLarge)?;
        let mut decoded = vec![0; n];
        let info = reader
            .next_frame(&mut decoded)
            .map_err(|_| GraphicsError::Invalid)?;
        let source = &decoded[..info.buffer_size()];
        let mut rgba = Vec::with_capacity(size);
        match info.color_type {
            png::ColorType::Rgba => rgba.extend_from_slice(source),
            png::ColorType::Rgb => {
                for p in source.as_chunks::<3>().0 {
                    rgba.extend_from_slice(&[p[0], p[1], p[2], 255]);
                }
            }
            png::ColorType::Grayscale => {
                for &v in source {
                    rgba.extend_from_slice(&[v, v, v, 255]);
                }
            }
            png::ColorType::GrayscaleAlpha => {
                for p in source.as_chunks::<2>().0 {
                    rgba.extend_from_slice(&[p[0], p[0], p[0], p[1]]);
                }
            }
            _ => return Err(GraphicsError::Invalid),
        }
        if rgba.len() != size {
            return Err(GraphicsError::Invalid);
        }
        return Ok((width, height, rgba));
    }
    let width = c.number(b's', 0)?;
    let height = c.number(b'v', 0)?;
    let size = image_size(width, height)?;
    if format == 32 {
        if bytes.len() != size {
            return Err(GraphicsError::Invalid);
        }
        Ok((width, height, bytes.to_vec()))
    } else {
        if bytes.len() != size / 4 * 3 {
            return Err(GraphicsError::Invalid);
        }
        let mut rgba = Vec::with_capacity(size);
        for p in bytes.as_chunks::<3>().0 {
            rgba.extend_from_slice(&[p[0], p[1], p[2], 255]);
        }
        Ok((width, height, rgba))
    }
}
fn placement(
    c: &Command,
    image: &ImageData,
    context: GraphicsContext,
    serial: u64,
) -> Result<(Placement, Option<[u32; 2]>), GraphicsError> {
    let x = c.number(b'x', 0)?.min(image.width);
    let y = c.number(b'y', 0)?.min(image.height);
    let w = match c.number(b'w', 0)? {
        0 => image.width - x,
        value => value.min(image.width - x),
    };
    let h = match c.number(b'h', 0)? {
        0 => image.height - y,
        value => value.min(image.height - y),
    };
    let cw = context.cell_width.max(1);
    let ch = context.cell_height.max(1);
    let ox = c.number(b'X', 0)?;
    let oy = c.number(b'Y', 0)?;
    if w == 0 || h == 0 || ox >= cw || oy >= ch {
        return Err(GraphicsError::Invalid);
    }
    let mut cols = c.number(b'c', 0)?;
    let mut rows = c.number(b'r', 0)?;
    let natural = cols == 0 && rows == 0;
    if natural {
        cols = (w + ox).div_ceil(cw);
        rows = (h + oy).div_ceil(ch);
    } else if cols == 0 {
        cols = u32::try_from(
            (u64::from(rows) * u64::from(ch) * u64::from(w)).div_ceil(u64::from(h) * u64::from(cw)),
        )
        .map_err(|_| GraphicsError::TooLarge)?;
    } else if rows == 0 {
        rows = u32::try_from(
            (u64::from(cols) * u64::from(cw) * u64::from(h)).div_ceil(u64::from(w) * u64::from(ch)),
        )
        .map_err(|_| GraphicsError::TooLarge)?;
    }
    if cols == 0 || rows == 0 || cols > 4096 || rows > 4096 {
        return Err(GraphicsError::TooLarge);
    }
    let advance = match c.number(b'C', 0)? {
        0 => Some([cols, rows]),
        1 => None,
        _ => return Err(GraphicsError::Invalid),
    };
    Ok((
        Placement {
            image: image.id,
            id: c.number(b'p', 0)?,
            serial,
            screen: context.screen,
            row: context.row,
            col: context.col,
            source: [x, y, w, h],
            cells: [cols, rows],
            offset: [ox, oy],
            natural,
            z: c.signed(b'z', 0)?,
        },
        advance,
    ))
}
