# Unicode 18 pinning

The canonical grapheme source is the vendored `unicode-segmentation` table
source at the revision recorded in `vendor/README.md`. The official fixture is
`crates/terminal-core/tests/fixtures/GraphemeBreakTest-18.0.0.txt`, checked by
SHA-256 in `SwiftUnicode18Tables.swift`.

Run the verifier with:

```sh
xcrun swiftc -parse-as-library tools/GenerateUnicode18.swift -framework CryptoKit -o /tmp/generate-unicode18 && /tmp/generate-unicode18
xcrun swift native/SwiftUnicode.swift native/SwiftUnicode18Tables.swift native/tests/SwiftUnicode18CorpusTests.swift .
```

The corpus runner reports every mismatch count and first mismatch. Generated
GCB/Extended_Pictographic/InCB-Consonant ranges plus the vendored InCB linker
set are emitted into Swift; run it with `--strict` to enforce the 853-case
official fixture as a hard gate.
