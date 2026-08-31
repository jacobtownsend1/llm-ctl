# fish completion for llm-ctl.  llm-ctl completion fish | source
function __llmctl_models
    llm-ctl ls 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}'
end
set -l cmds ls start stop restart status logs config wait url env new edit lint backends doctor completion help version

complete -c llm-ctl -f
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a ls        -d "list every model you have defined"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a start     -d "start a model and wait until it answers"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a stop      -d "stop what is running"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a restart   -d "restart or switch model"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a status    -d "what is up right now"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a logs      -d "logs of a model"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a config    -d "print the command start would run"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a doctor    -d "check this machine can run a model"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a new       -d "scaffold a model definition"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a lint      -d "check definitions for mistakes"
complete -c llm-ctl -n "not __fish_seen_subcommand_from $cmds" -a backends  -d "serving engines available here"
complete -c llm-ctl -n "__fish_seen_subcommand_from start stop restart logs config wait url env edit lint" -a "(__llmctl_models)"
complete -c llm-ctl -n "__fish_seen_subcommand_from completion" -a "bash zsh fish"
complete -c llm-ctl -l yes -s y -d "do not ask before stopping a running model"
complete -c llm-ctl -l json -d "machine-readable output"
complete -c llm-ctl -l quiet -s q -d "only errors"
