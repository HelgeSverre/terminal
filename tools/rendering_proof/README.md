# Final-binary rendering capture

This tool is prepared for an exclusive, root-coordinated GUI slot. Do not run it
while another GUI test or the user is interacting with the desktop. Preparation
and self-tests create no windows and send no input:

```sh
ruby tools/rendering_proof/run.rb --prepare
```

After the final mode/palette build is frozen, use that build's full source SHA and
executable SHA-256 from its provenance. These are inputs, not inferred from the
possibly changing worktree. Run the two commands sequentially with distinct fresh
output directories:

```sh
ruby tools/rendering_proof/run.rb \
  --app "$FINAL_RENDER_APP" \
  --source-sha "$FINAL_RENDER_SOURCE_SHA" \
  --executable-sha256 "$FINAL_RENDER_EXE_SHA" \
  --output /Users/helge/.codex/artifacts/rendering-final-candidate

ruby tools/rendering_proof/run.rb \
  --app "$FINAL_RENDER_APP" \
  --source-sha "$FINAL_RENDER_SOURCE_SHA" \
  --executable-sha256 "$FINAL_RENDER_EXE_SHA" \
  --output /Users/helge/.codex/artifacts/rendering-final-negative \
  --negative-control
```

The runner verifies the executable, snapshots a manifest of **all bundle files and
symlinks**, copies the bundle without modifying/signing it, and verifies the copy
and original still match. Helpers are cached only when their source and executable
hashes match the recorded build stamp. The fixture launch uses a private synthetic
shell for every pane; it displays no SQL, user commands, files or shell prompts.

`Driver prepare` targets only the newly spawned PID, checks its executable path,
requires one AX window and exactly one same-PID, layer-zero CG window matching its
frame within one point on each coordinate/dimension. AX and CG use global top-left
screen points; neither Retina scaling nor AppKit Y inversion is applied to this
comparison. The identity records both frames, deltas, tolerance, candidate count
and matched ID. The exercise revalidates that ID before sending input. Independent
cell dimensions come from the pane's AX bounds-for-range.
`Capture` verifies both window ID and owning PID before
creating a desktop-independent ScreenCaptureKit window filter. Audio, microphone,
cursor and child-window capture are disabled. All sample statuses, raw PTS,
callback host times, capture errors, component bounds and PNG failures/inconclusives
are retained alongside the whole window video.

Capture success requires the recording delegate's successful finish callback and
a nonempty regular `capture.mp4`. A recording failure cannot count as completion.
The runner independently requires `summary.json` to report `recording_finished:
true`, no recording error, and an existing nonempty MP4. Missing finalization or
video makes the run fail even if frame geometry passes; summary and video hashes
are preserved in `analysis.json`. Headless tests cover mismatched/ambiguous window
selection and absent, unfinished, failed or empty recording evidence.

The exercise creates right and nested-below splits, drags both native dividers,
drags the owned window's resize corner, performs programmatic window resizes, then
leaves static output. Mouse events use HID delivery because the prior directed-PID
mouse experiment did not enter AppKit tracking. Foreground ownership is checked
immediately before every event; an exclusive GUI slot is still required because
checking focus and posting an event are not one atomic operation. Cancellation
posts mouse-up to the owned PID if it lost focus. Keyboard events target the PID.

The script requires existing Accessibility and Screen Recording permission and
does not request prompts. It requires a visible screen at least 1180×860 points.
Every app/helper/PTY descendant is tracked and reaped with the existing owned-process
runner. Failed runs keep their artifacts and return nonzero.

## What the automated checks establish

- Magenta, green and cyan identify three panes. Each solid rectangle must be six
  native cell widths by two native cell heights. Both dimensions are checked
  independently; uniform scaling cannot pass merely by preserving aspect ratio.
- Missing/ambiguous or clipped markers and scaled capture frames are inconclusive,
  not successful observations. Failure/inconclusive images must be inspected.
- A 32-bit barcode carries two four-bit sentinels, a 16-bit payload and an eight-bit
  pane-dependent checksum. Final payload is `0x8000 | (rows << 8) | columns`, with
  explicit bounds of 1–127 rows and 1–255 columns. The final gate requires all three
  correct markers and decoded **latest final PTY geometry** in one captured frame.
- Native input is not declared effective merely because events were posted. Each
  drag requires changing PTY geometry within at least one pane and complete capture
  callbacks during the interval. Ruby uses `CLOCK_UPTIME_RAW`, checked against
  `ProcessInfo.systemUptime`; ordinary Ruby `CLOCK_MONOTONIC` has a different sleep
  offset on this Mac. Raw SCK PTS is retained for frame intervals, not compared to
  host uptime. Phase attribution uses callback receipt time and may lag acquisition.
- The negative control deliberately doubles fixture rectangle width. It must
  produce the expected `+6 cells, +0 rows` dimension error in all three panes in a
  single captured frame. An unrelated failure cannot make this control pass.

This is a **narrower external oracle** than the old instrumented probe: it does not
verify same-frame pane-local offsets or `MTLDrawable` presentation callbacks. The
negative control checks detection sensitivity; it is not a compositor-gravity
toggle. Native AppKit live-resize begin/end hooks are also unavailable externally.
The report's `passed` field refers only to these documented gates. It does not mean
every display frame was captured or every inconclusive frame was visually correct.
Inspect intermediate glyphs, markers, blank frames and final text in the retained
PNGs/video, and report all errors/gaps/inconclusives.

## Historical harness location

The prior source is diagnostic commit `53bb3b9`, particularly:

- `tools/rendering_probe.rb`, `tools/build_rendering_proof.sh`
- `tools/RenderingCapture.swift`, `tools/RenderingDrag.swift`
- `native/RenderingProbe.swift` and opt-in Canvas/Renderer/main instrumentation

The reviewed oracle and executed binaries remain at
`/Users/helge/.codex/artifacts/terminal-rendering-proof-v2/ReviewedRenderingCapture.swift`
and its `binaries/` directory. The original `--rendering-proof` command only works
with that instrumented `RenderingProof.app`; the final production binary has no
such entrypoint. Old 536/658-frame outcomes are historical evidence and cannot count
as results for this new run. See `docs/rendering-proof-followup.md` for that record.

At preparation time only compilation/headless checks have run. Native input,
permissions and capture of this new external harness still require the coordinated
GUI run before it can provide new visual evidence.
