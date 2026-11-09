# Editing smoke input isolation

A fresh-prompt failure came from external desktop keystrokes entering the smoke
window before its scripted `cd`. No parser or prompt-readiness change was needed.

The [controlled comparison](isolation.json) compiles two private app variants
against the same canonical source graph. Both filter unrelated physical input;
exactly two tagged queued key events reach the comparison boundary. The baseline
omits the smoke's own input filter. The candidate retains it.

| Variant | Initial → typed → erased column | Controlled probes | Result |
| --- | --- | --- | --- |
| Baseline | 4 → 6 → 4 | 2 accepted | Strict prompt alignment fails |
| Candidate | 2 → 4 → 2 | 2 rejected | All editing checks pass |

Both process trees exited with no survivors. The source-input and executable
hashes are in the report. These controlled binaries use Swift 5 mode without
optimization. Separate [development](development.json) and [whole-module release](release.json)
smokes also pass the unchanged strict checks on this Mac (M2 Max, macOS 15.6,
Swift 6.2.4). Only numeric editing state is retained. This is synthetic AppKit
input and ZLE-buffer validation, not physical keyboard/IME conformance.

Reproduce with a built app and a new output directory:

```shell
just editing-input-isolation dist/Terminal.app reports/editing-isolation-next
```

The runner edits temporary source only. No injection setting is added to the
product. Queued AppKit events can be copied, so controlled probes use a unique
future timestamp with key/type/window identity; synchronous fixture events keep
object identity. Input filtering is scoped to the smoke window and removed on
completion or timeout.
