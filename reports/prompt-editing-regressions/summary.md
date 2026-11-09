# Prompt and line-editing regression coverage

The original missing-locale defect and corrected `~/code` native A/B are recorded
in [locale-launch evidence](../locale-launch-evidence/summary.md). Investigation
of adjacent redraw operations also found missing CSI ECH/CNL/CPL support and
incorrect CUU/CUD scrolling-margin bounds with origin mode disabled.

ECH and the older cursor-motion cases were observed failing their new assertions
before their fixes; the focused semantic oracle passes afterward. Vertical
movement now shares one policy matching xterm's directional margin bounds.
See [xterm cursor.c](https://sources.debian.org/src/xterm/379-1/cursor.c/) for
CursorUp, CursorDown, CursorNextLine, CursorPrevLine and CarriageReturn.

## Automated checks

| Command | Contract checked |
| --- | --- |
| `just shell-editing-test` | Actual Session/PTY and isolated `zsh -dfi`, absent parent locale, UTF-8 child locale, temporary project PWD, real two-Tab directory completion, colored Unicode prompt reset with a live buffer, resize, Backspace/retype and interior cursor edits. |
| `just terminal-prompt-clear-oracle` | Every byte split in UTF-8/SGR/OSC 133 redraw streams, correct prompt-before-input marker order, exactly one prompt/command, expected cursor and style, erase/retype, synchronized-output explicit release/watchdog and resize. |
| `just terminal-semantic-regression` | ECH defaults/zero/large counts, background-only erasure, whole-wide-glyph repair from either cell, unmoved cursor, pending-wrap clearing, reflow/byte partitions; A/B/E/F default and margin-bound movement. |
| `just test` | All of the above plus ten actual-PTY locale cases: missing/empty LANG, preserved explicit C/UTF-8, LC_ALL/LC_CTYPE precedence, empty override presence, one LANG entry and unchanged parent environment. |

The shell test uses a fresh numbered ZLE BUFFER/CURSOR sidecar for each edit and
also waits for the exact current rendered line/cursor. It cannot pass from an
echoed readiness command or a stale earlier probe. Its temporary directory has
multiple matching directories, and the shell itself confirms PWD. Cleanup waits
for its owned child to be reaped before the test returns.

Native normal/editing checks and last-window/Cmd-Q fixtures also pass locally.
The normal fixture now explicitly establishes its owned Canvas focus before its
first UI input; a direct launch's first responder alone did not guarantee that
focus precondition. Editing fixtures retain derived prompt/cursor measurements
to distinguish prompt-width errors from incidental input. Native validation is
programmatic AppKit input; it is not physical-keyboard or input-method proof.

The focused tests are registered in the standard `just test`/macOS CI workflow.
The full suite and bundle verification pass at `a8cf4bd` in
[macOS CI run 42605737863](https://github.com/HelgeSverre/terminal/actions/runs/42605737863).
The exact signed 0.2.2/build 8 app also passes all 30 normal and 14 editing
checks plus both closure/reaping fixtures; its verified installation is recorded
in [the distribution receipt](../distribution-0.2.2.json).

## Locale regression control

The same current shell-test source was linked against the pre-locale-fix
`Spawn.c` from `8797cd1` in a private diagnostic executable. With LANG/LC_ALL/
LC_CTYPE absent, that control exits 1 on the real shell's UTF-8 readiness check.
The normal target linked against the fixed spawn implementation exits 0.
Both runs explicitly report `child_reaped=true`; cleanup defers unwind before
the main entry point exits. The bounded red/green logs are saved alongside this
summary. The production source and application bundle were not altered for the
control.
