# Incremental Swift host build

`tools/SwiftIncrementalBuild.swift` caches only the AppKit host under
`target/swift-host-incremental`. `tools/swift-sources.json` is the one source
graph for both the host and Swift-native test recipes. Verification rejects a
missing, duplicate, out-of-tree, or unlisted app/test Swift source so adding a
file cannot silently bypass the normal build.

Cargo remains the sole builder of `terminal-core`; its release archive and
`Spawn.o` are separate, content-hashed link inputs. A Rust body change
therefore recompiles Rust and relinks the app, but does not invoke the Swift
frontend. A Swift body edit recompiles through Swift's `-incremental` driver;
an absent object or `.swiftdeps` also rebuilds safely.

The cache configuration fingerprints the source graph, bridge header, exact
compiler path/version/content hash, SDK path/version/build, target, compiler
flags and linker flags. Swift 6.2's incremental dependency state itself is
timestamp based, so when this driver detects changed Swift content with an
unchanged source timestamp it discards that state and performs a safe host
rebuild. A bridge-content change is configuration invalidation and likewise
starts fresh. Missing source-comparison metadata also discards incremental
state; failed cache invalidation stops the build. Resources (Metal, plist, fonts,
dictionary, terminfo) remain the bundle recipe's concern and do not invalidate
Swift objects.

Use `xcrun swift tools/SwiftIncrementalBuild.swift --clean` to remove only the
host cache. `just build` validates the shared source graph and preserves the
launcher, Metal, plist, AppleScript dictionary, terminfo, font and signing
workflow.

Run `just swift-host-build-test` for a headless clean-build/no-op assertion.
It removes only `target/swift-host-incremental`, compiles the host once and
requires the next driver run to report `Swift host no-op`.
