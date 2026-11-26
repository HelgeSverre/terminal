# Shell integration

The signed application carries these resources. Embedding hosts can copy this
directory next to their launcher's `../Resources` directory or set
`LaunchSpec.shellIntegrationDirectory` to its absolute path. Resource discovery
never reads the embedding application's main bundle. Missing resources leave
the shell's normal launch intact.

Ordinary interactive zsh launches, including `-l`, read the user's original
startup files and install hooks without changing their files. Ordinary
nonlogin Bash launches use `--rcfile bash/rc.bash`, which sources `~/.bashrc`
before installing hooks. fish uses `--init-command` after its normal
configuration, preserving login behavior. Explicit commands and startup flags
are left as supplied by the host.

Bash login shells retain native login semantics. Bash provides no post-startup
hook for a terminal to inject after login profiles, and `--rcfile` is not read
by a login shell. Users can choose a nonlogin Bash launch profile or explicitly
source `bash/hooks.bash` at the end of their own login configuration. The
terminal never writes that configuration. Bash keeps existing `PROMPT_COMMAND`
entries and DEBUG traps. A readonly prompt disables integration. With an existing
DEBUG trap, Bash 4.4+ uses PS0; Bash 3.2 preserves that trap and reports prompt
and directory markers without command-start/exit metadata.

OSC 7 reports a percent-encoded local directory URI. OSC 133 marks the prompt
(A), input (B), command start (C), and completion with exit status (D). Prompt
text and existing shell hooks remain owned by the user. Shell output is
untrusted: markers are navigation metadata and do not authorize execution.

Previous Command and Next Command in the terminal context menu navigate retained
command boundaries. Embedding hosts can call `navigateCommand(older:)` and query
`commandHistory`. History retains at most 512 records; navigation skips rows
that scrollback eviction or reflow has removed. No shell command text is stored
or automatically replayed.
