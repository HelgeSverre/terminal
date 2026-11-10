# Working in this repository

Several agents (Claude Code, Codex) and Helge work here at the same time, on
one machine. These rules exist because sessions have broken each other's
builds, moved branches under each other, mixed uncommitted work, and once took
the machine down. The incidents behind them are in
[docs/agent-coordination.md](docs/agent-coordination.md).

## Before you start

Run `git worktree list` and `git status`. Know which checkouts exist, which
branch each is on, and whether something is already uncommitted where you are
about to work. Changes you did not make belong to someone else: leave them
alone and tell Helge.

## Where to work

- **Main checkout** (`/Users/helge/code/terminal`): for small things only. A
  doc fix, a one-file change, something committed within minutes. It stays on
  `main`. Never run `git switch`, `git checkout <branch>`, `git checkout -b`,
  `git stash` or `git reset` there: every other session in that checkout moves
  with you.
- **Everything else gets its own worktree.** Anything that needs a build and
  test cycle, takes more than a few minutes, or runs beside other work:

  ```shell
  git worktree add ../terminal-<topic> -b <kind>/<topic> main
  ```

  Put worktrees beside the repository (`~/code/terminal-<topic>`). Codex's own
  `~/.codex/worktrees/` is fine too. Never under `/tmp` or `/private/tmp`: a
  reboot erases them.
- **One writer per checkout.** Do not edit, build or test in a checkout
  another session is using. Do not `stash`, `restore`, `checkout --` or
  `reset` files you did not change.

## Branches

- Name them `feat/…`, `fix/…`, `perf/…`, `docs/…` or `chore/…`.
- Branch from `main`. Branch from another unmerged branch only when the work
  depends on it, and say so in your first commit message or to Helge.
- Keep branches short-lived and merge early. `justfile`,
  `tools/swift-sources.json`, `Session.swift` and `Canvas.swift` conflict
  every time two branches sit apart for long.
- Commit each verified step as you go. Uncommitted work has no protection
  from a crash or from another session.
- Do not push experiment tags. `archive/…` branches are kept on purpose.

## Merging

- A branch merges into `main` when `just test` passes on its tip and Helge
  has agreed to the merge, or asked for it. Rebase onto `main` first and
  fast-forward, so history stays linear.
- **Merging and cleaning up are one step.** After the merge: delete the
  branch locally and on the remote, remove its worktree, and run
  `git worktree prune`. Do not leave it for later.
- **Small work may go straight to `main`** and be pushed: documentation, a
  self-contained fix with its tests passing, or anything Helge asks to have
  on `main`. If you are unsure whether it is small, it is not.
- Push a feature branch when Helge asks, or when it needs a draft pull
  request for him to test.
- Never force-push `main`. Use `--force-with-lease`, and only on a branch
  that is yours alone.
- Tags and releases happen only on request. See Release credentials below.

## Builds, tests and the machine

- `target/` and `dist/` belong to one checkout. Never run two builds or test
  runs in the same checkout, and do not edit sources there while your own
  build or test run is going: the compiler stops with "was modified during
  the build" and the run is void. To keep working during a long run, test a
  committed tip in a second worktree.
- **One heavy job at a time on the machine**, across all sessions. Heavy
  means `just test` (about 13 minutes), `just check`, a release build, a
  fuzzer, or a benchmark. Check `uptime` first and wait if the load is high.
  Run parallel shards three at a time, not ten. On 2026-11-10 the full suite
  and a ten-process fuzzer together forced a hard reset.
- **Windows and focus.** Smoke tests and benchmarks open app windows, and
  some need focus. Run one at a time, say so before you start, and use the
  app's `--background` flag for diagnostic runs. Stop only processes you
  started, by PID.
- **Helge's own terminal is off limits.** Do not rebuild, replace, signal or
  script the installed app (`~/Applications/Helge Terminal.app`) or any
  instance you did not launch. `just install` runs only when he asks.
- **Measure a frozen bundle.** Copy `dist/Terminal.app` before measuring and
  record the commit and the executable's hash. A bundle another session can
  rebuild is not a measurement target.
- Test and smoke runs write their results to ignored files under `reports/`
  (`session-tests.json`, `native-smoke.json` and the others listed in
  `.gitignore`). To keep a result as evidence, copy it into a dated
  directory under `reports/` and commit that.
- Worktrees cost disk. Remove yours when the branch is merged or abandoned;
  `just clean` removes a checkout's build outputs.

## Tooling

New developer tooling is written in Swift, as a subcommand of the compiled
tool in `tools/Dev/`, and called from a `justfile` recipe. No new Ruby,
Python or shell runners. The existing Ruby runners are being ported one at a
time.

## When you finish

Say which branch and worktree the work is on, whether it is pushed, which
tests ran and at which commit, and what is still uncommitted or unverified.

# Release credentials

For notarization or signing-credential changes, read [docs/releasing.md](docs/releasing.md).
Save credentials and recovery details in Helge's **Personal** 1Password vault
before using new or changed credentials for notarization. Verify the stored
secrets by reading them back; shared certificate backups may be referenced.
