# OSC 133 is semantic metadata only. Existing prompt and ZLE hooks keep ownership
# of rendering/editing; no prompt strings or user configuration are replaced.
autoload -Uz add-zsh-hook add-zle-hook-widget
[[ ${_HELGE_TERMINAL_ZSH_INSTALLED-} == 1 ]] && return
typeset -g _HELGE_TERMINAL_ZSH_INSTALLED=1
typeset -g _HELGE_TERMINAL_ZSH_COMMAND=0
function _helge_terminal_report_directory() {
  local LC_ALL=C
  local encoded="" byte
  for byte in ${(s::)PWD}; do
    case "$byte" in
      [a-zA-Z0-9/._~-]) encoded+="$byte" ;;
      *) printf -v byte '%%%02X' "'$byte"; encoded+="$byte" ;;
    esac
  done
  printf '\e]7;file://localhost%s\a' "$encoded"
}
function _helge_terminal_precmd() {
  local command_status=$?
  if [[ $_HELGE_TERMINAL_ZSH_COMMAND == 1 ]]; then
    printf '\e]133;D;%s\a' "$command_status"
  fi
  _HELGE_TERMINAL_ZSH_COMMAND=0
  _helge_terminal_report_directory
  printf '\e]133;A;redraw=1\a'
  # A nonzero hook return prevents later user precmd hooks from running.
  return 0
}
function _helge_terminal_preexec() { _HELGE_TERMINAL_ZSH_COMMAND=1; printf '\e]133;C\a' }
function _helge_terminal_line_init() { printf '\e]133;B\a' }
add-zsh-hook precmd _helge_terminal_precmd
add-zsh-hook preexec _helge_terminal_preexec
add-zle-hook-widget line-init _helge_terminal_line_init
# Capture $? before user precmd hooks have a chance to change it.
precmd_functions=(_helge_terminal_precmd ${precmd_functions:#_helge_terminal_precmd})
