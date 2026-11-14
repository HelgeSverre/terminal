# PTY throughput: Terminal and SwiftTerm as embedded libraries

Measured on 2026-11-14 with two minimal hosts, each one window holding one
terminal view that runs the PTY driver and exits:
[`Benchmarks/EmbeddedHosts`](../../Benchmarks/EmbeddedHosts). This is what an
embedding app gets from each package, not what the Terminal app does: the app
is built differently (see below).

| | Terminal | SwiftTerm |
| --- | --- | --- |
| Version | `7a396ab`, through the `TerminalView` product | `v1.99.3` (`282c3c3a`), the newest release |
| Build | `swift build -c release` | `swift build -c release`, with one line patched |
| Renderer | Metal | Core Graphics (its default), and Metal with `--metal` |
| Font | Obel Mono 14 pt | Menlo 14 pt |
| Host SHA-256 | `ccc2c1cc039a5090aa0bd8f15960f9f5fa65b946c1e0c9f2a13fe33938d77be6` | `494c2b13b466ae67bdeee1e5ee0bb9fd1f39314150d8bfa55bddf12ec391f645` |

SwiftTerm does not compile with Swift 6.2.4 as released or at `d4f52fa` on its
`main`: `Sources/SwiftTerm/Apple/PowerlineRenderer.swift:387` fails to
type-check. The measured build has `flameLowerPath.dropFirst()` wrapped in
`Array(...)` there and nothing else changed. To repeat it:
`swift package edit SwiftTerm` in `Benchmarks/EmbeddedHosts`, make that edit
in `Packages/SwiftTerm`, then build.

## Method

The driver is `Benchmarks/TerminalBench/terminal-bench.c`, the one the
project's other comparisons use. It writes each workload to its terminal on
the alternate screen and waits for an ordered device status reply, so it
measures reading and parsing under backpressure, not drawing or key latency.
Each pass is 16 MiB per workload and 10 runs per workload on a 100 × 30 grid.
Five passes ran: a and b in opposite orders, then c, d and e interleaved.

The machine was in use throughout: load averages were between 5.5 and 7.7,
with a fuzzer from another project on one core. Single passes dropped to a
fifth of the best for both libraries (pass a for Terminal, pass c for
SwiftTerm with Metal), so the table of every pass is the result and the best
pass is the nearest thing to an undisturbed figure.

## Results

Best pass, as the median of its 10 runs, in MiB/s. The ratio is Terminal over
the faster SwiftTerm renderer.

| Workload | Terminal | SwiftTerm, Core Graphics | SwiftTerm, Metal | Ratio |
| --- | --- | --- | --- | --- |
| ascii_short_lines | 255 | 251 | 266 | 0.96 |
| ascii_long_lines | 287 | 293 | 303 | 0.95 |
| ansi_truecolor | 131 | 212 | 204 | 0.62 |
| unicode | 107 | 32 | 31 | 3.31 |

Every pass, as the median of its 10 runs, in MiB/s:

| Host | Workload | Pass a | Pass b | Pass c | Pass d | Pass e | Best | Median |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Terminal | ascii_short_lines | 45 | 255 | 193 | 137 | 92 | 255 | 137 |
| Terminal | ascii_long_lines | 41 | 287 | 205 | 154 | 67 | 287 | 154 |
| Terminal | ansi_truecolor | 43 | 131 | 122 | 111 | 66 | 131 | 111 |
| Terminal | unicode | 89 | 107 | 103 | 98 | 68 | 107 | 98 |
| SwiftTerm, Core Graphics | ascii_short_lines | 198 | 251 | 165 | 163 | 163 | 251 | 165 |
| SwiftTerm, Core Graphics | ascii_long_lines | 192 | 291 | 194 | 172 | 293 | 293 | 194 |
| SwiftTerm, Core Graphics | ansi_truecolor | 174 | 201 | 141 | 127 | 212 | 212 | 174 |
| SwiftTerm, Core Graphics | unicode | 31 | 32 | 26 | 30 | 32 | 32 | 31 |
| SwiftTerm, Metal | ascii_short_lines | 208 | 217 | 34 | 173 | 266 | 266 | 208 |
| SwiftTerm, Metal | ascii_long_lines | 229 | 248 | 69 | 190 | 303 | 303 | 229 |
| SwiftTerm, Metal | ansi_truecolor | 165 | 179 | 64 | 140 | 204 | 204 | 165 |
| SwiftTerm, Metal | unicode | 31 | 31 | 30 | 29 | 31 | 31 | 31 |

After the workloads, over 3 idle seconds:

| Host | Idle CPU (% of one core) | Footprint (MiB) |
| --- | --- | --- |
| Terminal | 2.2–2.9 | 48–77 |
| SwiftTerm, Core Graphics | 1.3–2.3 | 36–36 |
| SwiftTerm, Metal | 1.2–2.1 | 40–43 |

## Reading

- **Plain ASCII:** level. Both reach 250 to 300 MiB/s in their best pass, and
  the spread between passes is larger than the difference between libraries.
- **Mixed Unicode:** Terminal is about 3.3 times faster, and this is the one
  stable result: SwiftTerm stays at 26 to 32 MiB/s in every pass, Terminal at
  68 to 107.
- **Truecolor:** SwiftTerm is about 1.6 times faster than Terminal as a
  package. The cause is how the package is built, not the emulator; see below.
- **Memory:** SwiftTerm's process is smaller, 36 to 43 MiB against 48 to
  77 MiB.

## Why the package is slower than the app on truecolor

The app's release build turns off dynamic exclusivity checks
(`-enforce-exclusivity=unchecked`, `tools/Dev/AppBundle.swift`); the app
measured about 200 MiB/s on this workload the same day
([library-split-2026-11-14](../library-split-2026-11-14/README.md)). A package
cannot pass that flag to the apps that depend on it. Building the same host
with the flag, three alternating runs of the truecolor workload each:

| Build of the Terminal host | Truecolor, median of 10 runs (MiB/s) |
| --- | --- |
| `swift build -c release` | 131, 132, 133 |
| The same with `-Xswiftc -enforce-exclusivity=unchecked` | 190, 193, 184 |

The checks cost about 30% of truecolor throughput for an embedder. The fix
that works in a package is in the source: `@exclusivity(unchecked)` on the
emulator's hot stored properties, or keeping that state in locals on the
parser's fast path.

## Not measured

Frame rate, input latency, startup, resize and memory under scrollback. The
fonts differ, which does not affect parsing. SwiftTerm `main` after
`v1.99.3` was not measured because it does not compile here either.
