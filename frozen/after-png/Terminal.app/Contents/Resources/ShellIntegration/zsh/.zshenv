# Restore and source the user's files at top level, preserving typeset semantics.
typeset -g _HELGE_TERMINAL_DIR="$ZDOTDIR"
typeset -g _HELGE_TERMINAL_SAVED_ZDOTDIR="$HELGE_TERMINAL_ORIGINAL_ZDOTDIR"
typeset -g _HELGE_TERMINAL_SAVED_SET="$HELGE_TERMINAL_ZDOTDIR_SET"
typeset -g _HELGE_TERMINAL_SAVED_EXPORT=export
source "$_HELGE_TERMINAL_DIR/restore.zsh"
unset HELGE_TERMINAL_ORIGINAL_ZDOTDIR HELGE_TERMINAL_ZDOTDIR_SET
if [[ -r "${ZDOTDIR-$HOME}/.zshenv" ]]; then
  source "${ZDOTDIR-$HOME}/.zshenv"
fi
if [[ -o interactive && -o rcs ]]; then
  source "$_HELGE_TERMINAL_DIR/save.zsh"
fi
