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

## Where the work goes

**Commit to `main` and push.** That is the default for almost everything:
fixes, features, tests, tooling, documentation. Commit each verified step and
push it. Do not open a branch because the work "needs a build" or "might take
a while"; Helge does not want to see branches for ordinary work.

A branch is the exception. Make one only when:

- Helge asks for a branch or a pull request, or
- the work stays broken for more than a day and must be shared before it
  works.

When there is one: name it `feat/…`, `fix/…`, `perf/…`, `docs/…` or
`chore/…`, rebase onto `main` and fast-forward when it is done, then delete
it locally and on the remote in the same step. `archive/…` branches are kept
on purpose.

Before you push to `main`: the tests that cover the change pass, and
`just test` passes for anything beyond a small, self-contained change. Pull
with `git pull --rebase` first if `main` has moved. Never force-push `main`.
Tags and releases happen only on request. See Release credentials below.

## Checkouts

- **Main checkout** (`/Users/helge/code/terminal`): stays on `main`. Edit and
  commit here when the change needs no build. Never run `git switch`,
  `git checkout <branch>`, `git checkout -b`, `git stash` or `git reset`
  there: every other session in that checkout moves with you.
- **A second checkout to build and test in**, when the main checkout is in
  use or the work needs a build and test cycle. It is a scratch copy of
  `main`, not a branch:

  ```shell
  git worktree add --detach ../terminal-<topic> main
  # work, test, commit, then:
  git pull --rebase origin main && git push origin HEAD:main
  ```

  Put it beside the repository (`~/code/terminal-<topic>`). Codex's own
  `~/.codex/worktrees/` is fine too. Never under `/tmp` or `/private/tmp`: a
  reboot erases them. Remove it when the work is pushed, and run
  `git worktree prune`.
- **One writer per checkout.** Do not edit, build or test in a checkout
  another session is using. Do not `stash`, `restore`, `checkout --` or
  `reset` files you did not change.
- Commit each verified step as you go. Uncommitted work has no protection
  from a crash or from another session.

## Builds, tests and the machine

- `target/` and `dist/` belong to one checkout. Never run two builds or test
  runs in the same checkout, and do not edit sources there while your own
  build or test run is going: the compiler stops with "was modified during
  the build" and the run is void. To keep working during a long run, test a
  committed tip in a second worktree.
- **One heavy job at a time on the machine**, across all sessions. Heavy
  means `just test` (about 6 minutes from a clean checkout), `just check`,
  a release build, a fuzzer, or a benchmark. Check `uptime` first and wait
  if the load is high.
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
  (`native-smoke.json` and the others listed in
  `.gitignore`). To keep a result as evidence, copy it into a dated
  directory under `reports/` and commit that.
- Worktrees cost disk. Remove yours when the work is pushed or abandoned;
  `just clean` removes a checkout's build outputs.

## Building

`Package.swift` compiles everything: the app, its launcher, the developer
tool's tests and the test suites. `just build` runs `swift build` through
`dev bundle`, which then adds what a package cannot make: the icon, the
Metal library, the terminfo database, the bundle layout and the signature.
A new source file needs no registration; each target takes every file under
its directory.

The sources are four Swift targets, each importing the ones before it:
`TerminalEngine` (emulator and text), `TerminalHost` (PTY session),
`TerminalUI` (AppKit view and Metal renderer) and `TerminalApp` in
`Sources/Terminal` (windows, panes, settings, automation, smoke tests). Put
new code in the lowest target that can hold it; the three library targets
must not read preferences, the app delegate or `Bundle.main`. A declaration
another target needs is `package`. `public` is the interface other apps
embed, described in [docs/embedding.md](docs/embedding.md): add to it on
purpose, and keep `Examples/Embedding` building.

## Tests

Tests are Swift Testing suites, built once by `Package.swift` and run by
`just unit-test` (part of `just test`): `Tests/TerminalTests` for the app,
`Tests/DevTests` for the developer tool. Run some
with `just unit-test --filter SuiteName`. A new test goes into a suite there,
with `#expect` and `#require`; do not add test programs with their own
`main`. Tests wait with `await TestEnvironment.wait`, never by spinning the
run loop, and a suite that touches process-wide state is `.serialized`.

## Tooling

New developer tooling is written in Swift, as a subcommand of the compiled
tool in `tools/Dev/`, and called from a `justfile` recipe. No new Ruby,
Python or shell runners. The existing Ruby runners are being ported one at a
time.

## When you finish

Say which commit the work is at and whether it is pushed to `main`, which
tests ran and at which commit, and what is still uncommitted or unverified.

# Release credentials

For notarization or signing-credential changes, read [docs/releasing.md](docs/releasing.md).
Save credentials and recovery details in Helge's **Personal** 1Password vault
before using new or changed credentials for notarization. Verify the stored
secrets by reading them back; shared certificate backups may be referenced.
