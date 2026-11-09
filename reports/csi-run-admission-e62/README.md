# Contiguous CSI parameter admission

The parser scans a bounded run of CSI parameter bytes and appends it once,
then uses the existing command handler. It preserves the legacy byte budget,
high-byte charge, final-versus-overflow behavior, offer limit and REP/reply
backpressure yields. The new assertions run in the existing boundary suite.

Against runtime `9354d3a`, 62,918 grammar/partition records and 400 extra
budget/offset/backpressure records match exactly. The latter probe source is
retained here. Core, semantic and boundary regression suites pass. An independent
source review found no actionable defects.

Seven alternating-order WMO headless pairs give ANSI medians 47.688→50.716
MiB/s, a 6.35% gain; each pair improves by 5.69–7.99%. Short ASCII changes
−0.19%, long ASCII −0.38% and Unicode +0.64%, within the variation of this run.
`headless.json` retains samples, hashes and compiler flags. These are headless
feed results; the subsequent [paired app gate](../borrowed-ascii-e62/README.md)
includes the separate borrowed-ASCII change too.
