# Owner-confined PTY read storage

The owner previously allocated and zeroed a 16 KiB array on every PTY readiness
callback, even though these ASCII callbacks averaged about 1 KiB of output. It
now retains that scratch array for the session. Each successful read still
creates an owned immutable `Data` copy inside the short pointer borrow, before
enqueueing. Read limits, event boundaries, fairness, backpressure and EOF
branches are unchanged.

Both original and candidate Session implementations pass 54/54 checks with the
new real-PTY regression. It queues more than 64 KiB of varying position/query
commands behind resumable REP work, compares the complete ordered reply stream,
then verifies EOF and equality of read/parsed bytes. Each suite reaps all 23
owned children, with no unreaped processes. Reports are retained alongside this
file. Independent source review found no actionable defects.

The first combined app diagnostic was slower (55.39 MiB/s versus an earlier
59.96), so it was not treated as a speedup. A subsequent quiet matched
baseline–candidate–candidate–baseline run gave:

| Trial | Short ASCII MiB/s | Read ms/source MiB | Feed ms/source MiB |
| --- | ---: | ---: | ---: |
| Baseline | 58.10 | 3.208 | 10.916 |
| Candidate | 60.62 | 2.758 | 10.864 |
| Candidate | 60.42 | 2.660 | 10.946 |
| Baseline | 58.57 | 3.228 | 10.739 |

Each app run uses 10×16 MiB with the existing opt-in Session counters. The
candidate also includes indexed Unicode categories and faster visible-link
classification; it excludes the settings redesign. Exact identities and patch
hashes are in `source.json`. Read time falls while feed time stays similar in
the matched trials. These instrumented results support retaining the buffer
change, but do not establish an isolated app-level gain for any single patch.
They are not Ghostty comparisons or acceptance timings. Every run drained and
exited naturally, with no owned survivors. Initial and repeated observations
are retained, including the slower first candidate.
