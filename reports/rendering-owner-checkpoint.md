# Rendering-owner checkpoint

Base source: `240bced0b95b80822623bdfb7b89a3b21122c299`.

This checkpoint changes renderer ownership only:

- `AppDelegate` owns one `TerminalRendering` instance; panes hold opaque surface
  leases and attach/request/detach through it.
- A demand-paused `CAMetalDisplayLink` supplies each surface's drawable on the
  main/common run loop. The callback only hands that drawable to the single
  rendering executor; it does not encode or present directly.
- The executor retains the existing untimed `command.present(drawable)` before
  `command.commit()` order. Images are namespaced by surface, so independent
  sessions cannot evict or reuse each other's image IDs.

Source hashes after the checkpoint implementation:

```
c37f639d457c701cc5bb561265ae801837ed25e9c31f264b96d88ae435e8879d  native/Renderer.swift
8d7e3d1889581f4d3b7586c5f21e0ac475a91950b32f662dd500a60898a09c39  native/Canvas.swift
8094ab70741342ad451f4217641479dd97c953164b10bd0414fcc019512abcaa  native/main.swift
d8a71e3631912d02bebfc66696a2656832d5426f22ea6301e9a9a711a379bdb4  dist/Terminal.app/Contents/MacOS/Terminal
```

`ruby tools/native_smoke.rb normal` passed against that copied executable: it
exercised split/resize and 56 Metal command submissions with no command errors,
drawable/present mismatches, glyph drops, or buffer drops. It also reaped the
test app and PTY child. This is command/submission evidence, not a compositor
pixel capture.

This checkpoint deliberately **does not** claim completion of the residency
work: GPU work remains serialized to keep existing CPU texture writes safe;
the old atlas/direct-fallback accounting, font-reset behavior, raster work, and
process-wide 64 MiB budget have not yet been replaced. The next slice must add
shared residency, pins/retirement, bounded raster work, and the required
multi-surface liveness/visual evidence before production integration.
