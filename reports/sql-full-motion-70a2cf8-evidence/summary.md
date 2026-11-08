# Full SQL programmatic-motion pass

The full 8.16 GB SQL source completes in 355.2135 seconds at 21.9778 MiB/s,
with 8,183,995,079 wire bytes fully drained and all child/queue cleanup complete.
Peak footprint is 116,017,920 bytes, history 67,104,986 bytes, UI p95/max
4.65325/5.230958 ms, and owner p95/max 40.3645/58.545 ms.

The 21,305 ticks span 355.1589 seconds, about 59.99 Hz; recording stops after
cat completion and frame restoration. Tick lateness uses a rolling 12,000-sample
window: its 18.285 ms maximum is not a global full-run maximum. The motion uses
programmatic `setFrame`, not physical drag or compositor instrumentation.
No SQL contents are retained.
