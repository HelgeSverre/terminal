# Startup and shutdown time

> Superseded by the [0.3.0 measurements](../release-0.3.0-2026-11-11/README.md).
> The 26 ms "child command running" figure below was for an `--execute`
> command, which is no longer started before the first window; only the login
> shell is.

Measured on an Apple M2 Max, macOS 15.6, on AC power, at a one-minute load
average of 2.4–6.9 with the desktop in use. "Before" is `38b87ad`, the build
before this work; "after" is `909f15b`. References are Ghostty 1.4.0, Kitty
0.45.0, iTerm2 3.7.3 and Apple Terminal.

Both comparisons launch a fresh, disposable instance of each terminal from its
executable for every sample (`just benchmark-startup`, `just benchmark-shutdown`;
the tool is `tools/Dev`). Instances that were already open are never touched.
Run-to-run spread is in every table; differences inside it mean nothing.

## Startup

Median milliseconds after launch, with the range, over 9 warm launches (10
rounds, the first launch of each terminal excluded).

| Terminal | Window on screen (ms) | First frame presented (ms) | Child command running (ms) | First reply to the child (ms) |
| --- | ---: | ---: | ---: | ---: |
| This app, before | 139 (117–148) | not measured | 121 (99–127) | 121 (100–127) |
| This app, after | 133 (118–148) | 140 (120–148) | 26 (16–27) | 103 (84–112) |
| Ghostty | 186 (175–193) | not measured | 150 (139–159) | 150 (139–159) |
| Apple Terminal | 194 (169–215) | not measured | not measured | not measured |
| Kitty | 500 (479–507) | not measured | 474 (452–480) | 493 (471–499) |
| iTerm2 | 521 (495–539) | not measured | not measured | not measured |

The reference rows are from the run with the "after" build; the run with the
"before" build gave them 183, 183, 497 and 507 ms to a window.

- **Window on screen** is when the window server first lists a window of the
  launched process. **Child command running** is when a small C program given
  to the terminal as its command executes its first line. **First reply** is
  when that program receives the answer to a cursor-position query, which
  shows the terminal is reading and parsing.
- iTerm2 and Apple Terminal are started with the default shell, so only their
  window is timed.
- **First frame** comes from this app's `--first-frame-file` and has no
  equivalent for the others, or for the "before" build. In traced launches of
  the "before" code the first frame came 35–50 ms after the window was ordered
  in; it now comes with the window.
- Cold start (the first launch after a reboot) is not measured.

What changed:

- **The child starts at process launch.** The first window's command is
  spawned before AppKit initialises and adopted by the first session, so a
  shell's own startup overlaps the app's. The PTY starts at the size the first
  pane settled on last time. This is the 121 → 26 ms in the table; with a
  shell that takes 200 ms to reach its prompt, the prompt arrives about 95 ms
  sooner.
- **The first frame does not wait for the window server.** A new window's
  display link fires only once the window is on screen, about 30 ms after it
  is ordered in. A surface's first frame now takes its drawable from the layer
  directly, and the link is created afterwards.
- **The renderer is built beside AppKit's launch**, off the main thread.

The time to a window did not move beyond the spread (139 → 133 ms). In this
app's own trace of a warm launch, about 30 ms is AppKit initialising, 15 ms is
AppKit finishing launch, and 13 ms is creating the first window; none of that
was changed.

## Shutdown

Median milliseconds after a quit request, with the range, over 5 quits. Each
instance runs its default shell, idles 1.5 s, and is asked to quit the way
Command-Q and the Dock's Quit do.

| Terminal | Window gone (ms) | Process and Dock icon gone (ms) |
| --- | ---: | ---: |
| This app, before | 16 (13–74) | 3,028 (3,018–3,081) |
| This app, after | 37 (23–60) | 46 (37–67) |
| Ghostty | 7 (6–20) | 12 (8–35) |
| Kitty | 44 (35–63) | 50 (43–66) |
| Apple Terminal | 109 (107–110) | 112 (110–113) |
| iTerm2 | 1,468 (1,142–2,148) | 2,030 (1,473–2,156) |

The reference rows are from the run with the "after" build.

The quit handler used to close the windows and then always wait three seconds
before letting the process exit. It now exits once every pane's child has been
reaped. A child that ignores the hang-up is killed by its session after two
seconds, so a quit with such a child takes about 2,140 ms (one measured case);
its own children can outlive the app, as before.

## How it was checked

- `just test` passed on `909f15b`, and the pane-lifecycle and startup-grid
  smoke tests passed.
- The native smoke test is flaky on this machine while it is in use, on `main`
  before this work as well: interleaved runs gave 7 of 8 passes before and 8 of
  8 after. Its failures are in the phases that send keyboard shortcuts and
  cluster in time, which points at the test window losing focus. That is not
  fixed.
