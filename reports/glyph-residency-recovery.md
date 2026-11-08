# Glyph residency recovery repair

Reviewed base: `d460388a00a9230d88064c16c03534f9db367401`. This report covers the
uncommitted repair on that experimental integration tree, not production main.

The inherited two-surface probe called `resolve(B)` and then manually installed
B while its real worker request still held a CPU reservation. That bypassed the
acceptance step which releases the reservation. Its original failure is preserved,
but is not counted as evidence of a production allocator defect. The replacement
scenarios drive the bounded worker, its owner-queue callback, upload staging and
frame boundaries.

## Corrected behavior

- Successfully rasterized glyphs denied by current demand are suppressed until
  demand changes, rather than cached as permanent raster failures.
- Uploads blocked by submitted pins remain staged. Direct-texture completion
  releases pins and requests the recovery frame, just as atlas-page completion
  does.
- Pending CPU reservations also retain recoverable uploads. Their acceptance
  releases the reservation and requests another frame. Cached direct allocations
  are not reclaimed while those reservations still prevent replacement.
- A larger direct texture can reclaim several obsolete, unpinned allocations.
  References local to reclamation are released before the replacement allocation.

Admission still charges actual Metal heap capacity. The fixture obtains actual
heap sizes too: queried texture requirements were slightly smaller on this GPU.
It does not relax the allocator budget to hide a failure.

## Verification

`just build`, the isolated raster-worker tests, and the headless residency suite
passed. `git diff --check` passed. The suite includes the production R8/RGBA shader
fixtures and the existing real-CoreText delayed-B callback test.

The new worker-driven scenarios assert:

1. A+B settles on resident A plus fallback B; B-only recovers and becomes idle.
2. An oversized B upload survives A's submitted pin, and completion requests its
   recovery frame without requiring another raster result.
3. Two surfaces preserve the union of their visible glyphs; detaching A's surface
   admits B and then stops issuing work.
4. Replacing one surface's oversized mask glyph preserves the other surface's
   color glyph.
5. A demand change can recover two atlas pages, and a larger exact texture can
   reclaim two obsolete direct allocations.
6. A controlled job held in the actual raster OperationQueue cannot permanently
   suppress an earlier fitting result or prematurely evict cached allocations.

Every settled scenario repeats eight complete synthetic frame cycles and asserts
no pending/upload work, no additional redraw callbacks, and stable charged GPU
capacity. Synthetic pixels control dimensions and material; scheduling, bounded
worker admission, callbacks, uploads and Metal heap allocation are production code.
Pins are driven explicitly in the headless fixture. The current renderer's single
submission scheduler normally waits for completion before another preparation.
These tests establish residency-state behavior, not compositor pixels or new
window/split rendering evidence. No GUI app or PTY was launched for this repair.

## Frozen controls and provenance

Artifacts: `/Users/helge/.codex/artifacts/glyph-residency-recovery-d460388`.
`manifest.json` records source, executable, shader, build-log and result-log SHA-256
hashes. Its SHA-256 is
`02118e55c5b2ca5f06b577ebefb5ec54db0e16745e3e192b99c17d1366ecccc0`.

| Frozen executable | Result with final fixture |
| --- | --- |
| `same-fixture-red` | SIGTRAP: pinned upload discarded instead of retained |
| `reservation-red` | SIGTRAP: CPU reservation pressure discarded recoverable upload |
| `reclaim-red` | SIGTRAP: CPU reservation pressure prematurely reclaimed cached A |
| `same-fixture-green` | Exit 0: all scenarios and production shader fixtures pass |

The original red allocator's production portion is byte-for-byte identical to
the base after excluding the test-only block. The other red sources freeze the
intermediate implementations before their respective corrections. All controls
use the final scenario source and the same worker seam. The frozen green executable
also passes from the artifact directory using its frozen Metal shader library.

The original incorrect probe is preserved as `original-red.log`; it is separate
from the valid controls above. No prior stretch-capture evidence is reused to
claim correctness of this residency repair.
