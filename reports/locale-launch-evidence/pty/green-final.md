# Final GREEN receipt

Exit status: `0`.

This was a direct isolated C/Swift test runner execution; it did not build or
launch the application UI and did not overwrite the shared `Spawn.o`.

```text
xcrun clang -Wall -Wextra -Werror -I native -c native/tests/pty.c \
  -o target/native/locale-pty-green.o
xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h \
  $(xcrun swift tools/SwiftIncrementalBuild.swift --print pty) \
  target/native/locale-pty-green.o /tmp/terminal-locale-spawn.o \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -framework CoreFoundation -framework Security -liconv \
  -o target/native/locale-pty-green
target/native/locale-pty-green \
  "$PWD/dist/Terminal.app/Contents/MacOS/TerminalLauncher"
```

The final runner printed PASS for these actual PTY child cases:

```text
LANG=<default>, LC_ALL=, LC_CTYPE=, CODESET=UTF-8
LANG=<default> (empty parent LANG), LC_ALL=, LC_CTYPE=, CODESET=UTF-8
LANG=en_US.UTF-8, CODESET=UTF-8
LANG=C, CODESET=US-ASCII
LANG=en_US.UTF-8, LC_ALL=C, CODESET=US-ASCII
LANG=en_US.UTF-8, LC_CTYPE=C, CODESET=US-ASCII
```

Each test asserts exactly one child `LANG`, preserves explicitly supplied
`LANG`, leaves `LC_ALL`/`LC_CTYPE` present for locale precedence, observes the
child codeset, verifies the test parent's three locale variables remain
unchanged across spawn, and waits for child reaping/EOF. The existing PTY
corpus also passed: cwd/TTY, final-output drain, exec and cwd error paths, env,
bash, fish, nvim, tmux, and fzf.

| item | SHA-256 |
| --- | --- |
| final `native/Spawn.c` | `b4b32e7d9d592ce47cec4767afc0220d4209926a04f8f3708e236b76ded995d6` |
| final `native/tests/pty.c` | `556b0425012595064b2ec4c68e421889b46fcdac1ef0f5c03a31408868a512d4` |
| `/tmp/terminal-locale-spawn.o` | `90d65433ea77b738d1eb4049a3dffbf07088458d56239f53ab57f397812c44a7` |
| `target/native/locale-pty-green.o` | `6674f230980400d827e80150fcf6999696c432913d3006ea39bd703dfc35d920` |
| `target/native/locale-pty-green` | `0fe43d2a535a0544d25ead1670d77e6b5ab6f0b788df80525f13eebe458a087a` |

No raw green output was saved during the completed run. The listed PASS cases,
exit status, commands, and file hashes are the preserved receipt.
