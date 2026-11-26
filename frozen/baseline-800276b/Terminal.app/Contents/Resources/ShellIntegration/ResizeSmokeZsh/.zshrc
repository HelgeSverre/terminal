# Self-contained resize fixture: no user shell files or history participate.
HISTFILE=/dev/null
HISTSIZE=0
SAVEHIST=0
export STARSHIP_CONFIG="$ZDOTDIR/starship.toml"
eval "$(starship init zsh)"

autoload -Uz add-zle-hook-widget add-zsh-hook
function _helge_resize_fixture_precmd() { printf '\e]133;D\a\e]133;A;redraw=1\a' }
function _helge_resize_fixture_preexec() { printf '\e]133;C\a' }
typeset -g _helge_resize_fixture_seeded=0
function _helge_resize_fixture_line_init() {
  printf '\e]133;B\a'
  if (( ! _helge_resize_fixture_seeded )); then
    BUFFER='RESIZE_BUFFER'
    CURSOR=${#BUFFER}
    _helge_resize_fixture_seeded=1
  fi
}
# Keep the redraw contract deterministic while still letting Starship render
# the actual prompt; production shells may install their own WINCH behavior.
function TRAPWINCH() {
  if zle; then
    zle reset-prompt
  fi
}
add-zsh-hook precmd _helge_resize_fixture_precmd
add-zsh-hook preexec _helge_resize_fixture_preexec
add-zle-hook-widget line-init _helge_resize_fixture_line_init
function _helge_resize_fixture_right_prompt() { :; }
setopt prompt_subst
RPROMPT="${RPROMPT}"'$(_helge_resize_fixture_right_prompt)'
