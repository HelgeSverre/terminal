# Visible link classification

The visible-app profiles identified repeated Foundation whitespace-set creation
and Unicode classification during link/accessibility projection. The change
retains the immutable set and recognizes its exact ASCII subset directly.
Non-ASCII classification, token buffering, supported URL schemes, accessibility
and activation proofs retain their existing behavior.

Baseline and candidate pass the existing visible-link tests and permanent
reference-policy checks over ASCII, known Unicode separators and seeded random
Unicode scalars. A separate frozen/new differential compares 1,170 delimiter
cases, occurrences, grid mappings, activation proofs, soft wraps, OSC 8 and
overlong/capped input. The final test inputs and executable hashes are recorded
in `corrected-test-hashes.json`. An accidental NUL literal in the first test
draft was corrected and both variants rebuilt and rerun before integration;
production source was unaffected.

The isolated benchmark runs 64 projections per observation at 100×30 cells,
seven observations per invocation, in baseline–candidate–candidate–baseline
order. The 14 observations per variant have identical result checksums.

| Projection input | Baseline median ms | Candidate median ms | Throughput ratio |
| --- | ---: | ---: | ---: |
| ASCII | 97.24 | 47.25 | 2.06× |
| Unicode | 124.23 | 75.01 | 1.66× |
| Plain URLs | 196.24 | 99.39 | 1.97× |
| OSC 8 | 59.34 | 44.67 | 1.33× |

These are projection construction timings, not whole-app throughput, rendering
FPS or a Ghostty comparison. `timing-summary.json` retains raw observations;
`VisibleLinkBench.swift` retains the fixture and measurement loop.
