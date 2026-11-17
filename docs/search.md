# Search and headless interaction

`TerminalSession.search(_:options:completion:)` and
`HeadlessTerminal.beginSearch(_:options:)` use the same streaming engine.
`TerminalSearchOptions` controls case sensitivity, whole-word matching and
bounded regex matching. The find bar exposes these as **Aa**, **W** and **.***.

Literal matching defaults to case-insensitive Unicode scalar lowercase mapping
using the engine's pinned Unicode tables. It does not normalize text or apply
locale-sensitive collation. A word consists of Unicode letters, numbers,
combining marks and underscore. Soft-wrapped rows join without a newline;
hard row boundaries contribute a newline. Matching works across history and
screen rows, including wide characters and composed cell text.

## Bounded regex syntax

The regex toggle is labelled **Bounded regex (shortest nonempty matches)**.
This deliberately small syntax supports concatenated literal scalars, `.`,
`[abc]`, `[a-z]`, `[^a-z]`, `?`, `*`, `+`, leading `^` and trailing `$`.
Anchors describe hard lines; dot excludes newline. `\n`, `\r`, `\t` and
backslash-escaped punctuation are supported. Case-insensitive class endpoints
and regex atoms must lowercase to exactly one scalar. Unsupported syntax,
including groups, alternation, counted repetition, lookaround, backreferences
and shorthand classes such as `\w`, is rejected as `invalidQuery`.

Matches are nonempty, nonoverlapping, and accepted at the earliest ending
position, using the oldest viable start there. Thus `a+` finds each `a`
separately, and `a.*b` stops at the first `b`. This is **not a general-purpose
PCRE/ICU replacement** and does not promise greedy leftmost semantics.

The implementation is a streaming finite-state machine, with at most 256
states and 128 ranges per class. It never uses a backtracking regex engine.
Each worker turn processes at most 64 input scalars or empty/continuation
cells. Each call performs bounded work, including for adversarial patterns.
Active matches may consume at most 4096 scalars. An active path that would
exceed this bound returns `resourceLimit`, rather than silently skipping it.
The owner admits one immutable row at a time; the worker retains no terminal
or history references.

All modes accept 1–4096 UTF-8 query bytes. Rows above 16 MiB and cell strings
above 4096 UTF-8 bytes fail with `resourceLimit`. At most the newest 10,000
matches are retained; `capped` makes this visible. Match proof storage has a
65,536-row-span bound, beyond which the operation reports `resourceLimit`.
Cancellation takes effect between bounded steps. Row identities, revisions,
soft-wrap successor identities and boundary proofs are checked before results
are accepted; rewritten or evicted output never becomes an unrelated hit.

## Headless use

`beginSearch` returns `.working` or an admission error. Call `advanceSearch`
until it returns a terminal result; each advance performs at most one worker
step. `cancelSearch` retires an in-flight task. `searchPosition` and
`navigateSearch(older:)` inspect and navigate accepted results, while
`clearSearch` also removes their decorations. Navigation changes the engine's
viewport; read it with `currentScreen()` without resetting the scroll offset.
Screen values expose both current-match and all-match highlight segments.

For selection, obtain opaque proof-bearing endpoints with
`screen.selectionPoint(row:column:)`, then call
`select(from:to:rectangular:)`. The range is half-open. Repeat
`advanceSelection` while it returns `.pending`. Read the resulting
`screen.selection`, and pass that value to `copySelection` to request a copy
of exactly its revision. Copy uses the same engine implementation, wide-cell
rules, soft-wrap joins, content-change checks, 65,536-row selection limit and
16 MiB copy limit as the windowed terminal. Clear it with `clearSelection`.
Feeding bytes or resizing cancels pending selection work before mutation.

A headless instance and all its operations remain confined to one caller
thread or queue at a time. Hosts choose when to advance and can schedule those
calls without occupying a UI event loop for the whole history scan. State
serialization is not part of this API.
