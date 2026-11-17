# fish runs --init-command after personal configuration, including for login
# shells. Events preserve the user's handlers and their prompt function.
status is-interactive; or return
set -q _HELGE_TERMINAL_FISH_INSTALLED; and return
set -g _HELGE_TERMINAL_FISH_INSTALLED 1
function _helge_terminal_directory
    printf '\e]7;file://localhost%s\a' (string escape --style=url -- $PWD | string replace -a '%2F' '/')
end
function _helge_terminal_prompt --on-event fish_prompt
    _helge_terminal_directory
    printf '\e]133;A\a'
end
function _helge_terminal_preexec --on-event fish_preexec
    printf '\e]133;C\a'
end
function _helge_terminal_postexec --on-event fish_postexec
    set -l command_status $status
    printf '\e]133;D;%s\a' $command_status
end
if not functions -q fish_prompt
    function fish_prompt
        printf '> '
    end
end
functions --copy fish_prompt _helge_terminal_original_prompt
function _helge_terminal_status
    return $argv[1]
end
function fish_prompt
    set -l command_status $status
    _helge_terminal_status $command_status
    _helge_terminal_original_prompt
    printf '\e]133;B\a'
end
