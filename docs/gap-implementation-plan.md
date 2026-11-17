# Gap implementation plan — 2026-11-17

Authorized by Helge after the [40-entry inventory](gap-inventory.md), with
GPT-6.1 Sol implementors. Baseline `dfd25d8`. Status: implementation in progress.

## Decisions and constraints

- Preserve the inventory's explicit exclusions: clipboard writes, no multiline
  paste prompt, default grapheme clustering, remote-compatible TERM, no raw C1,
  child window manipulation, normal-quit restore or process reattachment.
- Implement the requested missing desktop features as well as compatibility
  repairs. Bell feedback is quiet and visual. Blink follows terminal requests
  and stops scheduling when irrelevant/occluded. Recovery resumes commands only
  after a click; basic recovery follows the existing recovery plan.
- Do not identify as Kitty to bypass an allowlist. Prepare and test a Helge
  Snacks integration; upstream adoption remains an external dependency.
- Preserve resource bounds. Regex search must have a bounded implementation,
  not an uninterruptible general-purpose backtracking regex on the session owner.
- Keep existing layering: engine owns terminal state, host owns ordered session
  operations, UI owns presentation, app owns preferences/persistence/policy.
- No releases, tags, installs or changes to Helge's running terminal.

## Work packages

Each package owns an isolated detached checkout. Changes to shared files are
integrated serially by the coordinator; workers do not push main. The listed
files are responsibility boundaries, not permission to edit another checkout.

| Package | Inventory | Ownership and implementation | Dependencies |
| --- | --- | --- | --- |
| Protocol discovery | C01–C04, C07, C08, U12 | Emulator query dispatch, bounded DCS query parser, terminal identity passed from host, palette/color scheme and title queries, OSC 8 logical link identity, bidi title filtering; protocol tests. Prepare truthful Snacks integration fixture/patch. | First; later engine work rebased onto this |
| VT semantics | C05 | Emulator/document cursor, margins, erase, rectangular operations, modes/save/reset; conformance regressions and explicit disposition of remaining xterm-specific failures. | Integrate after discovery |
| Input compatibility | C06, V01 | Input encoder, native key metadata, mouse encoding and negotiated modes; reproduce tmux/icat and add modifyOtherKeys/pixel mouse with meaningful tests. | Integrate after engine protocol work |
| Graphics | G01–G05, V04 | Kitty placement/reflow, indexed images, SIXEL semantics, iTerm multipart/animation/reporting, bounded transport and deterministic graphics tests. Downloads must require an explicit user save action, never arbitrary output-driven filesystem writes. | Engine protocol integration; coordinate renderer image interface |
| Presentation | U01, U02, U06 | Renderer underline geometry, request-driven blink scheduling, fractional viewport scrolling with correct selection/mouse geometry; rendered tests. | First; reserve RenderRequest integration seam |
| Native text/accessibility | U04, U05, V02, V03 | AppKit composition model/geometry and bounded AX history access, native tests and real-input validation recipe. | Integrate after presentation; physical/speech evidence stays separate |
| Recovery | U09, part V05 | Layout IDs/tree model, state location, lock/sentinel, atomic bounded checkpoints, unclean-exit restoration, scrollback and click-to-resume infrastructure per recovery plan. | App owner integrates before desktop conveniences |
| Desktop controls | U03, U10, U11, U13 | Preferences/settings, shell profiles, configurable shortcuts and Option sides, theme import/editor/cursor controls, pane focus/zoom/move, visual bell, automation parity. | Rebase onto recovery before main.swift integration |
| Search and headless | U07, E02 | Search options/worker, find controls, bounded public headless selection/search APIs; search/document tests. | Coordinate Canvas/Session and identity initializer seams |
| Shell integration | U08 | Bash/fish hooks alongside zsh, safe spawn/bundle discovery, command exit metadata and navigation; shell tests. | Rebase on protocol/desktop launch interfaces |
| Embedding/platform | E01, E03, E04, part V08 | UIKit text/input/selection/link/find/accessibility parity, robust consumer package structure, documented API policy and concurrency qualification; examples/platform checks. No version tag is implied. | Integrate public API changes after search/identity |
| Coordinator validation | V05–V09, D01 | Multi-pane/resource/renderer recovery checks, distribution/support matrix, CI timing improvements, current documentation and integration review. | All relevant code integrated before final full gates |

## Worker contract

You are not alone in the codebase. Do not revert others' edits or touch another
worker's checkout. Read AGENTS.md and the relevant source/tests before editing.
Do not spawn more agents. Use your assigned checkout only, starting with
`git worktree list` and `git status`.

No builds, test runs, benchmarks, simulators, GUI launches or package resolution
until the coordinator grants the machine's build slot. Source inspection,
primary-source protocol research, edits and `git diff --check` may run in
parallel. Disk is tight; do not copy target/dist or download large SDKs.

Prefer small cohesive commits and new focused modules over unrelated rewrites.
Message the coordinator about required shared API changes before spreading them
across targets. Preserve current tests and add behavior-level regressions where
the change needs them. No new shell/Python/Ruby test runners; use Swift tooling.

When the source patch is ready, run diff checks, checkpoint the changes on your
detached HEAD, and report commit IDs, exact tests needed, known limitations and
whether any compiler/test execution has actually happened. The coordinator will
integrate and verify before pushing main. Do not report tests as passed because
the implementation looks correct.

## Integration and verification

1. Review each package against its source and requirements; resolve shared-file
   conflicts without dropping another package's behavior.
2. Use one integration checkout/build directory and one heavy job at a time.
   Check load and disk before building; never stop processes owned by others.
3. Run focused regressions as packages land, then `just test`, esctest, embedding
   examples, relevant GPU/native checks and Gitleaks at the integrated commit.
4. Use independent spec and standards reviews against baseline `dfd25d8`.
5. Push verified steps to main, update each inventory entry with commit/evidence
   or its precise external/hardware dependency, and remove task-owned worktrees.

The under-five-minute target is tracked for both the test step and complete CI
feedback. Neither failed checks nor expensive validation are removed to hit it.
Physical keyboard, VoiceOver speech, unavailable OS/hardware and upstream
acceptance must not be claimed from unit tests.
