# bash completion for llm-ctl.  eval "$(llm-ctl completion bash)"
_llmctl() {
  local cur prev cmds
  cur=${COMP_WORDS[COMP_CWORD]}
  prev=${COMP_WORDS[COMP_CWORD-1]}
  cmds="ls start stop restart status logs config wait url env new edit lint backends doctor completion help version"

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$cmds" -- "$cur")); return
  fi
  case "$prev" in
    start|stop|restart|logs|config|wait|url|env|edit|lint)
      COMPREPLY=($(compgen -W "$(llm-ctl ls --json 2>/dev/null | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')" -- "$cur")) ;;
    completion) COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur")) ;;
    *) COMPREPLY=($(compgen -W "--yes --quiet --json --debug --no-color --home --port" -- "$cur")) ;;
  esac
}
complete -F _llmctl llm-ctl
