# Full SQL motion 65cb446 pass

The full 8.16 GB source drains 8,183,995,484 wire bytes in 237.1411 seconds at
32.91868 MiB/s, with 14,224 ticks over 237.104 seconds. Programmatic motion
varies x, y, width, and height. Peak footprint is 133,123,200 bytes (126.96
MiB), history 55,507,392 bytes, UI p95/max 4.666209/5.646625 ms, and owner
p95/max 39.025542/46.694292 ms. Following remains true with anchor zero, Metal
errors and queues are zero, and the child drains/reaps with clean cleanup.

There is no matched Rust-motion comparison. No SQL contents are retained.
