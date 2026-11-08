# Pinned Unicode data

The generators and corpus test use only committed inputs. Rust, a Cargo cache,
and network access are not required. Grapheme/width behavior is Unicode18;
search lowercase deliberately retains the Rust baseline's Unicode17 policy.

## Unicode18 graphemes and terminal widths

- `GraphemeBreakTest-18.0.0.txt` is a byte-for-byte copy of the existing 853-case
  fixture, including its Unicode copyright and terms-of-use notice. Its license
  is retained in `LICENSE-UNICODE`. SHA-256:
  `b0cf047ee94485bbdc846de2b902f5f8a815f6b674f9d04223cddadd91c9df31`.
- `grapheme-ranges-18.0.0.txt` contains 1,626 ordered `lower;upper;category`
  records (hexadecimal scalar bounds) extracted from the pinned
  `unicode-segmentation` generated `grapheme_cat_table`. `Any` is recorded as
  `Other`, exactly as the existing Swift generator did. No ranges are merged,
  reordered or inferred from the platform's Unicode version.
- `terminal-width-18.0.0.json` contains the exact non-CJK lookup arrays/ranges
  previously extracted from `unicode-width` 0.2.3 `src/gen/tables.rs`. Compact
  three-byte range endpoints have already been decoded little-endian, matching
  the former generator. It contains data, not a new width algorithm.
- `unicode18-inputs.json` records the upstream-source hashes and each neutral
  input's hash/size. Both Swift generators also pin their input hashes in code;
  changing data requires a deliberate generator update. The corpus test checks
  its own frozen checksum before exercising the segmenter.

The grapheme range source is Copyright 2012–2018 The Rust Project Developers;
the width source is Copyright 2012–2026 The Rust Project Developers. These
derived tables are used under the upstream MIT license in `LICENSE-MIT`.
Keep this attribution and license when removing the original Rust workspace.
The Unicode test fixture retains its separate original notice.

From the repository root, regenerate the checked-in runtime sources with:

```sh
mkdir -p target/native
xcrun swiftc -parse-as-library tools/GenerateUnicode18.swift -o target/native/generate-unicode18
target/native/generate-unicode18
xcrun swiftc -parse-as-library tools/GenerateTerminalWidth.swift -o target/native/generate-terminal-width
target/native/generate-terminal-width
```

The migration changes only provenance comments in the generated runtime files;
all table values and runtime algorithms remain identical.

## Unicode17 search lowercase

`rust-unicode17-lowercase.txt` contains every non-identity result of
`char::to_lowercase()` for each of the 1,112,064 valid Unicode scalars, emitted
by Rust `1.99.0 (b940084d7 2026-09-28)`. Its
`char::UNICODE_VERSION` is `17.0.0`; the record file SHA-256 is
`35e8335ca053474f0baa2ac0525b062468b684253a99377e84563bc5033b9cd0`.

The checked-in Swift generator validates that checksum and writes
`native/Text/UnicodeLowercase.swift`. A clean clone can reproduce the runtime table
without Rust or Foundation Unicode data:

```sh
xcrun swiftc -parse-as-library tools/unicode/GenerateUnicodeLowercase.swift \
  -o target/native/generate-unicode-lowercase
target/native/generate-unicode-lowercase \
  tools/unicode/rust-unicode17-lowercase.txt native/Text/UnicodeLowercase.swift
```

The exhaustive `unicode-lowercase` test regenerates the same canonical records
from the Swift runtime mapping and asserts the frozen SHA-256 independently of
the generated source file.
