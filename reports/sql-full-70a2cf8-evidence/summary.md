# Full 70a2cf8 SQL pass

Frozen `70a2cf8` completes the 8,162,501,113-byte SQL source: 8,183,995,026
wire bytes in 222.612 seconds (35.066 MiB/s). History is 67,107,175 bytes and
peak physical footprint 129,092,480 bytes. UI heartbeat p95/max is
4.666/4.974 ms; owner latency p95/max is 1.3945/20.011 ms. Parsing and reads
end, queues drain, the child is reaped, and the app exits naturally with no
cleanup survivors.

This is a full SQL pass, but not yet a Swift/Rust timing comparison: the paired
Rust run is still in progress. No SQL contents are retained. `release-build.json`
records the frozen immutable-archive release build, including its own launcher,
shader, and hooks.
