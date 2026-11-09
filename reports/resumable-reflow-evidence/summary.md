Resumable reflow replaces the synchronous implementation with one transaction builder used by both the Swift session bridge and the synchronous C ABI. The builder reserves its immutable input before capture, plans the retained output, copies stored cell runs, and commits one coherent geometry. The scoped reflow gates, integrated Session gate and final frozen-source replay passed. This receipt covers the implementation and headless evidence; it does not claim full v1 or GUI release acceptance.

The owner yields at a 1 ms cooperative deadline or 32,768 work units, with at most one additional bounded row operation. The process-wide reservation ledger admits at most 96 MiB per operation and 128 MiB concurrently. It counts input row storage and container capacities, sparse text/link resources, planning tables, replacement storage, and queued retirement. A private payload dictionary keeps resource charges consistent across COW edits; the public legacy history-byte formula is unchanged.

Only rows surviving the active window and ordinary history limits are built. A bounded ring holds lightweight plans for potentially retained rows. Pressure first retires a captured generation, then evicts bounded packets from the oldest history and replans. Empty FIFO backing containers also retire under a lease. Cancellation and destruction retain reservations until the queued resources are actually released. Rejection preserves geometry, grapheme state, and synchronized-output gating; explicit history-pressure eviction can remain committed.

Intentional spec §9.7 corrections relative to D7:

- Width changes choose the window nearest the old screen start that contains the cursor, rather than always selecting the output tail.
- Ordinary before-atom boundaries map after a required wrap; true pending-wrap positions keep their after-cell affinity. Saved pending-wrap and saved cursor attributes survive.
- Alternate resize preserves top-left coordinates. Cropped soft-wrap edges are removed; cropped row identities no longer retain graphics anchors.
- Clipped-wide cells consume their actual old occupancy and recover nominal width when possible. Planning allows the resulting width expansion.

Verification recorded under `/Users/helge/.codex/artifacts/terminal-resumable-reflow`:

| Check | Result |
| --- | --- |
| Reflow, document ownership, emulator, viewport, graphics, prompt, scheduler, boundary, semantic groups | All nine passed before the final narrow atomicity/affinity fixes |
| Atomicity follow-up: reflow, scheduler, boundary | Passed; cancellation grapheme regression was red before the fix |
| Affinity follow-up: reflow, prompt, viewport | Passed; ordinary boundary regression was red before the fix |
| Final reflow test source | Passed, including restored-wide plan-capacity control |
| Blocked-retirement destruction/cancellation | Reservations remain charged until retirement is released |
| Extreme retention fixture | 409,600 logical output rows, only 32 history rows retained; under 20 MiB, no artificial pressure eviction |
| Rich run copying | Styles, links including empty links, protected cells, combining text, wide fallback and retained snapshots preserved |
| Integrated Session gate | Passed: 50k-row resize yields to owner probes, FIFO and commit-only WINCH; rejected/pending-close cases preserve geometry; A→20→80 returns to the latest admitted size; all 17 children reaped |
| Final frozen-source ABI replay | Five full canonical snapshots byte-identical to D7; same 14,252 retained history rows and 117,436,480-byte charge |

The source manifest records the exact five Emulation/source-test hashes plus the two integrated Session hashes. Session run `F29070C1-3CCE-4D10-A60D-A1573532EF45` exited 0 with identical before/after source manifests. Independent reflow source review and Root’s final Session source review found no blocker. Raw logs, frozen sources, executables and canonical snapshots remain outside Git; the receipt records their hashes and paths.

The final frozen candidate (`accepted-candidate`, manifest SHA-256 `b44bff57cf9ffb422e3f2a583bdc8f749e69b4b615114e887e781a547ce79686`) used the same 10,000-row, 160→120-column public-ABI fixture as D7. Resize plus typed snapshot projection took **33.67–37.99 ms wall / 33.65–37.97 ms thread CPU**, versus D7 **97.88–110.53 ms wall / 86.52–91.91 ms CPU**, across five samples each. All five full snapshots match byte-for-byte. These are headless diagnostic samples, not end-to-end GUI latency or statistical p95 proof. Earlier pre-affinity measurements are retained as labelled checkpoints and are not substituted for this final source.

Limits: the deadline is cooperative and cannot prevent OS preemption or allocator latency. Checked reservations do not make Swift's allocator OOM recoverable. The headless timing fixture includes typed snapshot projection but not AppKit rendering or Session dispatch scheduling. This change retains the existing selection/search invalidation interfaces and does not add a public crop-event schema or complete the separate owner-confined selection/global-admission v1 work.

CI follow-up `25dc31e` corrects the Session cancellation fixture without changing
the product. The earlier 10 ms timer plus main-queue callbacks could send close
after a resize had legitimately committed; CI `42549643929` exposed that race.
The replacement posts admission and a close marker from one owner turn, forcing
close after begin and before the first continuation. It needs no timer or large
workload. Four local runs pass with no WINCH and all 17 children reaped; the
50k-history commit case still checks owner fairness. Final release evidence is
recorded in `../distribution-0.2.1-evidence/`.
