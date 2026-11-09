# PTY locale-launch evidence

This directory records the already-completed test-first PTY locale check. It is
evidence only: collecting it did not rerun a launcher, build the app, or touch
the installed application.

`red-baseline.md` documents the pre-fix failure and `green-final.md` documents
the isolated post-fix run. The C objects and runner were written under distinct
locale-specific paths (or `/tmp`), rather than replacing the shared app build
object.
