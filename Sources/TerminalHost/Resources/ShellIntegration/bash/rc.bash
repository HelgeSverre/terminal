# Bash reads this only for an ordinary, nonlogin interactive launch.
# Login shells retain Bash's native startup contract; see README.md.
_HELGE_TERMINAL_BASH_HOOKS="$HELGE_TERMINAL_INTEGRATION_DIRECTORY/bash/hooks.bash"
[[ -r ~/.bashrc ]] && source ~/.bashrc
source "$_HELGE_TERMINAL_BASH_HOOKS"
unset _HELGE_TERMINAL_BASH_HOOKS
