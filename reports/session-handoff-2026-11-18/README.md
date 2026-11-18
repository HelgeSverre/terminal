# Session handoff with real programs, 2026-11-18

Source `5b1a366`. `just build` (development bundle, ad hoc signed), executable
SHA-256 `6676d5fd2ce830a5bb5e491176d89faf5bc7346f8f48041c81e4ea6279964df9`.
macOS 15 (Darwin 24.6.0), Apple silicon. `just test` passed at the same commit.

The in-app smoke (`--handoff-smoke`, see
[session handoff](../../docs/session-handoff.md)) opened one pane per program
in a 250 by 70 cell window, typed each command into a login zsh, waited 14 s,
handed off, and checked the relaunched app.

Programs: a zsh prompt after `seq 1 3000`; a shell loop printing colored
numbered lines without pause; `htop`; `nvim` inside `tmux`; `claude`;
`codex`; `opencode`; `cmatrix`.

## Results

| Run | Relaunch | Panes | Rounds | Handoff (ms) | Result |
| --- | --- | --- | --- | --- | --- |
| A | The app relaunches itself | 8 | 3 | 82, 68, 69 | Passed every round |
| B | App exits; bundle replaced by a build numbered 23 and the old bundle deleted; 8 s wait; new bundle started | 10 (8 programs, one more tab, one more window) | 1 | 69 | Passed, adopted by build 23 |

Checked per pane and round, all true:

- the pane's shell has the same process ID and is alive, and every descendant
  process recorded before the handoff is alive;
- the grid is the same size, so no resize reached the program;
- static screens (zsh, nvim in tmux, claude, codex, opencode) are identical
  row for row one second after adoption;
- htop, cmatrix and the output loop keep changing;
- typed input arrives: `echo HANDOFF_$((6*7))` printed `HANDOFF_42`; text
  typed into nvim, claude, codex and opencode appeared in each, and
  accumulated over the rounds of run A, so each is one continuing process;
- the output loop's visible lines are consecutive and well-formed before,
  just after and 2.5 s after each handoff.

## Not covered

- A real Sparkle update. Run B does what an update does to the bundle, by hand.
- A separate window: the extra window joined the first window's tab group.
- An installed, Developer ID signed copy; macOS 14; Intel.
- Programs showing images, and panes scrolled back, at the moment of handoff.
- A gap longer than 8 s, and a keeper left unclaimed (covered by a unit test
  with a pipe, not with real programs).

## Defects this run found, fixed before `5b1a366`

- A soft-wrapped row followed by an empty row lost its line break on restore.
- Pane sizes passed through while windows were rebuilt reached adopted
  programs as resizes.
- Nested split ratios were applied against sizes not yet laid out.
