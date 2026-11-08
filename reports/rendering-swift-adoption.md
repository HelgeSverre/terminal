# Native rendering adoption into Swift

Source checkpoint: `436d65da6aa31abf1b264e54f0723caf553c5521`, preserved on the
private `HelgeSverre/terminal` remote as `rendering-residency-recovery-d460388`.
The receiving Swift tree started at `a723946`; the independent row-storage change
`70a2cf8` landed before this adoption commit. The frozen a723 benchmark was not
modified or rerun.

## Integration inventory

| Files | Adopted change / preserved Swift behavior |
| --- | --- |
| `native/Renderer.swift` | One AppDelegate-owned rendering service, per-surface display links and fair serialized submission, shared glyph owner, asynchronous raster misses, material-specific drawing. Preserves Swift `CellPalette`, underline colors and clear-background resolution. |
| `native/Canvas.swift` | Surface attach/request/detach and surface geometry diagnostics. Preserves attributed accessibility, style ranges, safe link routing and native top-left placement. |
| `native/main.swift` | Creates the shared service and detaches panes/windows explicitly. Preserves the session-statistics callback before natural-exit termination. |
| `native/Font.swift` | Exposes resolved CoreText glyph IDs with each bitmap. |
| `native/Terminal.metal` | Matching four-vector instance layout and distinct R8 coverage / premultiplied color sampling. |
| `native/GlyphRasterWorker.swift`, `native/GlyphResidency.swift` | Exact preserved checkpoint sources: bounded asynchronous worker and shared capacity, demand, pin, upload and recovery state. |
| `native/tests/GlyphRasterWorkerTests.swift`, `GlyphResidencyTests.swift`, `GlyphResidencyScenarioTests.swift` | Preserved worker, offscreen shader, allocator, multi-surface recovery and quiescence tests. |
| `tools/swift-sources.json` | Adds both runtime files to `app`; adds `glyph_raster_worker` and `glyph_residency` test groups. |
| `justfile` | Adds graph-driven `glyph-rendering-tests` and invokes it from the existing mandatory `test` recipe. Keeps the Swift incremental/WMO pipeline and introduces no Rust dependency. |

Canvas/main merged without conflicts. Renderer had two conflicts in legacy atlas
formatting and color conversion; both retain the Swift-side implementation.
The live drawing path retains all `CellPalette` behavior. No Document, SwiftGraphics,
Session, Preferences, parser or shell-integration source was changed by this adoption.

## Native proof run

All commands below passed from the Swift worktree:

```sh
xcrun swift tools/SwiftIncrementalBuild.swift --verify
just build
just glyph-rendering-tests
xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h $(xcrun swift tools/SwiftIncrementalBuild.swift --print snapshot_bridge) target/native/Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/snapshot-bridge-tests
target/native/snapshot-bridge-tests "$PWD"
git diff --check
```

The build verified 38 app sources and 27 test groups. The glyph suite covers
unchanged oversized demand, B-only recovery, direct pins/completion wakeups,
two-surface union/detach, mixed materials, multiple-victim reclaim, delayed CPU
reservations, quiescence and the production R8/RGBA Metal shader. Snapshot tests
pass colors/styles/links, Unicode, scrolling, images, synchronization and lifetimes.

Logs are frozen under
`/Users/helge/.codex/artifacts/glyph-residency-recovery-d460388/swift-adoption-a723946/`.
The earlier repair's same-fixture RED/GREEN evidence remains in the parent directory.

No GUI app was launched. Root owns the GUI slot and must validate the adopted
binary before claiming new displayed-frame correctness. Focused next commands are
`ruby tools/native_smoke.rb normal`, `glyph`, `atlas` and `atlas-budget`, one at a
time, plus owned-window intermediate-frame split/resize capture and multi-window
font/close recovery. The old atlas modes predate this shared owner: inspect their
assertions/metrics rather than assuming they exhaust the new global capacity.
Use `just release-build` before release-build GUI/performance evidence.

## Scope against the full specification

Implemented: a single rendering owner and glyph cache across panes; 64 MiB glyph
GPU-capacity admission including the legacy bridge; actual heap charging; a bounded
256-job/8 MiB raster worker; per-surface demand union; generation-safe page reuse;
submitted-use pins; callback-driven recovery and stable fallback under pressure.
The serial one-submission scheduler keeps CPU texture writes outside GPU sampling.

Remaining specification work is explicit:

- Reclamation is partitioned: atlas pages recycle within the same material kind,
  while exact textures reclaim other direct textures. It is not a cross-pool global
  LRU, so inactive allocations in another pool cannot yet fund a fitting request.
- Startup still allocates the legacy 2048-square RGBA atlas (roughly 16 MiB) used
  for the solid texel. This is charged, but does not meet the fully lazy small-page
  design. Dead legacy glyph paths should eventually be removed.
- Recipes use text/cell-span dimensions and font/style identity, not the complete
  shaped-run/per-glyph-ID/subpixel cache model. Explicit font/device epochs and a
  distinct backing-scale key remain absent; current recipes use scale 1 with pixel
  dimensions and point size already scaled by the view.
- The worker bounds jobs/bitmap bytes and the allocator bounds charged glyph GPU
  capacity. Other CPU cache metadata and image textures are not all charged to
  that glyph limit. This is not a claim of a process-wide total-memory cap.

This adopts the reviewed residency checkpoint; it does not declare the complete
rendering architecture or compositor verification finished.
