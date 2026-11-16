# Release runner isolation: candidate verification

Issue: [#9](https://github.com/HelgeSverre/terminal/issues/9).
Tested source: `9a6265145d80824cf913d795e918eddb6777afe9` (0.6.2, build 22).
The candidate was run with `gh workflow run release.yml --ref main`.
[Run 43977693224](https://github.com/HelgeSverre/terminal/actions/runs/43977693224)
passed on macos-15. This was an artifact-only candidate: publication was skipped;
no version tag, GitHub release, or Homebrew update was created.

## Timing

Compare first test-job start through the completion of signing-job cleanup,
including the gap between jobs and excluding publication and the initial queue.

| Measurement | Previous 0.6.1 release | Candidate |
| --- | ---: | ---: |
| Test/build/sign/notarize wall time | 19m 06s | 19m 17s |
| `Run tests` step | 11m 14s | 11m 07s |
| Developer-tool compilations | 2 | 2 |

Baseline: [run 43848945142](https://github.com/HelgeSverre/terminal/actions/runs/43848945142)
at `3ad91fecedff8116f22bc0ec705c0e710405ac28`, 2026-11-16 10:27:08–10:46:14 UTC.
Candidate: 2026-11-16 23:15:36–23:34:53 UTC. Test job: 14m 01s;
handoff: 3s; build/sign/notarize job: 5m 13s. Both runs missed their build cache.

The candidate was 11 seconds (0.96%) slower than the latest release. This single
run shows no significant slowdown; it is not a controlled performance benchmark.
For context, the preceding 0.6.0 release took 18m 08s for the same boundary.

## Checks

- `just test` passed in CI: 117 developer-tool tests, 362 app tests, and one
  Metal-upload probe test, plus the workflow's tooling and PTY checks.
- The existing hosted Apple Paravirtual GPU policy skipped glyph residency after
  its upload-driver probe fault. The baseline had the same exclusion. This run
  does not replace the local real-GPU gate.
- The signing job used a separate runner, installed no Homebrew test tools,
  restored no test cache or artifacts, and imported credentials after compilation.
- Universal app build, signing, notarization, update-feed signing, checksum
  generation, artifact upload, and credential cleanup all passed.
- Downloaded `signed-release` with `gh run download 43977693224 --name signed-release`.
  `shasum -a 256 -c SHA256SUMS`, `codesign --verify --deep --strict`,
  `xcrun stapler validate`, and `spctl --assess --type execute --verbose=2`
  passed. Gatekeeper reported `Notarized Developer ID`.
- The downloaded bundle reports version 0.6.2, build 22; `lipo -archs` reports
  x86_64 and arm64. The downloaded candidate was not installed or launched locally.

## Artifact identity

[Signed artifact 14282987771](https://github.com/HelgeSverre/terminal/actions/runs/43977693224/artifacts/14282987771)
expires 2026-11-30. Raw downloads are retained locally outside Git.

- ZIP: `HelgeTerminal-0.6.2-universal.zip`, 8,322,589 bytes.
- ZIP SHA-256: `ab4c4ecfa412725fb4a8ed1be0b522cf6202ac68fcfba098696891a34115493f`.
- App executable SHA-256: `c1ff4d37d6339cfe54d18689c2f4cd603dc7d0d2c961144f709d254e6ca2531a`.
- Appcast SHA-256: `eb03c67ceca4f41ff180baf9e025d276fa485d6e7cd46626e8d286030facc853`.
- GitHub artifact archive SHA-256: `d021629b43fba61e75cd83aeef4af5883f5ec7568852a68631796f114821c0e2`.
