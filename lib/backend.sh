#!/usr/bin/env bash
# backend.sh — the plugin layer.
#
# A backend is one shell file that says how to launch a serving engine. Drop a
# file in $LLMCTL_HOME/backends/<name>.sh and `BACKEND=<name>` works; a file
# there shadows a shipped backend of the same name, so you can adjust one
# without forking the tool. Nothing in the core knows the name of any engine.
#
# A backend may define these. Each has a default (below), so a minimal backend
# is just backend_command.
#
#   backend_describe    -> print a one-line summary for `llm-ctl backends`
#   backend_defaults    -> set BACKEND_ARGS=()      flags every model gets
#   backend_command     -> set BACKEND_CMD=()       argv run inside the image
#   backend_run_args    -> set BACKEND_RUN_ARGS=()  extra runtime flags
#   backend_health_path -> print the readiness path (default /v1/models)
#
# When those run, they can read: MODEL_NAME, MODEL_TARGET (what the engine
# should load — a container path or a hub id), MODEL_MOUNT (container mount
# point of DIR, empty for HF_MODEL), SERVED_NAME, PORT_IN, BIND, plus every
# key the model's conf set.

BACKEND_CONTRACT=(backend_describe backend_defaults backend_command
                  backend_run_args backend_health_path)

backend_dirs() {
  [ -d "$LLMCTL_HOME/backends" ] && printf '%s\n' "$LLMCTL_HOME/backends"
  printf '%s\n' "$LLMCTL_LIBEXEC/backends"
}

backend_file() {
  local name=$1 d
  while IFS= read -r d; do
    [ -f "$d/$name.sh" ] && { printf '%s' "$d/$name.sh"; return 0; }
  done < <(backend_dirs)
  return 1
}

backend_exists() { backend_file "$1" >/dev/null; }

backend_names() {
  local d f
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    for f in "$d"/*.sh; do [ -e "$f" ] || continue; basename "$f" .sh; done
  done < <(backend_dirs) | sort -u
}

# Reset the contract to its defaults, then let the backend override.
backend_load() {
  local name=$1 file fn
  file=$(backend_file "$name") || die "unknown backend: $name (llm-ctl backends)"
  for fn in "${BACKEND_CONTRACT[@]}"; do unset -f "$fn" 2>/dev/null; done

  backend_describe()    { printf '%s' "(no description)"; }
  backend_defaults()    { BACKEND_ARGS=(); }
  backend_command()     { die "backend '$BACKEND' defines no backend_command"; }
  backend_run_args()    { BACKEND_RUN_ARGS=(); }
  backend_health_path() { printf '/v1/models'; }

  # shellcheck disable=SC1090
  source "$file" || die "failed to load backend: $file"
  BACKEND_FILE=$file
}
