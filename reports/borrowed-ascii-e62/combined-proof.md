Combined uncommitted main CSI-run + borrowed ASCII source was frozen and each copied input rehashed against live source after copying. No live edits.

Frozen emulator SHA256: 7c8517ee859dc4d1580bb1adcaa4ee153338e7b5f0934cc64fef3bed10f0880d
All frozen input hashes: source-hashes.json

WMO compilation flags/commands are in compile.rb. Commands run:

ruby compile.rb candidate CSIDifferentialProbe
ruby compile.rb candidate CSIRunBoundaryProbe
bin/candidate-CSIDifferentialProbe > combined-grammar.txt
bin/candidate-CSIRunBoundaryProbe > combined-boundary.txt
cmp ../baseline-grammar.txt combined-grammar.txt
cmp ../baseline-boundary.txt combined-boundary.txt

Both comparisons PASS:
- 62,918 grammar/partition records: SHA256 630f213d52f3daf64279c9af43999a6b953db71874881b9cebcc1f6ee6ea7982
- 400 limit/backpressure/REP records including consumed offsets: SHA256 14db08eb97fddc9f40f55cf72b7a40e27e3ac4930abf415d31f92aa2a5924db0

Executable SHA256:
- CSIDifferentialProbe: 58378bd166d97bacb9a5d168216cd7d314f6cd3deefc511b4dc7cf3eb917e912
- CSIRunBoundaryProbe: 829132d112f44ddf3471450d246f9e4bfa352bbeb7522515585feee69939ba2d

No timings run. All compiler/test children exited. Other full suites left to root's actual app gate per coordination.
