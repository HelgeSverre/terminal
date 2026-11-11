# Measurements for 0.3.0

Measured on an Apple M2 Max, macOS 15.6, on AC power, at source `68dfb44`
(release build, executable SHA-256 `d68acb0fd206b2ac…`), with the desktop in
use and a one-minute load average of 3.6–4.9. References are Ghostty 1.4.0,
Kitty 0.45.0, iTerm2 3.7.3 and Apple Terminal. Every app comparison launches
fresh, disposable instances; differences inside the stated ranges mean nothing.

## Output throughput

MiB/s, mean of the two trial medians. `just benchmark-terminals`: ten 16 MiB
samples per workload, 100×30 cells, both launch orders, alternate screen.

| Workload | This app (MiB/s) | Ghostty (MiB/s) | Kitty (MiB/s) | This app / Ghostty | 0.2.4 (MiB/s) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Short ASCII lines | 219.1 | 280.4 | 110.5 | 78% | 99.8 |
| Long ASCII lines | 251.5 | 287.5 | 113.3 | 87% | 117.5 |
| ANSI truecolor | 200.7 | 201.4 | 79.7 | 100% | 45.1 |
| Mixed Unicode | 142.0 | 186.3 | 116.9 | 76% | 19.7 |

Trial medians for this app: 222.8/215.3, 248.6/254.3, 198.2/203.2 and
141.8/142.2. The 0.2.4 column is from that release's
[comparison](../terminal-comparison-2026-11-10/README.md), taken on battery
power on a Retina display, so it shows the scale of the change, not a paired
measurement; the paired one is in the
[direct text path report](../direct-text-path-2026-11-10/README.md). Raw
samples are in `three-app/`.

Headless emulator, MiB/s, 64 MiB per workload in 16 KiB feeds, best of three,
no PTY, window or renderer:

| Workload | Alternate screen (MiB/s) | Primary screen with scrollback (MiB/s) |
| --- | ---: | ---: |
| Short ASCII lines | 667 | 390 |
| Long ASCII lines | 999 | 509 |
| ANSI truecolor | 258 | 200 |
| Mixed Unicode | 181 | 136 |
| Unicode without clusters | 275 | 184 |
| CJK | 312 | 204 |
| Clusters only | 94 | 83 |

## Startup

Milliseconds after launch, median with the range, over 9 warm launches
(`just benchmark-startup`).

| Terminal | Window on screen (ms) | First frame presented (ms) | Child command running (ms) | First reply to the child (ms) |
| --- | ---: | ---: | ---: | ---: |
| This app | 111 (104–120) | 118 (112–125) | 86 (82–90) | 86 (82–90) |
| Ghostty | 171 (167–179) | not measured | 130 (129–136) | 131 (129–136) |
| Apple Terminal | 182 (177–191) | not measured | not measured | not measured |
| Kitty | 488 (480–555) | not measured | 461 (451–527) | 484 (471–547) |
| iTerm2 | 518 (509–540) | not measured | not measured | not measured |

The child command here is given with `--execute`, which is started with the
first window. A login shell, the normal case, is started at process launch
instead, about 75 ms earlier in this app's trace; the comparison tool does not
measure that path. This corrects the
[earlier startup report](../startup-shutdown-2026-11-10/README.md), whose
26 ms figure was for an `--execute` command at a time when those were started
early too. They no longer are, because a program started before the first
pane exists sees a PTY with no pixel size.

## Shutdown

Milliseconds after a quit request, median with the range, over 5 quits
(`just benchmark-shutdown`). Each instance runs its default shell and idles
1.5 s first.

| Terminal | Window gone (ms) | Process and Dock icon gone (ms) |
| --- | ---: | ---: |
| This app | 17 (14–47) | 18 (16–50) |
| Ghostty | 6 (5–6) | 7 (7–7) |
| Kitty | 37 (36–38) | 39 (38–41) |
| Apple Terminal | 113 (106–114) | 115 (109–116) |
| iTerm2 | did not quit within 8 s | did not quit within 8 s |

0.2.4 took about 3,030 ms to remove its process and Dock icon.

The iTerm2 row is an artefact of the first version of the tool, not of
iTerm2. iTerm2 keeps each shell in a server process that outlives the app;
earlier samples had been ended by signal, their sessions were restored into
the next instance, and iTerm2 then asked before quitting. With session
servers and the quit confirmation turned off for the disposable instance
only, a later run (`shutdown-iterm2-fixed.json`, same build, a busier
machine) gave:

| Terminal | Window gone (ms) | Process and Dock icon gone (ms) |
| --- | ---: | ---: |
| This app | 34 (24–64) | 43 (30–70) |
| Ghostty | 17 (8–19) | 34 (15–41) |
| Kitty | 55 (54–58) | 61 (58–66) |
| iTerm2 | 63 (50–76) | 81 (66–3,106) |
| Apple Terminal | 108 (107–110) | 112 (108–115) |

## Input latency under output flood

Milliseconds from submitting an input to the child receiving it, while the
child floods the PTY. Headless `Session`, 128 requests per case, two trials.

| Case | p50 (ms) | p95 (ms) | p99 (ms) |
| --- | ---: | ---: | ---: |
| Unicode flood, input | 0.41 / 0.41 | 0.61 / 0.58 | 0.69 / 0.63 |
| SQL flood, input | 0.31 / 0.31 | 0.48 / 0.47 | 0.54 / 0.51 |
| Unicode flood, resize and input | 26.0 / 26.0 | 27.1 / 27.2 | 27.9 / 27.4 |
| SQL flood, resize and input | 14.5 / 14.7 | 15.1 / 15.2 | 15.5 / 15.7 |

No case had a geometry mismatch or a rejected input.

## SQL dump with window motion

The full 8.16 GB SQL dump through `/bin/cat` on the primary screen, with
scrollback, while the window moves and resizes (`just stress-cat-motion`, one
run each; `sql-motion/`).

| Build | Wall time (s) | Peak physical footprint (MB) | Main-queue delay p95 (ms) |
| --- | ---: | ---: | ---: |
| 0.2.4 | 150.2 | 104.4 | 4.18 |
| Direct text path (`96efd66`) | 43.7 | 84.7 | 4.84 |
| This build | 38.9 | 98.1 | 4.11 |

All three runs parsed every byte, kept history within its 64 MiB limit and
exited cleanly. The peak footprint of this build is 13 MB above the previous
one; with one run each that is not explained. The earlier report gave the
first two footprints as MiB; they are megabytes of 10⁶ bytes.

## What appears on screen at startup

Milliseconds after launch, median with the range, over 9 warm launches
(`just benchmark-visible-startup`, `visible-startup.json`). The screen is
captured while each terminal starts a login zsh whose only start-up file
prints a block of marker colour, so the user's shell configuration is not
part of it. A frame's time is when it was shown; the displays refresh at
60 Hz, so each screen figure is rounded up to the next 16.7 ms.

| Terminal | Window listed (ms) | Window visible (ms) | Shell output visible (ms) |
| --- | ---: | ---: | ---: |
| This app | 119 (103–132) | 139 (125–155) | 152 (125–160) |
| Ghostty | 187 (151–205) | 209 (72–227) | 209 (175–272) |
| Kitty | 505 (489–566) | 527 (356–586) | 594 (570–686) |
| iTerm2 | 540 (518–573) | 604 (492–676) | 655 (621–704) |
| Apple Terminal | 182 (169–211) | not reliable | not seen |

Ghostty shows its window with the shell's output already in it. Three of
Kitty's nine launches and one of iTerm2's were not seen and are left out of
their screen figures. Apple Terminal's window was not detected reliably (it
is listed in one place and drawn in another), so its screen figures are
omitted.

## Key to program latency

Milliseconds from posting a key event to a terminal until a raw-mode program
on its PTY reads the byte, 100 keys per case
(`just benchmark-input-latency`, `input-latency.json`). It covers event
delivery, the terminal's key handling and its write to the PTY; keyboard
hardware and the display are not part of it. "Flood" is the same program
writing text as fast as the terminal takes it. The terminals were not in
front while measured.

| Terminal | Idle p50 (ms) | Idle p95 (ms) | Flood p50 (ms) | Flood p95 (ms) |
| --- | ---: | ---: | ---: | ---: |
| This app | 1.60 | 4.26 | 0.68 | 2.85 |
| Ghostty | 1.25 | 5.02 | 0.67 | 2.33 |
| Apple Terminal | 1.05 | 2.86 | 10.49 | 13.07 |
| iTerm2 | 1.59 | 3.61 | 62.72 | 96.74 |
| Kitty | not measured | not measured | not measured | not measured |

Kitty dropped every key posted to it in this run; in a 20-key trial its flood
figures were 5.7 and 10.5 ms. The idle figures are higher than the flood ones
for this app and Ghostty because an idle app that is not in front wakes up
more slowly than a busy one.

## Not measured

Cold start, display smoothness, input-to-photon latency, and the time to the
user's own shell prompt.

## Control sequences with a private marker

`tools/CSIProbe.swift` feeds every CSI final byte, with each private marker
and each intermediate byte, to the emulator and compares the screen, cursor,
modes and replies with a terminal that never received the sequence. It builds
like the differential fuzzer in
[`../direct-text-path-2026-11-10/tools`](../direct-text-path-2026-11-10/tools).

| Source | Marked or intermediate variants the emulator acted on |
| --- | ---: |
| `325b8a1`, before the fix | 1,733 |
| `27eac7c`, the release | 33 |

The 33 are the combinations the emulator implements: DEC private modes,
selective erase, the keyboard-flag commands, secondary device attributes,
soft reset, cursor style, character protection and the private-mode request.
