if [[ $_HELGE_TERMINAL_SAVED_SET == 1 ]]; then
  typeset -g ZDOTDIR="$_HELGE_TERMINAL_SAVED_ZDOTDIR"
  if [[ $_HELGE_TERMINAL_SAVED_EXPORT == *export* ]]; then
    export ZDOTDIR
  else
    typeset +x ZDOTDIR
  fi
else
  unset ZDOTDIR
fi
