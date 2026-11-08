# Immutable 0587616 complete-app build pair

One sequential build pair completed successfully from immutable archived
sources on this Mac. Rust was fixed at `9cc6f92`; Swift was fixed at
`0587616`. Each run used a fresh project output directory and the same warm
external compiler and dependency caches.

| Source | Optimized app command | Wall time | Executable bytes | Regular bundle bytes |
| --- | --- | ---: | ---: | ---: |
| Rust `9cc6f92` | `just build` | 29.470697 s | 3,745,088 | 9,024,940 |
| Swift `0587616` | `just release-build` | 32.433977 s | 2,017,712 | 7,297,852 |

The build recipes intentionally perform different work: the Rust recipe
includes the Cargo core build, while the Swift recipe builds the WMO Swift
host. This is one complete-app build observation, not a statistical benchmark
or a language-only compile-speed ratio.

Both output bundles were checked against their source-tree hashes and passed
strict deep code-signature verification before relocation. The tracked
manifest, complete build logs, and exact runner are retained here. The signed
app copies are intentionally outside Git; [relocation.json](relocation.json)
records their paths and the hashes used to verify them.

This source-scoped build evidence does not establish CI status, behavioral
parity, or replacement readiness.
