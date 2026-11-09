# Comparison brief

Compare the current optimized Swift terminal with installed Ghostty 1.4.0 on
this Mac, using the same PTY workload driver, font, cell grid, and payloads.
Identify useful feature coverage and material gaps from current source/tests
and Ghostty's tagged release documentation.

Questions:

1. What are the per-workload throughput ratios in two opposite launch orders?
2. Which measurements do not establish display latency, FPS, or memory parity?
3. Which everyday workflows are implemented and exercised locally?
4. Where do protocol breadth, text shaping, platform support, and validation differ?
5. Which gaps matter most before claiming general replacement parity?

Sources: current repository implementation/test evidence; Ghostty's official
1.4.0 release notes, configuration/VT/feature documentation, and tagged source.
Use high confidence for direct source/test facts; mark inference and unmeasured
behavior explicitly. No overall feature-parity percentage is justified.
