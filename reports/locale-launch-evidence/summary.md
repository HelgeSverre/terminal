# UTF-8 locale for desktop launches

Command-line duplication is reproducible with the old 0.2.0 runtime when
`LANG`, `LC_ALL` and `LC_CTYPE` are absent. With the same
runtime, geometry, font and paced AppKit events, setting a UTF-8 `LANG` removes
the duplication. The clean paired receipts cover three controlled rounds per
environment. Earlier potentially interfered captures are excluded.

Those initial paired captures did not independently assert the shell's working
directory or require the Crescat completion list. They establish a locale-related
redisplay failure, but do not validate the exact reported directory-completion
case. A later home-directory run was also excluded after Helge identified that
completion could not fire there. Corrected native validation must verify
`/Users/helge/code` and actual completion-directory tokens.

The corrected pair in `native-cwd/` now meets those prerequisites. Old 0.2.0
duplicates `cd` in all three rounds; frozen 0.2.2 duplicates it in none. Both
verify the actual shell PWD with a controlled `pwd`, require `crescat-app` and
`crescat-printer` in the completion list, and check the extended `cd crescat`
prefix. Each records 80 expected synthetic events, zero foreign input events,
the exact live canvas/window/first-responder destination, and no surviving owned
processes. These are targeted AppKit events, not physical keyboard proof;
foreground activation is recorded separately from event destination validity.

The missing locale leaves zsh using ASCII character classification while the
terminal interprets UTF-8. This makes Unicode prompt-width calculations disagree
and corrupts completion redisplay. The problem is visible in AX text as well as
the screenshot; it is not solely a glyph-presentation artifact.

`Spawn.c` now supplies a child-only `LANG` default when none is set. It derives
the language/country from macOS, validates that locale independently, and falls
back to the installed `en_US.UTF-8` locale if necessary. This host's `en_NO`
preference exercises that fallback. Nonempty inherited `LANG` values and every
`LC_*` override are preserved; the child receives exactly one `LANG` entry.
No application-global locale, user shell configuration or settings are changed.

This default applies to both interactive shells and explicit commands, covering
the underlying Unicode startup problem beyond this particular completion text.
[Ghostty's locale initialization](https://github.com/ghostty-org/ghostty/blob/main/src/os/locale.zig)
also accounts for missing `LANG` during macOS GUI launches. Its process-global
mutation is not used here.

## Evidence

- `provenance.json` distinguishes the original notarized 0.2.0 binary from the
  private diagnostic re-signed copy. The Mach-O UUID matches; signatures differ.
- The two `ui-020-*` receipts show clean no-locale red versus UTF-8 green. These
  inject AppKit events and are not physical HID proof. Raw AX text was not saved.
- `pty/` records the real spawn-path red/green test and the full existing PTY
  corpus. Defaults, explicit overrides, effective codesets, one-entry LANG,
  unchanged parent environment, output drain and child reaping are covered.
- `candidate-source-and-bundle.json` and `build.log` identify the optimized
  0.2.2/build 7 development candidate, not a signed/notarized installation.

The invalid headless wrapper attempts are not counted as product evidence.
The new candidate's native validation and distribution receipts are tracked
separately before installation.
