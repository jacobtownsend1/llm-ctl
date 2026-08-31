# custom — you supply the argv.
#
# For an engine with no backend file yet, or a one-off. Set CMD=() in the conf
# to the argv to run inside the image. These placeholders are substituted:
#
#   {model}   what the engine should load (container path, or hub id)
#   {port}    the port to listen on inside the container
#   {name}    the model's name
#   {mount}   where the weights are mounted, if they are
#
# Nothing else is added, so the command must bind 0.0.0.0:{port}.
#
#   BACKEND=custom
#   IMAGE="my/engine:latest"
#   DIR="$LLM_HOME/models/thing"
#   CMD=(my-server --model "{model}" --listen "0.0.0.0:{port}")
#
# If you find yourself repeating one, promote it to a backend file — see
# docs/backends.md; it is about fifteen lines.
backend_describe() { printf 'run a command you specify (CMD= in the conf)'; }
backend_defaults() { BACKEND_ARGS=(); }

backend_command() {
  [ ${#CMD[@]} -gt 0 ] || die "$MODEL_NAME.conf: BACKEND=custom needs CMD=()"
  local a
  BACKEND_CMD=()
  for a in "${CMD[@]}"; do
    a=${a//\{model\}/$MODEL_TARGET}
    a=${a//\{port\}/$PORT_IN}
    a=${a//\{name\}/$MODEL_NAME}
    a=${a//\{mount\}/$MODEL_MOUNT}
    BACKEND_CMD+=("$a")
  done
}
