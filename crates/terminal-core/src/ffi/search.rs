//! Search handles migrate exclusively between owner and worker. They contain no
//! terminal pointer; destruction is safe after the session has closed.
use crate::{
    Terminal,
    search::{SearchStatus, SearchTask},
};

/// # Safety
/// Terminal is live/exclusive. Query spans count readable bytes for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_search_create(
    terminal: *mut Terminal,
    query: *const u8,
    count: usize,
) -> *mut SearchTask {
    if terminal.is_null() || query.is_null() || count > 4096 {
        return std::ptr::null_mut();
    }
    // SAFETY: caller supplies a valid exclusive owner and readable query span.
    let (terminal, query) = unsafe { (&mut *terminal, std::slice::from_raw_parts(query, count)) };
    std::str::from_utf8(query)
        .ok()
        .and_then(|query| terminal.search(query).ok())
        .map_or(std::ptr::null_mut(), |task| Box::into_raw(Box::new(task)))
}
/// # Safety
/// Both handles are live/exclusive on the terminal owner. No worker call overlaps.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_search_fill(
    terminal: *mut Terminal,
    task: *mut SearchTask,
) -> u32 {
    // SAFETY: handles are live/exclusive when non-null.
    match unsafe { (terminal.as_mut(), task.as_mut()) } {
        (Some(terminal), Some(task)) => terminal.fill_search(task) as u32,
        _ => SearchStatus::Changed as u32,
    }
}
/// # Safety
/// Task is live/exclusive. It may run on a worker, with no terminal access.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_search_step(task: *mut SearchTask) -> u32 {
    // SAFETY: task is live/exclusive when non-null.
    unsafe { task.as_mut() }.map_or(SearchStatus::Changed as u32, |task| task.step() as u32)
}
/// # Safety
/// Handles are live/exclusive on the owner. Worker has finished with this task.
/// Returns 5 for an accepted hit, 2 for no hit, or a SearchStatus failure.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_search_accept(
    terminal: *mut Terminal,
    task: *mut SearchTask,
) -> u32 {
    // SAFETY: handles are live/exclusive when non-null.
    match unsafe { (terminal.as_mut(), task.as_mut()) } {
        (Some(terminal), Some(task)) => {
            let result = terminal.accept_search(task);
            if result == SearchStatus::Complete && task.found() {
                5
            } else {
                result as u32
            }
        }
        _ => SearchStatus::Changed as u32,
    }
}
/// # Safety
/// Task is a live uniquely owned allocation; no call overlaps or follows destroy.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn terminal_search_destroy(task: *mut SearchTask) {
    if !task.is_null() {
        // SAFETY: caller transfers the unique live allocation exactly once.
        unsafe {
            drop(Box::from_raw(task));
        }
    }
}
