SGR compatibility fixes against archived Rust `9190820`.

This patch is separate from the Codex color incident, whose cause was `NO_COLOR=1`. It changes only `TerminalEmulator.swift` and the existing mandatory `EmulatorTests.swift`.

- Empty parameters before colon colors reset rendition.
- Invalid indexed/RGB values leave the previous color unchanged; their operands remain consumed.
- Colon RGB reads the required three channels, rejects missing channels, and ignores trailing fields.
- SGR 6 enables blink, 21 selects double underline, and 28 clears conceal.

| Gate | Baseline | Candidate |
| --- | --- | --- |
| 33 focused Rust ABI style cases | 30 differences; 3 valid controls pass | 33/33 exact |
| 16 basic/bright/256/RGB/palette/query cases | 3 known edge differences | 16/16 exact |
| Mandatory emulator tests | New reset regression fails | Pass; includes 33 direct/legacy snapshot checks |
| Semantic regression oracle | — | Pass |

Read-only independent review: CLEAR. No GUI, installation, release, or performance claim.

Evidence is self-contained at `/Users/helge/.codex/artifacts/terminal-sgr-parity-919`: archived source, replay runners/binaries, input fixtures, raw snapshots/replies, build/test logs, and hash manifest. `oracles.rb` reproduces the baseline or accepts the candidate replay path; `normal-colors.rb` checks all normal-color values and reply bytes.

The [raw evidence archive](raw-evidence.tar.gz) has SHA-256 `2152f65293d8724ba3476732a242e23efd8b85998186c1d9a37b0a1e63aaafb8`. The [manifest](manifest.json) pins each retained input and output.
