# Helge Terminal detection fixture

This patch targets Snacks commit
`882c996cf28183f4d63640de0b4c02ec886d01f2`. It adds a Helge entry to the
[upstream environment table](https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/lua/snacks/image/terminal.lua),
using XTVERSION's `HelgeTerminal` name or the existing `TERM_PROGRAM` value.
It does not identify Helge as Kitty. Upstream acceptance is separate work.

Use a disposable clone at the pinned commit, apply `helge-terminal.patch`
with `git apply`, and set `HELGE_SNACKS_CHECKOUT` to that clone's absolute
path. Start Neovim **inside an isolated Helge validation app** with this
fixture as its config and the repository's PNG as its file:

```console
nvim -u /absolute/repo/Tests/Fixtures/Snacks/init.lua -i NONE -n /absolute/repo/assets/AppIcon.png
```

Unset `SNACKS_KITTY`, `SNACKS_GHOSTTY`, `SNACKS_WEZTERM` and `SNACKS_HELGE`
before starting. `image.force` remains false. The fixture reports the actual
detected identity/environment and confirms the ordinary image-buffer path.
Inspect `:lua =vim.g.helge_snacks_result`; optionally set
`HELGE_SNACKS_REPORT` to an explicit file under the run's ignored `reports/`
directory to retain JSON. A true `passed` field establishes detection and
startup only; inspect the actual image before claiming rendered correctness.

Repeat directly and inside a private tmux server with passthrough enabled,
first with its normal key defaults, then with extended keys enabled. Keep
each server/config isolated from the user's tmux state. Test SSH separately
where a server is available: the remote shell may not receive `TERM_PROGRAM`,
so confirm the XTVERSION reply traverses the transport. The fixture deliberately
does not override terminal identity, force support, alter user config or
submit changes upstream.

Retain the source commit, frozen bundle hash, Neovim/Snacks/tmux versions,
the JSON and a compact visual result according to `reports/README.md`.
The direct native run passed detection and visual inspection on 2026-11-17;
see the [dated evidence](../../../reports/gap-implementation-2026-11-17/README.md).
The private tmux and SSH variants remain separate qualification.
