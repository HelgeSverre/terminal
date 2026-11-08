# SQL and history ownership evidence

The full 8 GB SQL run at `90e16ff` timed out at 600 seconds and is retained as
a failure, not a pass. Its prefix profile is diagnostic evidence only. The FIFO
compatibility probe at `8eb9d03` passes its exact 270-record parity suite.

The separate 154 MB SQL window-motion run passes. These results do not turn the
8 GB timeout into a full-file success. Raw runner, source, binary, profile, and
fixture artifacts are retained only in `raw-evidence.tar.gz`; compact JSON
reports remain alongside this summary.
