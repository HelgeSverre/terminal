# Paired full SQL comparison

On the same 8.16 GB source, runner settings, and two scheduled resizes, frozen
Rust completes in 115.298 seconds at 67.689 MiB/s; frozen Swift 70 completes in
222.612 seconds at 35.066 MiB/s. Swift is 51.8% of Rust, below the user's 70%
target for this primary SQL workload. The earlier four-workload 868 gate is
source-scoped and does not establish replacement readiness on this workload.

Both runs complete cleanly. Rust peak footprint is 111.831 MiB versus Swift
123.112 MiB; UI p95 is 4.668 versus 4.666 ms, and owner p95 is 0.7987 versus
1.3945 ms. Accounted history bytes (Rust 19,680,000; Swift 67,107,175) reflect
logical representation charges and are neither RSS nor a count match. No SQL
contents are retained. The full-motion 70 run remains active and is not claimed.
