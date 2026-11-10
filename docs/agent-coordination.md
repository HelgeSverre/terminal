# Why the working rules exist

The rules in [AGENTS.md](../AGENTS.md) come from what went wrong between
2026-11-07 and 2026-11-10, when Codex and several Claude Code sessions worked
in this repository at once. This file records the incidents, found by reading
the session transcripts, the git reflog and the commit history. Times are CET.

## Incidents

| When | Who | What happened | Cost |
|---|---|---|---|
| Nov 7–9 | Codex and its subagents, mostly in the main checkout | 24 builds stopped with "was modified during the build": one session edited sources, or rewrote the shared `target/native/Spawn.o`, while another compiled | Failed and invalidated test gates, reruns |
| Nov 8, 04:01 | Two Codex agents | Per-worktree build caches filled the disk ("No space left on device") | Builds failed; 13 worktrees and 2.3 GiB had to be cleared |
| Nov 8–9 | Codex | Merging long-lived experiment worktrees into `main` conflicted in about 20 files, three times; the settings port to the SidePulse branch conflicted again | Manual resolution each time. The same files recur: `justfile`, `tools/swift-sources.json`, `Session.swift`, `Canvas.swift` |
| Nov 10, 09:20 | A Claude session | Created a perf branch with `git switch -c` in the main checkout | Every later session in that checkout started on a perf branch without knowing it |
| Nov 10, 10:27–10:37 | Two Claude sessions in the main checkout | One ran `git stash` / `git stash pop` around a build while the other ran a release build | The release build failed; a paired benchmark then ran on a stale bundle and reported PASS. It was discarded |
| Nov 10, 10:31 | Same two | One session moved its own uncommitted edits to a worktree with `git checkout --`; the other saw files change | No loss, but a false report to Helge that his changes had been discarded |
| Nov 10, 10:27–10:35 | Same two | A GUI selection smoke ran while the other session launched benchmark windows | 2 of 26 smoke runs failed on lost focus; the benchmark was probably noisy too |
| Nov 10, 10:37–11:00 | A Claude session | Committed four pane commits onto the perf branch, because that was what was checked out, and pushed it | Feature work mixed into a perf branch; half the perf work pushed; eight commits rebased later |
| Nov 10, 13:58 | A Claude session, alone | Edited sources in the worktree where its own test run was going | The run was void |
| Nov 10, 14:08 | Same session | Ran the full test suite and a ten-process fuzzer together at a load average near 10 | The machine needed a hard reset. Helge lost every terminal tab and pane |
| Nov 10, 14:08 | Same session | Its worktrees and uncommitted work were under `/private/tmp`, which the reboot erased | About an hour of work redone |
| Nov 10, 19:17–19:33 | Three Claude sessions | One created a branch in the main checkout with uncommitted edits; two then edited the same files and both ran `just test` there | Two full test runs failed. The mixed diff was separated by matching hunks on keywords |
| Nov 10, 19:20 | Three sessions | Three app instances ran at once while one session scripted keystrokes through System Events | A GUI step failed; startup timings were taken under foreign load |

## Patterns, by cost

1. **Heavy jobs run together on one machine.** One hard reset and Helge's
   whole terminal state lost.
2. **Several writers in one checkout.** Every "modified during the build"
   failure, mixed uncommitted diffs, and false alarms about discarded work.
3. **Branch operations in the shared main checkout.** HEAD moved under other
   sessions four times in one day, which is how feature commits landed on a
   perf branch.
4. **Shared build outputs.** `target/` and `dist/` are per checkout and every
   recipe reuses them, so concurrent runs corrupt each other and benchmarks
   measure a stale bundle.
5. **Work kept only uncommitted or in a temporary directory.**
6. **Long-lived branches merged late.** The same four files conflict.
7. **Branch, worktree and tag sprawl.** 64 worktrees were created in three
   days and 33 experiment tags pushed.
8. **GUI tests that need focus.** They fail, or take the keyboard, when
   another window is in front.
9. **Tracked report files rewritten by test runs.** Every checkout is
   permanently dirty, and sessions keep running `git restore` on them.
