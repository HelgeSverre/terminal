# Pre-fix RED receipt

Status: failing as expected (nonzero assertion exit). The original raw process
log was not retained; this is the contemporaneous structured observation from
the isolated actual-PTY run, not a reconstructed rerun.

Observed child output before the assertion:

```text
locale PTY mismatch: LOCALE LANG=<> LC_ALL=<> LC_CTYPE=<> LANG_COUNT=0
 CODESET=US-ASCII
```

The test unset `LANG`, `LC_ALL`, and `LC_CTYPE` only in its own runner process,
then launched `/bin/sh` through `terminal_spawn_args`. It waited for master and
status EOF and child reaping before inspecting the output. Therefore the
failure establishes both the missing child default `LANG` and non-UTF-8
effective child codeset in the pre-fix launch path.

The red compilation used a separate object:

```text
xcrun clang -Wall -Wextra -Werror -I native -c native/Spawn.c \
  -o target/native/locale-pty-spawn-red.o
```

The runner was then linked with that object and executed with the already-built
`dist/Terminal.app/Contents/MacOS/TerminalLauncher`. It did not run an app
build or replace `target/native/Spawn.o`.

Source identities:

| item | SHA-256 |
| --- | --- |
| pre-fix `native/Spawn.c` content (`HEAD:native/Spawn.c`) | `9ffb179cb879cdc54c7a952398f205c9ab46dad799f91d5dc5ed00a43759c3dc` |
| pre-fix `native/tests/pty.c` content (`HEAD:native/tests/pty.c`) | `6814acead3772dff96db2d7a6e106ff4f67e4acdc9d22baa47187130bb891d69` |

The temporary red runner source/object receipt was not retained, so no hash is
claimed for it. Its only purpose was to make this failure visible before the
production patch.
