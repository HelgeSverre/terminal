//! Literal history search. The owner lends one immutable row at a time; a worker
//! consumes bounded cell quanta without ever accessing the mutable terminal.
use crate::{Terminal, model::*};
use serde::Serialize;
use std::{collections::VecDeque, sync::Arc};

const MAX_QUERY_BYTES: usize = 4096;
const CELLS_PER_STEP: usize = 64;
const MAX_RETAINED_ROW_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    document: u64,
    history: u64,
    geometry: u64,
    screen: u64,
    alternate: bool,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Proof {
    row: u64,
    revision: u64,
    soft_next: Option<u64>,
}
impl From<&Row> for Proof {
    fn from(row: &Row) -> Self {
        Self {
            row: row.id,
            revision: row.revision,
            soft_next: row.soft_next,
        }
    }
}
#[derive(Debug, Clone, Copy)]
struct Span {
    proof: Proof,
    start: usize,
    end: usize,
}
#[derive(Debug, Clone)]
pub(crate) struct SearchHit {
    stamp: Stamp,
    spans: Vec<Span>,
}
#[derive(Debug)]
struct Page {
    row: Arc<Row>,
    column: usize,
    end: usize,
    hard_break: bool,
}
/// Search quanta have fixed limits; hosts do not choose budgets or interpret
/// row identities. A task alternates exclusive owner fill and worker step calls.
#[derive(Debug)]
pub struct SearchTask {
    stamp: Stamp,
    pattern: Vec<char>,
    failure: Vec<usize>,
    matched: usize,
    recent: VecDeque<Span>,
    match_end: Option<usize>,
    next: Option<u64>,
    stop: u64,
    hint: usize,
    page: Option<Page>,
    hit: Option<SearchHit>,
    status: SearchStatus,
}
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchStatus {
    Working = 0,
    NeedsPage = 1,
    Complete = 2,
    Changed = 3,
    ResourceLimit = 4,
}
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SearchError {
    #[error("search must contain 1..=4096 UTF-8 bytes")]
    Query,
}
/// Resolved decoration in a single presented viewport. End is exclusive.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SearchHighlight {
    pub row: usize,
    pub start: usize,
    pub end: usize,
}

impl Terminal {
    fn search_stamp(&self) -> Stamp {
        Stamp {
            document: self.document_epoch,
            history: self.history_epoch,
            geometry: self.geometry_epoch,
            screen: self.screen_epoch,
            alternate: self.is_alternate,
        }
    }
    fn search_row(&self, index: usize) -> Option<&Arc<Row>> {
        if self.is_alternate {
            self.alternate.rows.get(index)
        } else if index < self.history.len() {
            self.history.get(index)
        } else {
            self.primary.rows.get(index - self.history.len())
        }
    }
    fn search_row_count(&self) -> usize {
        if self.is_alternate {
            self.height
        } else {
            self.history.len() + self.height
        }
    }
    fn search_row_index(&self, id: u64, hint: usize) -> Option<usize> {
        if self.search_row(hint).is_some_and(|r| r.id == id) {
            Some(hint)
        } else {
            (0..self.search_row_count()).find(|&n| self.search_row(n).is_some_and(|r| r.id == id))
        }
    }
    /// Start a new case-insensitive literal search over the currently retained
    /// document. Unicode scalar lowercase is locale-independent. New output is
    /// not chased beyond the captured final row. No transcript is cloned.
    pub fn search(&mut self, query: &str) -> Result<SearchTask, SearchError> {
        if query.is_empty() || query.len() > MAX_QUERY_BYTES {
            return Err(SearchError::Query);
        }
        let pattern: Vec<_> = query.chars().flat_map(char::to_lowercase).collect();
        let mut failure = vec![0; pattern.len()];
        for i in 1..pattern.len() {
            let mut prefix = failure[i - 1];
            while prefix > 0 && pattern[i] != pattern[prefix] {
                prefix = failure[prefix - 1];
            }
            if pattern[i] == pattern[prefix] {
                prefix += 1;
            }
            failure[i] = prefix;
        }
        self.search_hit = None;
        Ok(SearchTask {
            stamp: self.search_stamp(),
            pattern,
            failure,
            matched: 0,
            recent: VecDeque::new(),
            match_end: None,
            next: self.search_row(0).map(|r| r.id),
            stop: self
                .search_row(self.search_row_count() - 1)
                .map_or(0, |r| r.id),
            hint: 0,
            page: None,
            hit: None,
            status: SearchStatus::NeedsPage,
        })
    }
    /// Owner-only page admission. Borrowing a row is O(1) in the usual case;
    /// movement/eviction falls back to equality lookup, never RowId ordering.
    pub fn fill_search(&self, task: &mut SearchTask) -> SearchStatus {
        if task.stamp != self.search_stamp() {
            task.status = SearchStatus::Changed;
        }
        if task.status != SearchStatus::NeedsPage {
            return task.status;
        }
        let Some(index) = task
            .next
            .and_then(|id| self.search_row_index(id, task.hint))
        else {
            task.status = SearchStatus::Changed;
            return task.status;
        };
        let Some(row) = self.search_row(index) else {
            return SearchStatus::Changed;
        };
        if row.accounted_bytes() > MAX_RETAINED_ROW_BYTES {
            task.status = SearchStatus::ResourceLimit;
            return task.status;
        }
        let next = if row.id == task.stop {
            None
        } else {
            self.search_row(index + 1).map(|r| r.id)
        };
        if next.is_none() && row.id != task.stop {
            task.status = SearchStatus::Changed;
            return task.status;
        }
        let soft = next.is_some_and(|id| row.soft_next == Some(id));
        let end = if soft {
            row.cells.len()
        } else {
            row.cells
                .iter()
                .rposition(|c| {
                    matches!(c.kind, CellKind::Lead1 | CellKind::Lead2)
                        || row.style(*c).background != Color::Default
                })
                .map_or(0, |n| n + 1)
        };
        task.page = Some(Page {
            row: Arc::clone(row),
            column: 0,
            end,
            hard_break: !soft && next.is_some(),
        });
        task.next = next;
        task.hint = index + 1;
        task.status = SearchStatus::Working;
        task.status
    }
    fn resolve_search_hit(&self, hit: &SearchHit) -> Option<usize> {
        if hit.stamp != self.search_stamp() {
            return None;
        }
        let first = hit.spans.first()?;
        let index = self.search_row_index(first.proof.row, 0)?;
        for (offset, span) in hit.spans.iter().enumerate() {
            let row = self.search_row(index + offset)?;
            if Proof::from(row.as_ref()) != span.proof {
                return None;
            }
        }
        Some(index)
    }
    /// Accept only unchanged source rows and current epochs, then navigate by
    /// identity on the owner. A stale result never scrolls to unrelated text.
    pub fn accept_search(&mut self, task: &SearchTask) -> SearchStatus {
        if task.stamp != self.search_stamp() {
            return SearchStatus::Changed;
        }
        if task.status != SearchStatus::Complete {
            return task.status;
        }
        let Some(hit) = &task.hit else {
            return SearchStatus::Complete;
        };
        let Some(index) = self.resolve_search_hit(hit) else {
            return SearchStatus::Changed;
        };
        if !self.is_alternate {
            self.set_view_offset(self.history.len().saturating_sub(index));
        }
        self.search_hit = Some(hit.clone());
        SearchStatus::Complete
    }
    pub(crate) fn search_highlights(&self, scroll: usize) -> Vec<SearchHighlight> {
        let Some(hit) = self.search_hit.as_ref() else {
            return Vec::new();
        };
        let Some(index) = self.resolve_search_hit(hit) else {
            return Vec::new();
        };
        let top = if self.is_alternate {
            0
        } else {
            self.history.len() - scroll
        };
        hit.spans
            .iter()
            .enumerate()
            .filter_map(|(n, span)| {
                let row = (index + n).checked_sub(top)?;
                (row < self.height && span.start < span.end).then_some(SearchHighlight {
                    row,
                    start: span.start,
                    end: span.end,
                })
            })
            .collect()
    }
}
impl SearchTask {
    pub fn found(&self) -> bool {
        self.hit.is_some()
    }
    fn push(&mut self, ch: char, span: Span) {
        for ch in ch.to_lowercase() {
            self.recent.push_back(span);
            while self.matched > 0 && ch != self.pattern[self.matched] {
                self.matched = self.failure[self.matched - 1];
            }
            if ch == self.pattern[self.matched] {
                self.matched += 1;
            }
            if self.matched == self.pattern.len() {
                self.match_end = Some(self.recent.len());
                self.matched = self.failure[self.matched - 1];
            }
        }
    }
    /// Worker-only bounded quantum. No terminal pointer or mutable row crosses
    /// this seam. Calling again after a terminal result has no semantic effect.
    pub fn step(&mut self) -> SearchStatus {
        if self.status != SearchStatus::Working {
            return self.status;
        }
        let Some(mut page) = self.page.take() else {
            self.status = SearchStatus::NeedsPage;
            return self.status;
        };
        self.match_end = None;
        let proof = Proof::from(page.row.as_ref());
        let stop = page.column.saturating_add(CELLS_PER_STEP).min(page.end);
        while page.column < stop {
            let col = page.column;
            let cell = page.row.cells[col];
            page.column += 1;
            let span = Span {
                proof,
                start: col,
                end: col + if cell.kind == CellKind::Lead2 { 2 } else { 1 },
            };
            match cell.kind {
                CellKind::Lead1 | CellKind::Lead2 => {
                    for ch in page.row.text(cell).chars() {
                        self.push(ch, span);
                    }
                }
                CellKind::Empty => self.push(' ', span),
                CellKind::Continuation | CellKind::WrapSpacer => {}
            }
        }
        if page.column == page.end {
            if page.hard_break {
                self.push(
                    '\n',
                    Span {
                        proof,
                        start: page.end,
                        end: page.end,
                    },
                );
            }
            self.status = if self.next.is_some() {
                SearchStatus::NeedsPage
            } else {
                SearchStatus::Complete
            };
        } else {
            self.page = Some(page);
        }
        // Record only the last match per quantum. Materializing every overlap
        // would turn a repetitive query into O(input * query) work.
        if let Some(end) = self.match_end {
            let mut spans: Vec<Span> = Vec::new();
            for part in self.recent.range(end - self.pattern.len()..end) {
                if let Some(last) = spans.last_mut().filter(|s| s.proof == part.proof) {
                    last.start = last.start.min(part.start);
                    last.end = last.end.max(part.end);
                } else {
                    spans.push(*part);
                }
            }
            self.hit = Some(SearchHit {
                stamp: self.stamp,
                spans,
            });
        }
        let discard = self.recent.len().saturating_sub(self.pattern.len());
        self.recent.drain(..discard);
        self.status
    }
}
