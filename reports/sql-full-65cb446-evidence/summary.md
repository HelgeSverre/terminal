# Full SQL 65cb446 pass

Frozen 65cb446 completes the 8,162,501,113-byte source in 165.61844 seconds
at 47.126804 MiB/s, draining all 8,183,995,191 wire bytes. Peak footprint is
195,824,576 bytes (186.75 MiB); history is 67,107,175 bytes, below 64 MiB.
The viewport remains following with zero offset and anchor, UI p95/max is
4.679/4.981 ms, owner p95/max 0.133667/26.859 ms, Metal errors are zero, and
the child is reaped with clean cleanup.

Against fresh Rust 9cc at 67.689 MiB/s, Swift is 69.6%, just below the 70%
SQL target. The separate four-parser-workload 86.8%+ results remain a different
gate. No SQL contents are retained; motion evidence is pending.
