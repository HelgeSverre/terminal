# EOF interaction lifecycle receipt

The focused Session gate exposed an EOF lifecycle regression: `endRead()` calls
`endWrite()`, which previously made the one `accepting` flag false. That flag
also controlled selection/link admission and converted their undelivered Main
results to cancellation. The retained final screen was therefore searchable but
could not support owner-validated read-only interactions.

## Red

- Command: `just _session-test`, followed by the freshly built
  `target/native/session-tests "$PWD"` test binary.
- Run: `B45D128F-135C-47F0-B008-4B853FA7808B`.
- Result: exit 1. The short-lived fixture had `eof=true`, `reaped=true`, and
  ordinary input rejection remained true, but range-selection admission was
  false; copy and link completion were consequently absent.
- Cleanup: all 22 owned children were reported reaped.
- Reconstructed exact Session-group input manifest fingerprint:
  `74a014cdb7a146e774fe0ba3104f97398ba81746243ce3478867872becf2b211`.
  It is the ordered SHA-256 manifest of the 26 files printed by
  `SwiftIncrementalBuild --print session` plus `target/native/Spawn.o`, with
  the pre-fix `Session.swift` and red fixture source substituted. The retained
  pre-fix file hashes are `18649c8dcea27fb9b27985047e14341d2010a03dae525fd2d6c8010bf9cc08bd`
  (`Session.swift`) and `f915b63ae79f9e4e28ca87f9615d62e3154da46cefc7be77cee5b7bc91df841a`
  (`SessionTests.swift`).

## Green

- Same focused command and directly-run fresh binary.
- Run: `0EBC41D9-9AAD-4006-A628-6592004C6BC7`.
- Result: exit 0. The reaped final snapshot range-selects, copies
  `FINISHED_SELECT`, and accepts the pre-projected
  `https://example.test/finished` URL. Ordinary input remains rejected;
  pending selection/link explicit-close cancellation checks remain true.
- Cleanup: all 22 owned children were reported reaped. The raw structured
  report is `green-session-tests-0EBC41D9-9AAD-4006-A628-6592004C6BC7.json`.
- Ordered Session-group input manifest fingerprint:
  `c6f0c8460c5ccac21bfe26ad87a4c0981b0e343a61ed20469f081d0ddccae3da`.
  Final changed-file hashes are
  `06c69ec64ba79eece6eae3c42b28de9c7c8716108592a0e7adb5d4400ac4ec55`
  (`Session.swift`) and
  `e7a71cc111c80507d28429541bcb028e6c97940cb4bd0c424913bc0b9ce6de9e`
  (`SessionTests.swift`); the shared `Spawn.o` hash was unchanged at
  `84caeca60616fe9ae9757722bdd4a4eb5834ed27caa39706361f621deb34f108`.
