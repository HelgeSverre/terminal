# Integrated search parity and SQL stress status

Frozen `db33304` integrates the search checkpoint and pinned case mapping.
The full Swift `just test` passed at `6fe7916`; frozen WMO core and native smoke
also passed. The lowercase parity artifact covers 1,112,064 scalars, 1,488 Rust
Unicode 17 mappings, and the recorded hash `35e833…`; the former Foundation
misses are closed by the generator and records in `tools/unicode`.

The real 8.16 GB SQL dump is negative evidence, not a full-file pass. It was
interrupted after the already failing cap condition: 64 MB parsed in 44 seconds
(1.38 MiB/s), with 72.3 MB history above the 64 MB cap. The owned five-second
sample and provenance record clean cleanup with no surviving owned process. No
SQL contents are retained. Rust replacement remains incomplete; the 868
performance gate applies only to its frozen source.

The ongoing history-owner fix is intentionally excluded.
