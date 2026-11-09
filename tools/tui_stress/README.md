# Real TUI pane stress

This is a short, explicit GUI diagnostic for the real installed `codex` and
`files` programs. It is not a synthetic renderer test. The Codex scenario uses
one fixed public prompt against a disposable loopback provider, never a real
model or external API. Each invocation copies the supplied app bundle
to its new report directory, starts that copy with an isolated fixture shell,
and removes only processes that it started.

Run preparation first. It compiles the small native helpers and tests the inner
PTY relay; it does not launch an app, workload, capture, or GUI input.

```shell
just tui-stress-prepare
```

For the usual installed-app run, the runner finds the local distribution
receipt whose executable hash matches `~/Applications/Helge Terminal.app`.
It refuses a changed or ambiguous install and creates a fresh timestamped
report in `/tmp`:

```shell
just tui-stress files
just tui-stress codex
```

The GUI phase requires Accessibility and Screen Recording already granted to
the local diagnostics helpers. It intentionally refuses an existing report
directory and checks both the input and copied app bundle against the provided
executable hash. Run the workloads separately so every run has a fresh shell,
private working directory, and private Codex state directory:

```shell
app=/path/to/Terminal.app
source_sha=$(git rev-parse HEAD)
app_sha=$(shasum -a 256 "$app/Contents/MacOS/Terminal" | awk '{print $1}')

ruby tools/tui_stress/run.rb --workload files --app "$app" \
  --source-sha "$source_sha" --executable-sha256 "$app_sha" \
  --output /tmp/terminal-tui-files-stress

ruby tools/tui_stress/run.rb --workload codex --app "$app" \
  --source-sha "$source_sha" --executable-sha256 "$app_sha" \
  --output /tmp/terminal-tui-codex-stress
```

The driver splits right, creates a nested lower pane, drags both dividers,
closes and recreates a pane, changes window dimensions rapidly, then verifies a
settled three-pane layout. The fixture relays the real workload through a
private inner PTY and records child identity, bounded output, and real WINCH
sizes. The final AX screen invariant only checks public `TUI_STRESS_*` canaries.

Each report includes `analysis.json`, fixture event logs, `input-events.json`,
the final AX invariant, an MP4, and sampled PNGs. The reused capture helper's
synthetic marker classifier is **always inconclusive for real Codex/Files
output**. The MP4/PNGs are evidence to inspect visually; they are not a pixel
oracle or a pass/fail rendering verdict.
