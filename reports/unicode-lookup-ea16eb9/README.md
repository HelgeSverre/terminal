# Indexed Unicode grapheme categories

The clean WMO app profile at `ea16eb9` identified repeated category-range
searches while printing Unicode. The generator now packs the same pinned
categories into deduplicated 256-code-point pages. Runtime lookup uses a page
index and a four-bit category instead of a binary search. Segmentation rules
and the Unicode version are unchanged.

The permanent corpus test compares all 1,114,112 code points, including
surrogates, with an independent range oracle read from the checksum-pinned
neutral input. It also checks values above the Unicode range. All 853 official
segmentation cases, decoder tests, emulator tests, 2,400 Unicode span/scalar
differential cases and document ownership tests passed on both implementations.
The final surrogate-inclusive exhaustive run passed on the candidate; the
baseline exhaustive run covered valid scalars. An independent source review
found no actionable defects.

The isolated feed benchmark ran baseline–candidate–candidate–baseline, seven
observations per case in each invocation, with no competing builds or profilers.
`results.json` retains every observation and the source hashes are alongside it.
The benchmark includes primary-history retention; it is not the visible-app
alternate-screen comparison.

| Input | Chunk bytes | Baseline median ms | Candidate median ms | Throughput ratio |
| --- | ---: | ---: | ---: | ---: |
| ASCII | 1 | 79.68 | 80.81 | 0.986× |
| ASCII | 4,096 | 14.93 | 15.16 | 0.985× |
| Combining/emoji clusters | 1 | 105.81 | 99.65 | 1.062× |
| Combining/emoji clusters | 4,096 | 64.19 | 58.90 | 1.090× |
| Multilingual ordinary text | 1 | 145.29 | 130.88 | 1.110× |
| Multilingual ordinary text | 4,096 | 40.79 | 29.06 | 1.404× |

The small ASCII decrease needs whole-app confirmation; this pilot does not
establish a regression under varying desktop load. The headless executable
grows by 272 bytes. Generated source grows from 52,926 to 117,309 bytes; raw
table payload falls from 19,512 to 18,560 bytes, which is not a binary-size
claim. The warm generator takes about 0.098 seconds versus 0.011 seconds.
The measured compile durations share a cache and run in one order, so they
cannot establish a build-speed change. Repeated generation is byte-identical.

These results justify the candidate, not a claim of comparable Ghostty speed.
The separate full-app comparison determines how much carries through.
