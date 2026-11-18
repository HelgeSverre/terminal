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

## Update installed by Sparkle

Source `ff65cda`, `just test` passed there; development bundle executable
SHA-256 `5a5e2b784568282a85400bcbaea019c1fd96bb9ed33ab3f28d8088b56e90d619`.
`just update-rehearsal` made an "installed" copy numbered 0.0.1 (1) and
offered 0.6.2 (22) on a loopback feed signed with a key made for the run.
Sparkle 2.10.1 in the installed copy reported: checking, found 0.6.2 (22),
downloading, extracting, ready to install, installing. The feed served
`appcast.xml` and `update.zip` once each.

| Run | Panes | Result |
| --- | --- | --- |
| Default scenario: zsh after `seq 1 500`, vim, a perl loop printing every 50 ms | 3 | Passed |
| The eight programs above, with claude, codex and opencode started in `~/code`, plus one more tab | 9 | Passed |

In both, the bundle on disk and the copy that adopted the sessions were
build 22, and every pane kept its process, descendants and grid, kept
animating where expected and received typed input.

Those copies were ad hoc signed and the update was accepted without
Sparkle's windows.

## Signed, through Sparkle's windows, and from the published feed

Source `ddd1f8a`, `just test` passed there; development bundle executable
SHA-256 `97ce98e5ba582f55892bebf377cc9d1f153c4484d0ba0e52305ff25965965796`.

| Run | What it proves | Result |
| --- | --- | --- |
| `--signed --windows`, the eight programs plus one more tab | Both copies signed with Developer ID and the hardened runtime, the update notarized (submission `6b01ea65-0560-4449-809a-4b209b408195`) and stapled; Sparkle's standard windows, with Install Update and Install and Relaunch pressed through accessibility | Passed: all 9 panes kept process, descendants and grid; Gatekeeper on the installed bundle: accepted, Notarized Developer ID |
| `--published` | A Developer ID signed copy numbered 0.0.1 with the release's feed URL and public key: Sparkle downloaded the published 0.6.2 (22), checked it with the published key and installed it | Passed: the bundle became `no.helgesverre.terminal` 0.6.2 (22); Gatekeeper: accepted, Notarized Developer ID |

Earlier the same day, before `ddd1f8a`: `--signed` alone passed once,
`--windows` alone passed 7 times and failed once. In the failure the old copy
stayed in its quit after Sparkle had handed off: it had been asked to quit a
second time and waited for an answer already given. `ddd1f8a` answers a
repeated request. What sent the second request was not found.

## Not covered

- A released version that contains handoff updating to a later one: none
  exists yet. The published 0.6.2 has no handoff, so in the `--published`
  run nothing adopted the sessions, as expected.
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
