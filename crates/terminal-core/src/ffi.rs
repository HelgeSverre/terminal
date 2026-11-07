//! ABI v1. Opaque handles are confined to one serial owner. Returned C strings are owned.
mod search;
/// # Safety
/// Handle is live/exclusive on its owner. Returns DisplayClear's native action.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_clear_display(terminal: *mut crate::Terminal) -> u32 {
    // SAFETY: caller guarantees a live exclusive non-null handle.
    unsafe { terminal.as_mut() }.map_or(0, |terminal| terminal.clear_display() as u32)
}
use crate::{
    Terminal,
    input::{Key, KeypadKey, Modifiers},
};
use std::{
    ffi::{CStr, CString, c_char},
    ptr,
};
#[unsafe(no_mangle)]
pub extern "C" fn terminal_abi_version() -> u32 {
    1
}
#[unsafe(no_mangle)]
pub extern "C" fn terminal_create(cols: u32, rows: u32) -> *mut Terminal {
    Terminal::new(cols as usize, rows as usize)
        .map(|t| Box::into_raw(Box::new(t)))
        .unwrap_or(ptr::null_mut())
}
/// # Safety
/// `terminal` must be a live handle exclusively owned by this caller, then never reused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_destroy(terminal: *mut Terminal) {
    if !terminal.is_null() {
        // SAFETY: caller transfers its unique live allocation.
        unsafe {
            drop(Box::from_raw(terminal));
        }
    }
}
/// # Safety
/// Handle is live and exclusive; bytes spans len readable bytes. All calls are serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_feed(
    terminal: *mut Terminal,
    bytes: *const u8,
    len: usize,
    now: u64,
) -> usize {
    if terminal.is_null() || bytes.is_null() {
        return 0;
    } // SAFETY: ABI caller guarantees valid lifetime, exclusivity and slice bounds.
    unsafe { (&mut *terminal).feed(std::slice::from_raw_parts(bytes, len), now) }
}
/// # Safety
/// Handle is live and exclusive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_resize(terminal: *mut Terminal, cols: u32, rows: u32) -> bool {
    if terminal.is_null() {
        return false;
    } // SAFETY: live exclusive ABI handle.
    unsafe {
        (&mut *terminal)
            .resize(cols as usize, rows as usize)
            .is_ok()
    }
}
fn string_out(bytes: Vec<u8>) -> *mut c_char {
    CString::new(bytes)
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}
/// # Safety
/// Handle is live and exclusive. Result must be released with terminal_string_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_snapshot(
    terminal: *mut Terminal,
    scroll: usize,
    now: u64,
) -> *mut c_char {
    if terminal.is_null() {
        return ptr::null_mut();
    } // SAFETY: live exclusive ABI handle.
    let t = unsafe { &mut *terminal };
    t.tick(now);
    t.snapshot(scroll)
        .and_then(|s| serde_json::to_vec(&s).ok())
        .map(string_out)
        .unwrap_or(ptr::null_mut())
}
/// # Safety
/// String was returned by this ABI and has not already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_string_free(string: *mut c_char) {
    if !string.is_null() {
        // SAFETY: caller returns the original owned CString pointer exactly once.
        unsafe {
            drop(CString::from_raw(string));
        }
    }
}
/// # Safety
/// Handle is live and exclusive. Callback receives borrowed bytes valid only during invocation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_replies(
    terminal: *mut Terminal,
    context: *mut std::ffi::c_void,
    callback: extern "C" fn(*mut std::ffi::c_void, *const u8, usize),
) {
    if terminal.is_null() {
        return;
    } // SAFETY: live exclusive ABI handle.
    for bytes in unsafe { &mut *terminal }.take_replies() {
        callback(context, bytes.as_ptr(), bytes.len());
    }
}
/// # Safety
/// Handle live and exclusive; text is a valid NUL-terminated UTF-8 C string. Callback borrows bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_input(
    terminal: *mut Terminal,
    text: *const c_char,
    key: u32,
    modifiers: u32,
    event: u32,
    context: *mut std::ffi::c_void,
    callback: extern "C" fn(*mut std::ffi::c_void, *const u8, usize),
) -> bool {
    if terminal.is_null() {
        return false;
    } // SAFETY: caller guarantees a live exclusive handle and readable C string.
    let t = unsafe { &mut *terminal };
    let text = if text.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(text) }.to_str().unwrap_or("")
    };
    let bytes = if key == 0 {
        text.as_bytes().to_vec()
    } else if key == 1 {
        match t.encode_paste(text) {
            Some(b) => b,
            None => return false,
        }
    } else if key == 2 {
        t.encode_focus(event != 0)
    } else {
        let key = match key {
            10 => Key::Up,
            11 => Key::Down,
            12 => Key::Right,
            13 => Key::Left,
            14 => Key::Home,
            15 => Key::End,
            16 => Key::PageUp,
            17 => Key::PageDown,
            18 => Key::Insert,
            19 => Key::Delete,
            20 => Key::Backspace,
            21 => Key::Tab,
            22 => Key::Enter,
            23 => Key::Escape,
            100..=111 => Key::Function((key - 99) as u8),
            300..=317 => match KeypadKey::from_index((key - 300) as usize) {
                Some(key) => Key::Keypad(key, text.chars().next()),
                None => return false,
            },
            _ => match text.chars().next() {
                Some(c) => Key::Character(c),
                None => return false,
            },
        };
        t.encode_key(
            key,
            Modifiers {
                shift: modifiers & 1 != 0,
                alt: modifiers & 2 != 0,
                control: modifiers & 4 != 0,
                super_key: modifiers & 8 != 0,
            },
            event == 1,
            event == 2,
        )
    };
    callback(context, bytes.as_ptr(), bytes.len());
    true
}
/// # Safety
/// Handle live and exclusive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_finish(terminal: *mut Terminal) {
    if !terminal.is_null() {
        // SAFETY: live exclusive ABI handle.
        unsafe { &mut *terminal }.finish();
    }
}
/// # Safety
/// Handle is live and exclusive. Diagnostic invariant check, not a mutation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_validate(terminal: *mut Terminal) -> bool {
    if terminal.is_null() {
        return false;
    }
    // SAFETY: live exclusive ABI handle.
    unsafe { &*terminal }.check_invariants()
}
/// # Safety
/// Handle is live and exclusive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_has_work(terminal: *mut Terminal) -> bool {
    if terminal.is_null() {
        return false;
    }
    // SAFETY: live exclusive ABI handle.
    unsafe { &*terminal }.has_pending_work()
}
/// # Safety
/// Handle is live and exclusive. Called as an ordered config event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_set_history_limit(terminal: *mut Terminal, rows: u32) {
    if terminal.is_null() || rows > 50_000 {
        return;
    }
    // SAFETY: live exclusive ABI handle.
    let terminal = unsafe { &mut *terminal };
    terminal.history_limit = rows as usize;
    terminal.enforce_history();
    terminal.revision += 1;
}
/// # Safety
/// Handle is live/exclusive. Callback receives borrowed RGBA bytes for this call
/// only; the full image ID and generation must match the immutable snapshot.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_image_rgba(
    terminal: *mut Terminal,
    id: u32,
    generation: u64,
    context: *mut std::ffi::c_void,
    callback: extern "C" fn(*mut std::ffi::c_void, *const u8, usize),
) -> bool {
    if terminal.is_null() {
        return false;
    }
    // SAFETY: live exclusive ABI handle; callback cannot retain this borrowed slice.
    let terminal = unsafe { &*terminal };
    let Some(image) = terminal
        .graphics
        .resources
        .get(&id)
        .filter(|i| i.generation == generation)
    else {
        return false;
    };
    callback(context, image.rgba.as_ptr(), image.rgba.len());
    true
}
/// # Safety
/// Handle is live/exclusive. Pixel metrics and cell geometry are one owner event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_resize_pixels(
    terminal: *mut Terminal,
    cols: u32,
    rows: u32,
    cell_width: u32,
    cell_height: u32,
) -> bool {
    if terminal.is_null() {
        return false;
    }
    // SAFETY: live exclusive ABI handle.
    unsafe { &mut *terminal }
        .resize_pixels(cols as usize, rows as usize, cell_width, cell_height)
        .is_ok()
}
/// # Safety
/// Handle is live/exclusive. Counts canonical retained history, not GPU memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_history_bytes(terminal: *mut Terminal) -> u64 {
    if terminal.is_null() {
        return 0;
    }
    // SAFETY: live exclusive ABI handle.
    unsafe { &*terminal }.history_bytes as u64
}

/// Borrowed cell view. Every pointer is valid only during the snapshot callback.
#[repr(C)]
#[derive(Debug)]
pub struct TerminalCellView {
    pub text: *const u8,
    pub text_len: usize,
    pub link: *const u8,
    pub link_len: usize,
    pub foreground: u32,
    pub background: u32,
    pub underline_color: u32,
    pub style_flags: u16,
    pub kind: u8,
    pub cell_flags: u8,
    pub underline: u8,
}
fn packed_color(color: crate::model::Color) -> u32 {
    use crate::model::Color;
    match color {
        Color::Default => 0,
        Color::Indexed(index) => 0x0100_0000 | u32::from(index),
        Color::Rgb(r, g, b) => 0x0200_0000 | u32::from(r) << 16 | u32::from(g) << 8 | u32::from(b),
    }
}
#[derive(serde::Serialize)]
struct SnapshotHeader<'a> {
    at_prompt: bool,
    search: &'a [crate::search::SearchHighlight],
    images: &'a [crate::graphics::ImagePlacement],
    revision: u64,
    geometry_epoch: u64,
    document_epoch: u64,
    history_epoch: u64,
    screen_epoch: u64,
    scroll_offset: usize,
    following_tail: bool,
    viewport_clamp_revision: u64,
    cols: usize,
    cursor: &'a crate::model::Cursor,
    modes: &'a crate::model::Modes,
    alternate: bool,
    title: &'a str,
    history_rows: usize,
    palette: &'a [[u8; 3]],
    default_fg: [u8; 3],
    default_bg: [u8; 3],
}
/// # Safety
/// Handle is live and exclusive. Callback must not reenter the handle. All supplied
/// views are read-only and borrowed only for the callback; copy before returning.
/// Header is length-delimited UTF-8 JSON metadata; cells are row-major, followed by
/// one soft-wrap flag per row. Indexed colors retain their symbolic identity.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_snapshot_binary(
    terminal: *mut Terminal,
    scroll: usize,
    now: u64,
    context: *mut std::ffi::c_void,
    callback: extern "C" fn(
        *mut std::ffi::c_void,
        *const u8,
        usize,
        *const TerminalCellView,
        usize,
        *const u8,
        usize,
    ),
) -> bool {
    if terminal.is_null() {
        return false;
    }
    // SAFETY: caller guarantees the live exclusive handle throughout this call.
    let terminal = unsafe { &mut *terminal };
    terminal.tick(now);
    let Some(snapshot) = terminal.snapshot(scroll) else {
        return false;
    };
    publish_snapshot(&snapshot, context, callback)
}

type SnapshotCallback = extern "C" fn(
    *mut std::ffi::c_void,
    *const u8,
    usize,
    *const TerminalCellView,
    usize,
    *const u8,
    usize,
);

/// # Safety
/// Same lifetime, exclusivity and callback contract as terminal_snapshot_binary.
/// Uses the owner-confined stable viewport instead of a numeric scroll offset.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_view_snapshot_binary(
    terminal: *mut Terminal,
    now: u64,
    context: *mut std::ffi::c_void,
    callback: SnapshotCallback,
) -> bool {
    // SAFETY: caller guarantees the live exclusive handle, when non-null.
    let Some(terminal) = (unsafe { terminal.as_mut() }) else {
        return false;
    };
    terminal.tick(now);
    terminal
        .view_snapshot()
        .is_some_and(|snapshot| publish_snapshot(&snapshot, context, callback))
}

/// # Safety
/// Handle is null or live and exclusive on its owner lane.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_view_scroll(terminal: *mut Terminal, rows: i64) {
    // SAFETY: caller guarantees exclusive ownership of a live non-null handle.
    if let Some(terminal) = unsafe { terminal.as_mut() } {
        terminal.scroll_view(rows);
    }
}

/// # Safety
/// Handle is null or live and exclusive on its owner lane.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_view_follow_tail(terminal: *mut Terminal) {
    // SAFETY: caller guarantees exclusive ownership of a live non-null handle.
    if let Some(terminal) = unsafe { terminal.as_mut() } {
        terminal.follow_tail();
    }
}

fn publish_snapshot(
    snapshot: &crate::model::Snapshot,
    context: *mut std::ffi::c_void,
    callback: SnapshotCallback,
) -> bool {
    let header = SnapshotHeader {
        at_prompt: snapshot.at_prompt,
        search: &snapshot.search,
        images: &snapshot.images,
        revision: snapshot.revision,
        geometry_epoch: snapshot.geometry_epoch,
        document_epoch: snapshot.document_epoch,
        history_epoch: snapshot.history_epoch,
        screen_epoch: snapshot.screen_epoch,
        scroll_offset: snapshot.scroll_offset,
        following_tail: snapshot.following_tail,
        viewport_clamp_revision: snapshot.viewport_clamp_revision,
        cols: snapshot.cols,
        cursor: &snapshot.cursor,
        modes: &snapshot.modes,
        alternate: snapshot.alternate,
        title: &snapshot.title,
        history_rows: snapshot.history_rows,
        palette: &snapshot.palette,
        default_fg: snapshot.default_fg,
        default_bg: snapshot.default_bg,
    };
    let Ok(metadata) = serde_json::to_vec(&header) else {
        return false;
    };
    let cells: Vec<_> = snapshot
        .rows
        .iter()
        .flat_map(|row| &row.cells)
        .map(|cell| {
            let style = &cell.style;
            let flags = [
                style.bold,
                style.faint,
                style.italic,
                style.inverse,
                style.conceal,
                style.strike,
                style.overline,
                style.blink,
            ]
            .into_iter()
            .enumerate()
            .fold(0, |bits, (n, value)| bits | u16::from(value) << n);
            let link = cell.link.as_deref().unwrap_or("");
            TerminalCellView {
                text: cell.text.as_ptr(),
                text_len: cell.text.len(),
                link: cell
                    .link
                    .as_ref()
                    .map_or(ptr::null(), |value| value.as_ptr()),
                link_len: link.len(),
                foreground: packed_color(style.foreground),
                background: packed_color(style.background),
                underline_color: packed_color(style.underline_color),
                style_flags: flags,
                kind: cell.kind as u8,
                cell_flags: cell.flags,
                underline: style.underline,
            }
        })
        .collect();
    let wraps: Vec<_> = snapshot
        .rows
        .iter()
        .map(|row| u8::from(row.soft_wrapped))
        .collect();
    callback(
        context,
        metadata.as_ptr(),
        metadata.len(),
        cells.as_ptr(),
        cells.len(),
        wraps.as_ptr(),
        wraps.len(),
    );
    true
}
