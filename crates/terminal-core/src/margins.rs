use crate::Terminal;
use std::sync::Arc;

impl Terminal {
    pub(super) fn horizontal_margins(&self) -> (usize, usize) {
        if self.modes.left_right_margins {
            self.screen().horizontal_margins
        } else {
            (0, self.cols - 1)
        }
    }
    pub(super) fn write_bounds(&self, column: usize) -> (usize, usize) {
        let (left, right) = self.horizontal_margins();
        if column <= right {
            (left, right)
        } else {
            (0, self.cols - 1)
        }
    }
    pub(super) fn carriage_return(&mut self) {
        let (left, _) = self.horizontal_margins();
        let column = self.screen().cursor.col;
        let cursor = &mut self.screen_mut().cursor;
        cursor.col = if column >= left { left } else { 0 };
        cursor.pending_wrap = false;
    }
    pub(super) fn scroll_rectangle(
        &mut self,
        top: usize,
        bottom: usize,
        left: usize,
        right: usize,
        count: usize,
        up: bool,
    ) {
        let height = bottom - top + 1;
        let count = count.min(height);
        if count == 0 {
            return;
        }
        let erase = self.pen.erase();
        // Source rows are visited before they can be overwritten. Their Arc keeps
        // resource maps immutable while destination handles are remapped.
        for step in 0..height {
            let row = if up { top + step } else { bottom - step };
            let source = if up {
                row.checked_add(count).filter(|&r| r <= bottom)
            } else {
                row.checked_sub(count).filter(|&r| r >= top)
            };
            if let Some(source) = source {
                let source = self.screen().rows[source].clone();
                self.row_mut(row)
                    .copy_span(&source, left, right + 1, &erase);
            } else {
                self.row_mut(row).erase(left, right + 1, &erase, false);
                self.row_mut(row).soft_next = None;
            }
        }
        if top > 0 {
            self.row_mut(top - 1).soft_next = None;
        } else if !self.is_alternate
            && let Some(row) = self.history.back_mut()
        {
            Arc::make_mut(row).soft_next = None;
        }
        // Partial-width image scrolling needs independent placement clipping;
        // conservatively clear placements rather than attach them to wrong text.
        self.graphics.clear_screen(self.is_alternate);
    }
}
