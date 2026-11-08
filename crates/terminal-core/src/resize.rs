use crate::{Error, Terminal, model::*};
use std::{collections::VecDeque, sync::Arc};
impl Terminal {
    pub fn resize_pixels(
        &mut self,
        cols: usize,
        rows: usize,
        cell_width: u32,
        cell_height: u32,
    ) -> Result<(), Error> {
        if cell_width == 0 || cell_height == 0 || cell_width > 1024 || cell_height > 1024 {
            return Err(Error::Geometry);
        }
        let old_epoch = self.geometry_epoch;
        let changed = self.cell_width_px != cell_width || self.cell_height_px != cell_height;
        self.resize(cols, rows)?;
        self.cell_width_px = cell_width;
        self.cell_height_px = cell_height;
        if changed && self.geometry_epoch == old_epoch {
            self.geometry_epoch += 1;
            self.revision += 1;
            self.open = None;
            self.sync_deadline = None;
        }
        Ok(())
    }
    /// Atomic geometry replacement. Both active and inactive screens are transformed.
    pub fn resize(&mut self, cols: usize, height: usize) -> Result<(), Error> {
        Self::validate_geometry(cols, height)?;
        if cols == self.cols && height == self.height {
            return Ok(());
        }
        self.open = None;
        self.sync_deadline = None;
        let old_height = self.height;
        let old_cols = self.cols;
        let old_start = self.history.len();
        let prompt_start = self.primary.prompt_start.and_then(|anchor| {
            self.primary
                .rows
                .iter()
                .position(|row| row.id == anchor.row)
                .map(|row| {
                    (
                        row,
                        (anchor.col + usize::from(anchor.pending_wrap)).min(old_cols),
                    )
                })
        });
        let prompt_start_source = prompt_start.map(|(row, col)| (old_start + row, col));
        if !self.is_alternate
            && cols != old_cols
            && self.primary.at_prompt
            && self.primary.prompt_redraw
            && let Some((prompt_start, prompt_col)) = prompt_start
        {
            for (index, row) in self.primary.rows.iter_mut().enumerate().skip(prompt_start) {
                let start = if index == prompt_start { prompt_col } else { 0 };
                Arc::make_mut(row).erase(start, old_cols, &Style::default(), false);
            }
        }
        let view_anchor = self.primary_view_anchor();
        let mut view_map = view_anchor;
        let current = (
            old_start + self.primary.cursor.row,
            self.primary.cursor.col,
            self.primary.cursor.pending_wrap,
        );
        let saved = (
            old_start + self.primary.saved.cursor.row,
            self.primary.saved.cursor.col,
            self.primary.saved.cursor.pending_wrap,
        );
        let source: Vec<_> = self
            .history
            .iter()
            .chain(&self.primary.rows)
            .cloned()
            .collect();
        let mut output: VecDeque<Arc<Row>> = VecDeque::new();
        let mut cursor_map = (0, 0, false);
        let mut saved_map = (0, 0, false);
        let mut start_map = 0;
        let mut prompt_start_map = None;
        if cols != old_cols {
            self.graphics.clear_screen(false);
        }
        self.cols = cols;
        self.height = height;
        if cols == old_cols {
            output.extend(source);
            cursor_map = current;
            saved_map = saved;
            start_map = old_start;
            prompt_start_map =
                prompt_start_source.map(|(row, col)| (row, col.min(cols - 1), col == cols));
        } else {
            let mut row = self.blank();
            let mut col = 0;
            for (index, old) in source.iter().enumerate() {
                if index == old_start {
                    start_map = output.len();
                }
                let mut end = old
                    .cells
                    .iter()
                    .rposition(|c| {
                        c.kind != CellKind::Empty || old.style(*c).background != Color::Default
                    })
                    .map_or(0, |n| n + 1);
                if index == current.0 {
                    end = end.max(current.1 + usize::from(current.2));
                }
                if index == saved.0 {
                    end = end.max(saved.1 + usize::from(saved.2));
                }
                if let Some((prompt_row, prompt_col)) = prompt_start_source
                    && index == prompt_row
                {
                    end = end.max(prompt_col);
                }
                let soft = source
                    .get(index + 1)
                    .is_some_and(|next| old.soft_next == Some(next.id));
                if soft {
                    end = old_cols;
                }
                for old_col in 0..=end {
                    if old_col < end
                        && matches!(
                            old.cells[old_col].kind,
                            CellKind::Continuation | CellKind::WrapSpacer
                        )
                    {
                        continue;
                    }
                    let atom = old.cells.get(old_col).copied().unwrap_or_default();
                    let nominal = if atom.kind == CellKind::Lead2 || atom.flags & 1 != 0 {
                        2
                    } else {
                        1
                    };
                    let width = nominal.min(cols);
                    if old_col < end && col + width > cols {
                        if col < cols {
                            Arc::make_mut(&mut row).cells[col].kind = CellKind::WrapSpacer;
                        }
                        let next = self.blank();
                        Arc::make_mut(&mut row).soft_next = Some(next.id);
                        output.push_back(row);
                        row = next;
                        col = 0;
                    }
                    let map = (output.len(), col.min(cols - 1), col == cols);
                    if old_col == 0 && view_anchor.is_some_and(|id| id.0 == old.id) {
                        view_map = Some(crate::viewport::RowId(row.id));
                    }
                    if (index, old_col) == (current.0, current.1 + usize::from(current.2)) {
                        cursor_map = map;
                    }
                    if (index, old_col) == (saved.0, saved.1 + usize::from(saved.2)) {
                        saved_map = map;
                    }
                    if prompt_start_source == Some((index, old_col)) {
                        prompt_start_map = Some(map);
                    }
                    if old_col == end {
                        break;
                    }
                    if atom.kind == CellKind::Empty {
                        // A meaningful blank retains its background and geometry.
                        Arc::make_mut(&mut row).erase(
                            col,
                            col + 1,
                            &old.style(atom).erase(),
                            false,
                        );
                    } else {
                        Arc::make_mut(&mut row).write(
                            col,
                            &old.text(atom),
                            CellWidth {
                                occupied: width,
                                nominal,
                            },
                            &old.style(atom),
                            old.link(atom).as_deref(),
                            atom.flags,
                        );
                    }
                    col += width;
                }
                if !soft {
                    output.push_back(row);
                    row = self.blank();
                    col = 0;
                }
            }
            if col > 0 {
                output.push_back(row);
            }
        }
        // Keep the closest old start that contains the current cursor. Height growth pulls history.
        let mut start = start_map;
        if height > old_height {
            start = start.saturating_sub(height - old_height);
        }
        if cursor_map.0 < start {
            start = cursor_map.0;
        }
        if cursor_map.0 >= start + height {
            start = cursor_map.0 + 1 - height;
        }
        self.history = output.drain(..start.min(output.len())).collect();
        for row in &mut self.history {
            if row.has_stale_resources() {
                Arc::make_mut(row).compact_resources();
            }
        }
        output.truncate(height);
        while output.len() < height {
            output.push_back(self.blank());
        }
        self.primary.rows = output;
        self.primary.cursor.row = cursor_map.0.saturating_sub(start).min(height - 1);
        self.primary.cursor.col = cursor_map.1.min(cols - 1);
        self.primary.cursor.pending_wrap = cursor_map.2;
        self.primary.saved.cursor.row = saved_map.0.saturating_sub(start).min(height - 1);
        self.primary.saved.cursor.col = saved_map.1.min(cols - 1);
        self.primary.saved.cursor.pending_wrap = saved_map.2;
        self.primary.prompt_start = prompt_start_map
            .filter(|(row, _, _)| (start..start + height).contains(row))
            .and_then(|(row, col, pending_wrap)| {
                self.primary.rows.get(row - start).map(|row| PromptAnchor {
                    row: row.id,
                    col: col.min(cols - 1),
                    pending_wrap,
                })
            });
        if self.primary.prompt_start.is_none() {
            self.primary.prompt_redraw = false;
        }
        self.primary.margins = (0, height - 1);
        self.primary.horizontal_margins = (0, cols - 1);
        while self.alternate.rows.len() < height {
            let row = self.blank();
            self.alternate.rows.push_back(row);
        }
        self.alternate.rows.truncate(height);
        for row in &mut self.alternate.rows {
            let row = Arc::make_mut(row);
            row.cells.resize(cols, Cell::default());
            if row.cells[cols - 1].kind == CellKind::Lead2 {
                row.cells[cols - 1].kind = CellKind::Lead1;
                row.cells[cols - 1].flags |= 1;
            }
            row.repair(&Style::default());
            row.soft_next = None;
            row.revision += 1;
        }
        for c in [&mut self.alternate.cursor, &mut self.alternate.saved.cursor] {
            c.row = c.row.min(height - 1);
            c.col = c.col.min(cols - 1);
            c.pending_wrap = false;
        }
        self.alternate.margins = (0, height - 1);
        self.alternate.horizontal_margins = (0, cols - 1);
        self.tabs.resize_with(cols, || false);
        if cols > old_cols && !self.tabs_cleared {
            for i in old_cols..cols {
                self.tabs[i] = i > 0 && i % 8 == 0;
            }
        }
        self.history_bytes = self.history.iter().map(|r| r.accounted_bytes()).sum();
        self.enforce_history();
        self.remap_primary_view(view_map);
        self.repair_links();
        self.prune_graphics();
        self.geometry_epoch += 1;
        self.revision += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal_retaining(change: impl FnOnce(&mut Row)) -> (Terminal, Arc<Row>) {
        let mut terminal = Terminal::new(2, 2).unwrap();
        let mut row = terminal.blank();
        change(Arc::make_mut(&mut row));
        terminal.history_bytes = row.accounted_bytes();
        terminal.history.push_back(row.clone());
        (terminal, row)
    }

    #[test]
    fn height_only_resize_preserves_compact_history_sharing_and_compacts_dirty_rows() {
        let (mut terminal, compact) = terminal_retaining(|_| {});
        let compact_bytes = compact.accounted_bytes();
        assert!(terminal.check_invariants());

        terminal.resize(2, 1).unwrap();

        assert!(Arc::ptr_eq(&compact, terminal.history.front().unwrap()));
        assert_eq!(terminal.history_bytes, compact_bytes);
        assert!(terminal.check_invariants());

        let first_style = Style {
            foreground: Color::Indexed(1),
            ..Style::default()
        };
        let second_style = Style {
            foreground: Color::Indexed(2),
            ..Style::default()
        };
        let (mut terminal, dirty) = terminal_retaining(|dirty| {
            dirty.write(
                0,
                "a\u{301}",
                CellWidth {
                    occupied: 1,
                    nominal: 1,
                },
                &first_style,
                Some("https://first.example"),
                0,
            );
            dirty.write(
                0,
                "b\u{301}",
                CellWidth {
                    occupied: 1,
                    nominal: 1,
                },
                &second_style,
                Some("https://second.example"),
                0,
            );
        });
        assert!(dirty.has_stale_resources());
        let dirty_bytes = dirty.accounted_bytes();
        let dirty_text = dirty.copy_text();
        assert!(terminal.check_invariants());

        terminal.resize(2, 1).unwrap();

        let compacted = terminal.history.front().unwrap();
        assert!(!Arc::ptr_eq(&dirty, compacted));
        assert_eq!(dirty.accounted_bytes(), dirty_bytes);
        assert_eq!(dirty.copy_text(), dirty_text);
        assert_eq!(compacted.copy_text(), dirty_text);
        assert!(compacted.accounted_bytes() < dirty_bytes);
        assert_eq!(terminal.history_bytes, compacted.accounted_bytes());
        assert!(terminal.check_invariants());
    }
}
