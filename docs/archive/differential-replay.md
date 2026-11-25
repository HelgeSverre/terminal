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
1–7 byte chunks. Reports retain raw Swift and Rust dumps plus a canonical
semantic snapshot. The canonical comparison includes every field exposed by
both sides, including colors, cursor pending-wrap, styles, links and cells.
Swift's screen-local margin observations are retained separately because the
frozen Rust JSON format does not expose their equivalents. `terminal-tools`
also has no reply-queue projection; the Swift reply bytes remain an explicit
observation, not a claimed comparison.

Rust is external to the experiment: it is neither linked into nor built by the
Swift app. The initial fixtures are deliberately small smoke transcripts. A
successful fixture is evidence only for that exact transcript; failures are
kept as data for porting, not filtered out.
