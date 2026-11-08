# CSI reuse pilot

Frozen `0465763` was measured Swift-first with the 2 MiB × three-run visible-app pilot. Swift/Rust ratios are 65.75% short ASCII, 71.19% long ASCII, 81.53% ANSI, and 75.25% Unicode. Only short ASCII remains below the current 70% floor, so the overall gate is false and this is not acceptance. WMO core and native smoke passed, and measured apps exited naturally with no survivors. The recorded 23.72-second WMO compile is provenance, not a matched cold-build claim. The in-progress row candidate is excluded.
