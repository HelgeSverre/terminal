# Source after personal configuration. Works with macOS Bash 3.2 as well as
# newer Bash; never replaces a user's DEBUG trap or prompt command.
[[ $- == *i* && ${_HELGE_TERMINAL_BASH_INSTALLED-} != 1 ]] || return
# A readonly prompt is an explicit ownership choice. Leave it alone.
for _helge_terminal_variable in PS1 PROMPT_COMMAND; do
  _helge_terminal_declaration=$(declare -p "$_helge_terminal_variable" 2>/dev/null)
  _helge_terminal_flags=${_helge_terminal_declaration#declare -}
  [[ ${_helge_terminal_flags%% *} == *r* ]] && return
done
unset _helge_terminal_variable _helge_terminal_declaration _helge_terminal_flags
_HELGE_TERMINAL_BASH_INSTALLED=1
_HELGE_TERMINAL_BASH_RUNNING=1
_HELGE_TERMINAL_BASH_COMMAND=0

_helge_terminal_directory() {
  local LC_ALL=C encoded='' byte i
  for ((i=0; i<${#PWD}; i++)); do
    byte=${PWD:i:1}
    case $byte in
      [a-zA-Z0-9/._~-]) encoded+=$byte ;;
      *) printf -v byte '%%%02X' "'$byte"; encoded+=$byte ;;
    esac
  done
  printf '\e]7;file://localhost%s\a' "$encoded"
}
_helge_terminal_prompt() {
  local command_status=$?
  _HELGE_TERMINAL_BASH_RUNNING=1
  if [[ $_HELGE_TERMINAL_BASH_COMMAND == 1 ]]; then
    printf '\e]133;D;%s\a' "$command_status"
  fi
  _HELGE_TERMINAL_BASH_COMMAND=0
  _helge_terminal_directory
  printf '\e]133;A\a'
  return "$command_status"
}
_helge_terminal_ready() {
  local command_status=$?
  # Readline must see the marker as zero-width. Keep all user prompt text,
  # including dynamic prompt-command assignments, untouched before it.
  local marker='\[\e]133;B\a\]'
  [[ $PS1 == *"$marker" ]] || PS1+=$marker
  _HELGE_TERMINAL_BASH_RUNNING=0
  return "$command_status"
}
_helge_terminal_debug() {
  local command_status=$?
  if [[ $_HELGE_TERMINAL_BASH_RUNNING == 0 && $BASH_COMMAND != _helge_terminal_prompt* && ${FUNCNAME[1]-} != _helge_terminal_* ]]; then
    printf '\e]133;C\a'
    _HELGE_TERMINAL_BASH_COMMAND=1
    _HELGE_TERMINAL_BASH_RUNNING=1
  fi
  return "$command_status"
}
# Existing DEBUG ownership wins. Bash 4.4+ has PS0 for preexec without traps.
if [[ -z $(trap -p DEBUG) ]]; then
  trap '_helge_terminal_debug' DEBUG
elif (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  PS0+='\e]133;C\a'
  # PROMPT_COMMAND cannot distinguish an empty input from an executed command
  # without a preexec hook. Report completion at the next prompt in this case.
  _helge_terminal_ready() {
    local command_status=$? marker='\[\e]133;B\a\]'
    [[ $PS1 == *"$marker" ]] || PS1+=$marker
    _HELGE_TERMINAL_BASH_COMMAND=1
    return "$command_status"
  }
fi
if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) =~ ^declare\ -[^[:space:]]*a ]]; then
  PROMPT_COMMAND=(_helge_terminal_prompt "${PROMPT_COMMAND[@]}" _helge_terminal_ready)
else
  # Newlines, not semicolons: a value ending in ";" would otherwise form ";;".
  PROMPT_COMMAND="_helge_terminal_prompt${PROMPT_COMMAND:+
$PROMPT_COMMAND}
_helge_terminal_ready"
fi
