# Input compatibility and icat hold diagnosis — 2026-11-17

Source baseline: `67a34c3` (detached input worktree). Runtime probes below use
the existing external clients, not a newly built Terminal executable. No GUI,
installed Terminal instance, package resolution, build or Swift suite was run
by this worker. `git diff --check` passed before checkpointing the patch.

## C06 implementation awaiting integrated validation

- Xterm `CSI > 4 ; level m` sets modifyOtherKeys levels 0–3; omitted level
  resets to the initial value 0. `CSI ? 4 m` queries it; `CSI > 4 n` disables
  it. Unsupported resources, values and colon masks are ignored. The output
  format is the default `CSI 27 ; modifier ; codepoint ~`; formatOtherKeys and
  modifier-mask resources are not implemented or advertised.
- Kitty negotiation owns input while its flags are nonzero. Repeats retain
  the requested protocol; unrequested releases stay suppressed. Committed IME
  text bypasses physical-key encoding. Native editing shortcuts are retained.
- Mouse encoding modes 1005 (UTF-8), 1006 (SGR cells), 1015 (URXVT) and 1016
  (SGR pixels) are mutually exclusive and queryable. Legacy/UTF-8 coordinate
  limits are enforced. Pixel coordinates use the same backing-pixel content
  grid as PTY size reporting, excluding the inset, with one-based bounds.
  Mode 1001 highlight tracking remains unsupported and reports status 0.
- Tracking resets no longer disable a different active tracking mode. Soft
  and hard resets clear the added modes. Middle-button and right/middle drag
  events now use the same encoder. Shift still reserves local selection.
- Per-side native Option configuration uses AppKit's physical-side flag bits;
  nil inherits the existing policy. If both sides are held, either side set
  to Escape enables Escape behavior. Ambiguous aggregate-only events inherit
  the existing policy. This is synthetic-policy coverage, not physical-keyboard
  qualification.

Focused checks requested after integration:

```sh
just unit-test --filter TerminalInputCompatibilityTests --filter TerminalInputEncoderTests --filter KeyMapTests --filter TerminalSchedulerOracleTests --filter EmulatorTests
```

`TerminalInputCompatibilityTests` covers wire formats, extended-coordinate
limits, scale/inset conversion, resource queries, invalid requests, resets,
Kitty precedence, IME bypass and the recorded hold negotiation bytes. The
suite is authored but has not yet been compiled or executed by this worker.
Native selection smoke and a real pixel-mouse client remain integration checks.
Presentation integration must subtract its fractional viewport offset before
pixel conversion (the presentation worker resets that offset in mouse mode).

## V01 isolated in the client legacy-input path

Environment: macOS 15.6 arm64; `tmux -V`: `tmux 3.7c`;
`/Applications/kitty.app/Contents/MacOS/kitten --version`: `kitten 0.45.0`.
SHA-256:

- kitten: `062ab81e2f2ed2bf29cbb27849611826782037c4f3ab805b7c8ed8d758859188`
- tmux: `6a9a68532c31a72ac822481da8879ae413f158d7a2b07c50d96126012336afe0`

The headless PTY command (80×24 cells, 800×480 pixels) was:

```sh
/Applications/kitty.app/Contents/MacOS/kitten icat --hold --stdin=no --use-window-size=80,24,800,480 --transfer-mode=stream --place=1x1@0x0 --passthrough=none assets/AppIcon.png
```

After the hold prompt, its output requested `CSI > 29 u`. Sending raw CR
(`0d`), Escape (`1b`) and Ctrl-C (`03`) separately, with one second of
observation after each, left the process running. Sending `CSI 13;1u`
(`1b 5b 31 33 3b 31 75`) then exited immediately with status 0 and emitted
the normal keyboard pop/terminal-state cleanup. This reproduces the symptom
without Helge Terminal or tmux in the process path.

A private `tmux -L helge-gap-input-20261117 -f /dev/null -vv` server ran the
same command with `--passthrough=tmux` and an absolute image path. Its default
`extended-keys off` was queried. An attached headless PTY delivered Enter;
the viewer remained running. The server log captured `writing key 0xd (Enter)`
and `input_key: \\r`. Sending the literal CSI key with
`tmux -L helge-gap-input-20261117 send-keys -t input -l $'\e[13;1u'`
exited the viewer/session normally. Raw logs remain ignored local artifacts.

Two additional private servers used `extended-keys on` and `always`, both
with `extended-keys-format csi-u`. `on` was exercised with separate semantic
`send-keys Enter`, `Escape`, and `C-c` invocations: the pane remained `kitten`
after each. The `always` attached PTY also remained in hold after raw input.
Literal CSI Enter exited both normally. Thus merely enabling tmux's extended
key settings was not demonstrated to fix this client. Every owned viewer,
client and private server exited; no unrelated tmux server was touched.

The byte comparison aligns with the pinned upstream sources:

- [kitten 0.45.0 HoldTillEnter](https://github.com/kovidgoyal/kitty/blob/v0.45.0/tools/tui/hold.go)
  installs an `OnKeyEvent` callback, with no `OnText` callback.
- [kitten 0.45.0 input loop](https://github.com/kovidgoyal/kitty/blob/v0.45.0/tools/tui/loop/run.go)
  delivers CSI key sequences to key events, while `handle_rune` delivers raw
  characters only to `OnText`. The raw characters therefore do not reach
  hold's exit-key callback. Current master retains this separation.
- [tmux 3.7c input dispatch](https://github.com/tmux/tmux/blob/3.7c/input.c)
  and [key encoding](https://github.com/tmux/tmux/blob/3.7c/input-keys.c)
  support xterm extended-key modes but do not negotiate Kitty's all-key flag
  for the inner client. The client emits `CSI > 29 u`; changing tmux's xterm
  option does not add that missing negotiation.

Disposition: a client/multiplexer compatibility limitation, not evidence of
an incorrect native Enter/Escape/Control-C encoding in this terminal. Direct
Kitty negotiation must continue producing CSI keys; an unnegotiated tmux path
must continue producing its expected legacy bytes. A practical workaround is
to omit `--hold` in tmux and use the shell's own read prompt if a pause is
needed, or use direct icat. No upstream issue was filed by this worker.

Protocol references: [maintained xterm controls](https://github.com/ThomasDickey/xterm-snapshots/blob/master/ctlseqs.txt)
and [xterm key handling](https://github.com/ThomasDickey/xterm-snapshots/blob/master/input.c).
