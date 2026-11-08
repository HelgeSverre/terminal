//! Native clear action, distinct from a child-issued erase or terminal reset.
use crate::{Terminal, model::PromptAnchor, viewport::Viewport};

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayClear {
    IgnoredAlternate = 0,
    Cleared = 1,
    RedrawPrompt = 2,
}
impl Terminal {
    /// Clear primary history and return to its live view. At a marked shell
    /// prompt, clear the grid and request a shell redraw. Otherwise remove only
    /// rows above the cursor, preserving the running program's current content.
    pub fn clear_display(&mut self) -> DisplayClear {
        if self.is_alternate {
            return DisplayClear::IgnoredAlternate;
        }
        self.open = None;
        self.sync_deadline = None;
        self.history.clear();
        self.history_bytes = 0;
        self.history_epoch += 1;
        self.screen_epoch += 1;
        self.search_hit = None;
        self.viewport = Viewport::FollowTail;
        self.graphics.clear_from_host(false);
        let prompt = self.primary.prompt_phase.at_prompt();
        if prompt {
            for index in 0..self.height {
                let row = self.blank();
                self.primary.rows[index] = row;
            }
            // The fresh grid has new row identities. Keep the prompt anchor on
            // its first row so a later width resize can still clear this
            // redrawable prompt before ZLE repaints it.
            self.primary.prompt_start = self.primary.rows.front().map(|row| PromptAnchor {
                row: row.id,
                col: 0,
                pending_wrap: false,
            });
            self.primary.cursor.row = 0;
            self.primary.cursor.col = 0;
            self.primary.cursor.pending_wrap = false;
        } else {
            let above = self.primary.cursor.row;
            self.primary.rows.drain(..above);
            for _ in 0..above {
                let row = self.blank();
                self.primary.rows.push_back(row);
            }
            self.primary.cursor.row = 0;
        }
        // Appearance, modes, keyboard stack and margins survive this action.
        self.repair_links();
        self.revision += 1;
        if prompt {
            DisplayClear::RedrawPrompt
        } else {
            DisplayClear::Cleared
        }
    }
}
