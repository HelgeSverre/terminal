# Frozen 4ca WMO app provenance

Created without rebuilding after the isolated build. This report describes the
artifact used for the follow-up app smoke/timing work; it is not a benchmark.

## Inputs

- Repository HEAD: `4ca285f0c4dcf9de200c75b91e83cc5649db2f22`
- Source graph: [`tools/swift-sources.json`](../../tools/swift-sources.json)
- App source list: `xcrun swift tools/SwiftIncrementalBuild.swift --print app`
  (34 Swift files, in the order recorded in `input.sha256`)
- Aggregate SHA-256 of those 34 files plus `native/Bridge.h`,
  `native/Spawn.c`, and `tools/swift-sources.json`, both before and after
  compilation: `328bd2b4cb17935b821917dac784fae68734db0519c62790ec1a46fa35af6cae`
- Compiler output:

  ```text
  swift-driver version: 1.127.15 Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)
  Target: arm64-apple-macosx15.0
  ```

## Exact build commands

The following was run from the repository root. `SOURCE_ARGS` was populated,
in order, from the `--print app` command above; the fully resolved list and
every input digest are in `input.sha256`.

```bash
ditto dist/Terminal.app target/frozen-4ca-wmo.app
xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 \
  -c native/Spawn.c -o target/frozen-4ca-wmo-build/Spawn.o
xcrun swiftc -swift-version 5 -O -whole-module-optimization \
  -target arm64-apple-macosx15.0 -module-name TerminalIncremental \
  -import-objc-header native/Bridge.h -framework AppKit \
  -framework QuartzCore -framework Metal -framework CoreText \
  -framework ImageIO "${SOURCE_ARGS[@]}" target/frozen-4ca-wmo-build/Spawn.o \
  -o target/frozen-4ca-wmo-build/Terminal
ditto target/frozen-4ca-wmo-build/Terminal \
  target/frozen-4ca-wmo.app/Contents/MacOS/Terminal
codesign --force --sign - target/frozen-4ca-wmo.app
codesign --verify --deep --strict --verbose=2 target/frozen-4ca-wmo.app
```

The WMO Swift invocation took `real 21.76s` (`user 21.11s`, `sys 0.73s`).
No source file changed during compilation. The cloned bundle's main executable
was the only payload file replaced; bundle signing updated signature metadata.

## Artifact manifest

| Path | Size | SHA-256 |
| --- | ---: | --- |
| `target/frozen-4ca-wmo-build/Terminal` | 1,543,272 B | `e8a1775787daf920a3bbe289aa88d199b4d2bef039830cd6f82a643677189032` |
| `target/frozen-4ca-wmo-build/Spawn.o` | 6,400 B | `84caeca60616fe9ae9757722bdd4a4eb5834ed27caa39706361f621deb34f108` |
| `target/frozen-4ca-wmo-build/swift-core-wmo-tests` | 502,920 B | `e795824c50f099e4e5372cce590e25832a6d70c29ae8629de027959eff9bffff` |
| `target/frozen-4ca-wmo.app/Contents/MacOS/Terminal` | 1,561,424 B | `3fb5564cf825ee477f9129cfea6352d230447f69129a20ab47dc09bda3527894` |
| `target/frozen-4ca-wmo.app/Contents/_CodeSignature/CodeResources` | 8,254 B | `5e9d626fd174f3ae22d7a06ea87f5f60b0c5b0f9ec20849b817ea057cfd93628` |

- Bundle path: `target/frozen-4ca-wmo.app`
- Bundle size: 6,752 KiB
- Bundle file-manifest SHA-256:
  `2c1c41ab40080f1f279064e3ef0192e1e3cee3360f82da4d5b22b5fc42387ced`
- `codesign --verify --deep --strict` passed.

## Focused WMO ABI check

The existing `swift_core` source group was compiled with the identical
`-swift-version 5 -O -whole-module-optimization -target
arm64-apple-macosx15.0 -import-objc-header native/Bridge.h` flags and its
normal `Foundation`, `CoreGraphics`, and `ImageIO` framework links.

- Compile wall time: `real 10.32s` (`user 9.88s`, `sys 0.52s`)
- Result: `PASS Swift core smoke: grid, SGR, alternate screen, wire input/replies, resize`

No GUI was launched and no benchmark was run by this build task.
