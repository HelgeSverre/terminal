# Pinned Unicode lowercase data

`rust-unicode17-lowercase.txt` contains every non-identity result of
`char::to_lowercase()` for each of the 1,112,064 valid Unicode scalars, emitted
by Rust `1.99.0 (b940084d7 2026-09-28)`. Its
`char::UNICODE_VERSION` is `17.0.0`; the record file SHA-256 is
`35e8335ca053474f0baa2ac0525b062468b684253a99377e84563bc5033b9cd0`.

The checked-in Swift generator validates that checksum and writes
`native/UnicodeLowercase.swift`. A clean clone can reproduce the runtime table
without Rust or Foundation Unicode data:

```sh
xcrun swiftc -parse-as-library tools/unicode/GenerateUnicodeLowercase.swift \
  -o target/native/generate-unicode-lowercase
target/native/generate-unicode-lowercase \
  tools/unicode/rust-unicode17-lowercase.txt native/UnicodeLowercase.swift
```

The exhaustive `unicode-lowercase` test regenerates the same canonical records
from the Swift runtime mapping and asserts the frozen SHA-256 independently of
the generated source file.
