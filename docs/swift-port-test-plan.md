# Emulator validation

`native/tests/EmulatorTests.swift` is the narrow public-ABI smoke test, invoked
by `just unit-test --filter EmulatorTests`. It covers basic grid updates, SGR snapshots,
alternate-screen isolation, input bytes, paste, replies and chunked feeding.
It is one gate, not a declaration of parity or full v1 completion.

The mandatory `just test` workflow also runs independent document ownership,
viewport, reflow, semantic, malformed-boundary, scheduler, prompt, graphics,
palette, Unicode18, UTF-8 decoder, width, lowercase, input, OSC52, PTY,
Session, clipboard, snapshot, rendering, keymap and terminfo checks.
`Package.swift` is the build and test graph.

Maintain these contracts when changing the emulator:

1. Compare snapshots, replies, encoded input and observable resource behavior;
   do not normalize away identity, accounting or clamp differences.
2. Keep Unicode18 grapheme/width data and Unicode17 lowercase policy pinned to
   the committed neutral inputs. Host-platform Unicode is not a substitute.
3. Exercise multiple byte partitions and retained snapshots across mutation,
   eviction, reflow and object destruction.
4. Cover graphics transport, placement/deletion, generation and resource bounds
   separately from native dmscene playback.
5. Run owned native application fixtures for input, settings, accessibility,
   automation, quit, glyph pressure and resizing. Always reap their PTY children.

`dev compare-swift-rows` (formerly `tools/compare_swift_rows.rb`, removed after 0.3.0) compiled one probe against two immutable Git
revisions. It recognizes each archived revision's source-group name, so the
naming cleanup does not discard earlier compatibility checkpoints. Native
pixel captures and real input-method/VoiceOver validation remain distinct
from headless ABI assertions.
