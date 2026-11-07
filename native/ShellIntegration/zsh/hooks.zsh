# OSC 133 is semantic metadata only. Existing prompt and ZLE hooks keep ownership
# of rendering/editing; no prompt strings or user configuration are replaced.
autoload -Uz add-zsh-hook add-zle-hook-widget
function _helge_terminal_precmd() { printf '\e]133;D\a\e]133;A\a' }
function _helge_terminal_preexec() { printf '\e]133;C\a' }
function _helge_terminal_line_init() { printf '\e]133;B\a' }
add-zsh-hook precmd _helge_terminal_precmd
add-zsh-hook preexec _helge_terminal_preexec
add-zle-hook-widget line-init _helge_terminal_line_init
