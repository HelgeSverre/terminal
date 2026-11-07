//! Owner-confined viewport identity. Row identities are compared for equality,
//! never ordered: row editing and reflow do not preserve creation order.
use crate::{Terminal, model::Snapshot};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct DocumentEpoch(u64);
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RowId(pub(crate) u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PrimaryAnchor {
    document: DocumentEpoch,
    pub(crate) row: RowId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Viewport {
    FollowTail,
    Anchored(PrimaryAnchor),
}

impl Terminal {
    /// Ordinary typing follows the selected screen. Input sent to the alternate
    /// screen must not discard the primary viewport retained for return.
    pub fn follow_tail(&mut self) {
        if !self.is_alternate {
            self.viewport = Viewport::FollowTail;
        }
    }

    /// Scroll relative to the current content anchor, not a stale host offset.
    /// Positive rows move towards older content. Alternate has no scrollback.
    pub fn scroll_view(&mut self, rows: i64) {
        if self.is_alternate || rows == 0 {
            return;
        }
        let old = self.resolve_primary_view();
        let offset = if rows > 0 {
            old.saturating_add(usize::try_from(rows).unwrap_or(usize::MAX))
                .min(self.history.len())
        } else {
            old.saturating_sub(usize::try_from(rows.unsigned_abs()).unwrap_or(usize::MAX))
        };
        self.set_view_offset(offset);
    }

    /// Explicit navigation (for example a validated search hit). An ordinary
    /// snapshot with a numeric offset remains available for replay tools.
    pub fn set_view_offset(&mut self, offset: usize) {
        let offset = offset.min(self.history.len());
        if self.is_alternate || offset == 0 {
            self.follow_tail();
        } else if let Some(row) = self.history.get(self.history.len() - offset) {
            self.viewport = Viewport::Anchored(PrimaryAnchor {
                document: DocumentEpoch(self.document_epoch),
                row: RowId(row.id),
            });
        }
    }

    pub(crate) fn primary_view_anchor(&self) -> Option<RowId> {
        match self.viewport {
            Viewport::FollowTail => None,
            Viewport::Anchored(anchor) if anchor.document == DocumentEpoch(self.document_epoch) => {
                Some(anchor.row)
            }
            Viewport::Anchored(_) => None,
        }
    }

    /// Reflow remaps the old top row's leading boundary while it already visits
    /// that row. Only the mapped row is retained, not the old transcript.
    pub(crate) fn remap_primary_view(&mut self, row: Option<RowId>) {
        if matches!(self.viewport, Viewport::Anchored(_)) {
            if let Some(row) = row {
                self.viewport = Viewport::Anchored(PrimaryAnchor {
                    document: DocumentEpoch(self.document_epoch),
                    row,
                });
            } else {
                self.clamp_primary_view();
            }
        }
    }

    fn clamp_primary_view(&mut self) {
        // Even if retention leaves no history, remain anchored until a user
        // action explicitly follows the tail. Do not select unrelated old IDs.
        if let Some(row) = self.history.front().or_else(|| self.primary.rows.front()) {
            self.viewport = Viewport::Anchored(PrimaryAnchor {
                document: DocumentEpoch(self.document_epoch),
                row: RowId(row.id),
            });
            self.viewport_clamp_revision += 1;
        }
    }

    fn resolve_primary_view(&mut self) -> usize {
        let Viewport::Anchored(anchor) = self.viewport else {
            return 0;
        };
        if anchor.document != DocumentEpoch(self.document_epoch) {
            self.viewport = Viewport::FollowTail;
            return 0;
        }
        if let Some(index) = self
            .history
            .iter()
            .chain(&self.primary.rows)
            .position(|row| row.id == anchor.row.0)
        {
            if index > self.history.len() {
                // Growing the window can pull this row below the first live
                // row. A viewport cannot start below the live grid's top.
                if let Some(row) = self.primary.rows.front() {
                    self.viewport = Viewport::Anchored(PrimaryAnchor {
                        document: DocumentEpoch(self.document_epoch),
                        row: RowId(row.id),
                    });
                    self.viewport_clamp_revision += 1;
                }
                return 0;
            }
            return self.history.len() - index;
        }
        self.clamp_primary_view();
        self.history.len()
    }

    /// Materialize the owner's current viewport. Publication gating does not
    /// discard the anchor; output remains authoritative while frames are gated.
    pub fn view_snapshot(&mut self) -> Option<Snapshot> {
        let offset = if self.is_alternate {
            0
        } else {
            self.resolve_primary_view()
        };
        let mut snapshot = self.snapshot(offset)?;
        snapshot.following_tail = self.is_alternate || self.viewport == Viewport::FollowTail;
        Some(snapshot)
    }
}
