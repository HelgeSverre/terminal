# Scalar buffer pilot

Frozen `d35690e` is the measured successor to the previously unmeasured scalar-buffer idea. In the 2 MiB × three-run visible-app pilot, Swift/Rust ratios are 66.70% short ASCII, 69.76% long ASCII, 58.59% ANSI, and 73.46% Unicode. Unicode exceeds the 70% floor, but the other workloads do not, so this is not acceptance. The prior d934 failed pilot remains retained as negative evidence. WMO core and native smoke passed and measured apps exited naturally.
