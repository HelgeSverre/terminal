# Full SQL timeout and bounded controls

The final `a723946` 8 GB SQL run fails at the 600-second deadline after
5,737,408,178 parsed wire bytes, about 9.119 MiB/s. History remains bounded and
the app exits 0 with clean owned-process cleanup, but the file is not complete;
this is not a pass. `sample-midrun.txt` is archived with validated owned-PID
identity.

The 64 MiB prefix profile passes at 17.8126 MiB/s wall throughput over 3.586
seconds (3.602 seconds stream time). Sampling overlaps the tail, so it makes no
two-resize claim. The exact 270-record `70a2cf8` row compatibility control
passes. The subsequent charge optimization is not yet SQL-measured.
