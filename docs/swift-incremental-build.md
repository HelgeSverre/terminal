# True Swift incremental compile measurement

`tools/SwiftIncrementalBuild.swift` invokes `swiftc -incremental -c` with a
per-source output-file map and persistent `.swiftdeps` files. Unlike a repeated
whole-program `swiftc` command, unchanged source files are eligible to be
skipped by the Swift driver. It builds only the host executable; packaging,
asset copying, Metal compilation and signing are intentionally omitted from the
compiler timing.

From the experiment worktree:

```sh
/usr/bin/time -lp xcrun swift tools/SwiftIncrementalBuild.swift --clean
/usr/bin/time -lp xcrun swift tools/SwiftIncrementalBuild.swift
```

The first command destroys only `target/swift-incremental` and establishes a
clean compiler cache. The second is the no-source-change incremental result.
For a changed-source result, edit or touch one owned Swift source, run once,
then restore it before recording a baseline. The tool neither invokes Cargo nor
launches the app.

The comparison must still report compile/link time separately from full bundle
build time, and must not compare a Swift compiler-cache result with Cargo's
different dependency/cache scope without saying so.

## Distribution configuration

The default configuration is deliberately the development configuration above:
it writes `target/swift-incremental` and preserves per-source objects and
`.swiftdeps`. `just build`, `just dev` and `just test` use it.

`xcrun swift tools/SwiftIncrementalBuild.swift --configuration release` writes
only to `target/swift-release` and invokes one
`swiftc -O -whole-module-optimization` command over the same `app` source
graph, bridge header, module name, deployment target and framework set as the
frozen WMO artifact. It records `provenance.json` with graph/source/header
hashes, toolchain/SDK identity, flags and executable hash. WMO is intentionally
not an edit-time cache.

`just release-build` assembles that WMO executable into the development bundle.
`just install`, `just package` and `just release` depend on `release-build`;
they never package or install the development incremental executable.

The mode was validated without mutable-worktree inputs against a disposable
`git archive 0465763` tree. `xcrun swift tools/SwiftIncrementalBuild.swift
--configuration release --clean` produced provenance whose independently
recomputed graph, app-source, Bridge and Spawn hashes were respectively
`6ed8a18d`, `f37003b2`, `e5baa6ff` and `9ffb179c`; the executable hash also
matched. `just --show _assemble-bundle` verified the development and release
output mappings. This validates configuration/provenance wiring only, not a
comparable timing result.
