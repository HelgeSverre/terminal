# Swift differential replay

`tools/SwiftDifferential.swift` builds a temporary Swift ABI runner, feeds it
the physical fixture chunks, and compares its final JSON snapshot against the
Rust `terminal-tools` oracle fed the concatenated bytes. It writes a
machine-readable report containing both snapshots and the first recursive
difference.

```sh
xcrun swift tools/SwiftDifferential.swift \
  --rust-root /path/to/frozen/rust-terminal-worktree \
  --output reports/swift-port/differential.json
```

Use `--partition whole`, `--partition byte`, or `--partition random` to feed
the same concatenated bytes as one write, one byte at a time, or deterministic
1–7 byte chunks. The raw comparison preserves colors, cursor pending-wrap,
styles, replies, and every published metadata field; it does not normalize
away schema differences.

Rust is external to the experiment: it is neither linked into nor built by the
Swift app. The initial fixtures are deliberately small smoke transcripts. A
successful fixture is evidence only for that exact transcript; failures are
kept as data for porting, not filtered out.
