source "$_HELGE_TERMINAL_DIR/restore.zsh"
if [[ -r "${ZDOTDIR-$HOME}/.zshrc" ]]; then
  source "${ZDOTDIR-$HOME}/.zshrc"
fi
if [[ -o interactive ]]; then
  source "$_HELGE_TERMINAL_DIR/hooks.zsh"
fi
unset _HELGE_TERMINAL_DIR _HELGE_TERMINAL_SAVED_SET _HELGE_TERMINAL_SAVED_ZDOTDIR _HELGE_TERMINAL_SAVED_EXPORT
