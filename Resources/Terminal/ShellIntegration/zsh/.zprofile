source "$_HELGE_TERMINAL_DIR/restore.zsh"
if [[ -r "${ZDOTDIR-$HOME}/.zprofile" ]]; then
  source "${ZDOTDIR-$HOME}/.zprofile"
fi
if [[ -o interactive && -o rcs ]]; then
  source "$_HELGE_TERMINAL_DIR/save.zsh"
fi
