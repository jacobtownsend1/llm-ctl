#compdef llm-ctl
# zsh completion for llm-ctl.  eval "$(llm-ctl completion zsh)"
_llmctl_models() {
  local -a m
  m=(${(f)"$(llm-ctl ls 2>/dev/null | awk 'NR>1 && $1 !~ /^$/ {print $1}')"})
  _describe 'model' m
}
_llmctl() {
  local -a cmds
  cmds=(
    'ls:list every model you have defined'
    'start:start a model and wait until it answers'
    'stop:stop what is running'
    'restart:restart or switch model'
    'status:what is up right now'
    'logs:logs of a model'
    'config:print the command start would run'
    'wait:block until the server answers'
    'url:print the OpenAI base URL'
    'env:print shell exports for OpenAI clients'
    'new:scaffold a model definition'
    'edit:edit a model definition'
    'lint:check definitions for mistakes'
    'backends:serving engines available here'
    'doctor:check this machine can run a model'
    'completion:print a completion script'
    'help:usage, or `help conf` for the schema'
  )
  if (( CURRENT == 2 )); then _describe 'command' cmds; return; fi
  case ${words[2]} in
    start|stop|restart|logs|config|wait|url|env|edit|lint) _llmctl_models ;;
    completion) _values 'shell' bash zsh fish ;;
  esac
}
_llmctl "$@"
