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
