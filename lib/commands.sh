#!/usr/bin/env bash
# commands.sh — the subcommands, plus the shared machinery they sit on.

# ---- shared -----------------------------------------------------------------

# Which models are up right now, as "name<TAB>container" lines.
#
# Ownership comes from a label llm-ctl sets when it starts a container, so this
# never guesses from a container's name. The one exception is an external
# model, whose container was created and named by its own launcher: that one is
# matched against the CONTAINER_NAME its conf declares, by exact string compare.
running_models() {
  local names labels line n
  names=$(rt_running_names) || return 0
  [ -z "$names" ] && return 0

  # Read the label with `inspect`, not with a ps --format template: in
  # `docker ps` .Labels is one comma-joined string, and the per-runtime
  # accessors for a single label are not portable. .Config.Labels under
  # `inspect` is a map everywhere.
  local c m
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    m=$(rt inspect -f '{{index .Config.Labels "llm-ctl.model"}}' "$c" 2>/dev/null)
    [ -n "$m" ] && printf '%s\t%s\n' "$m" "$c"
  done < <(rt ps --filter "label=llm-ctl.model" --format '{{.Names}}' 2>/dev/null)
  labels=$(rt ps --filter "label=llm-ctl.model" --format '{{.Names}}' 2>/dev/null)

  while IFS= read -r n; do
    [ -z "$n" ] && continue
    load_model "$n" 2>/dev/null || continue
    [ "$BACKEND" = external ] || continue
    while IFS= read -r line; do
      [ "$line" = "$CONTAINER" ] && { printf '%s\t%s\n' "$n" "$line"; break; }
    done <<<"$names"
  done <<<"$(model_names)"
}

# The container actually running this model, or the name we would give it.
# The two differ for an external model, whose launcher chose the name, and
# stopping or reading the logs of the name we would have picked would quietly
# do nothing.
container_for() {
  local name=$1 n c
  while IFS=$'\t' read -r n c; do
    [ "$n" = "$name" ] && { printf '%s' "$c"; return 0; }
  done <<<"$(running_models)"
  printf '%s' "${CONTAINER:-}"
}

# First running model, or empty. Sets RUNNING_MODEL / RUNNING_CONTAINER.
current_model() {
  RUNNING_MODEL=""; RUNNING_CONTAINER=""
  local line
  line=$(running_models | head -1)
  [ -z "$line" ] && return 1
  RUNNING_MODEL=${line%%	*}
  RUNNING_CONTAINER=${line#*	}
  return 0
}

# Resolve the model's weights to something the engine can load, and ask the
# backend for its command line. Call after load_model.
prepare_model() {
  backend_load "$BACKEND"
  PORT_IN=$MODEL_PORT
  MOUNT_SRC=""; MODEL_MOUNT=""; MODEL_TARGET=""
  HEALTH=${HEALTH_PATH:-$(backend_health_path)}
  BACKEND_ARGS=(); BACKEND_CMD=(); BACKEND_RUN_ARGS=()

  # An external model has no command line of ours to build: its launcher owns
  # that. Everything below this line is about running a container ourselves.
  [ "$BACKEND" = external ] && return 0

  if [ -n "$HF_MODEL" ]; then
    MODEL_TARGET="$HF_MODEL"          # engine pulls it into the shared cache
  elif [ -d "$DIR" ]; then
    MOUNT_SRC="$DIR"
    MODEL_MOUNT="/models/$MODEL_NAME"
    MODEL_TARGET="$MODEL_MOUNT"
    [ -n "$MODEL_FILE" ] && MODEL_TARGET="$MODEL_MOUNT/$MODEL_FILE"
  else
    # DIR names a single file (a .gguf, typically): mount its directory.
    MOUNT_SRC=$(dirname "$DIR")
    MODEL_MOUNT="/models/$MODEL_NAME"
    MODEL_TARGET="$MODEL_MOUNT/$(basename "$DIR")"
  fi

  backend_defaults; backend_command; backend_run_args
}

# The full runtime argv, in RUN_ARGV. Shared by `start` and `config`, so what
# `config` prints is what `start` runs — not a reconstruction of it.
build_run_argv() {
  rt_gpu_args "$MODEL_GPUS"

  local env_flags=() kv mount_flags=() m
  for kv in "${ENV[@]}"; do env_flags+=(-e "$kv"); done
  for m in "${MOUNTS[@]}"; do mount_flags+=(-v "$m"); done

  local cache_flags=()
  if [ -n "$HF_CACHE" ]; then
    cache_flags=(-v "$HF_CACHE:/root/.cache/huggingface"
                 -e "HF_HOME=/root/.cache/huggingface")
  fi

  RUN_ARGV=(
    "$RT" run -d
    --name "$CONTAINER"
    --label "llm-ctl.model=$MODEL_NAME"
    --label "llm-ctl.backend=$BACKEND"
    "${GPU_ARGS[@]}"
    -p "$BIND:$MODEL_PORT:$PORT_IN"
    "${BACKEND_RUN_ARGS[@]}"
    "${cache_flags[@]}"
    "${env_flags[@]}"
  )
  [ -n "$MOUNT_SRC" ] && RUN_ARGV+=(-v "$MOUNT_SRC:$MODEL_MOUNT:ro")
  RUN_ARGV+=("${mount_flags[@]}")
  # Remember where the image sits so `config` can lay the command out in the
  # three parts people actually read: runtime flags, image, engine flags.
  RUN_IMAGE_IDX=${#RUN_ARGV[@]}
  RUN_ARGV+=("$IMAGE"
             "${BACKEND_CMD[@]}" "${BACKEND_ARGS[@]}"
             "${COMMON_ARGS[@]}" "${ARGS[@]}")
}

# Poll until the server answers, the container dies, or we run out of patience.
wait_ready() {
  local port=$1 health=$2 timeout=$3 container=${4:-}
  local waited=0 step=${LLMCTL_POLL_INTERVAL:-3} started=0
  while [ "$waited" -lt "$timeout" ]; do
    if is_serving "$port" "$health"; then
      [ "$started" = 1 ] && printf '\n'
      READY_SECONDS=$waited
      return 0
    fi
    # Only announce that we are waiting once we know we have to.
    if [ "$started" = 0 ] && [ "${LLMCTL_QUIET:-0}" != 1 ]; then
      printf '    loading'; started=1
    fi
    if [ -n "$container" ] && ! rt_is_running "$container"; then
      [ "$started" = 1 ] && printf '\n'
      return 2
    fi
    sleep "$step"; waited=$((waited + step))
    [ "${LLMCTL_QUIET:-0}" = 1 ] || printf '.'
  done
  [ "$started" = 1 ] && printf '\n'
  return 1
}

# "nothing running" is a confusing thing to read while a model is plainly
# answering on the port -- which happens whenever a container was started by
# hand, or by a version of this tool that used a different label. Say what is
# actually true instead of leaving the user to doubt the tool.
unmanaged_port_note() {
  local port=${1:-$PORT}
  port_in_use "$port" || return 0
  if is_serving "$port"; then
    printf 'note:      something llm-ctl does not manage is serving on port %s\n' "$port"
  else
    printf 'note:      something llm-ctl does not manage holds port %s\n' "$port"
  fi
}

stop_model() {
  local name=$1 target=${2:-}
  if ! load_model "$name"; then
    # The definition is gone but its container is still up -- someone renamed
    # or deleted the conf while the model ran. That is exactly when you most
    # need to stop it, so stop what we can see rather than refusing.
    if [ -n "$target" ]; then
      warn "$name has no definition any more; stopping container $target"
      rt_stop "$target"
      return 0
    fi
    error "$MODEL_ERR"
    return 1
  fi
  [ -n "$target" ] || target=$(container_for "$name")
  if [ "$BACKEND" = external ]; then
    if [ -n "$STOPPER" ]; then
      info "stopping $name via $(basename "$STOPPER")${NODES:+ ($NODES nodes)}"
      "$STOPPER" >/dev/null 2>&1
      return 0
    fi
    # No STOPPER: stopping the container we can see may leave peers running on
    # other nodes, so say so rather than pretending it was a clean stop.
    warn "$name has no STOPPER; stopping $target only"
  fi
  info "stopping $name"
  rt_stop "$target"
}

# ---- ls ---------------------------------------------------------------------

cmd_ls() {
  local names; names=$(model_names)
  if [ -z "$names" ]; then
    if [ "${LLMCTL_JSON:-0}" = 1 ]; then echo '[]'; return 0; fi
    echo "no models defined in $MODELS_D"
    echo "add one with:  llm-ctl new <name>"
    return 0
  fi

  local running; running=$(running_models)
  local name status colour size first=1 out=''

  [ "${LLMCTL_JSON:-0}" = 1 ] || \
    printf '%s%-14s %-9s %-10s %-29s %-6s %s%s\n' "$C_BOLD" \
      MODEL BACKEND STATUS IMAGE SIZE DESCRIPTION "$C_RESET"

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! load_model "$name"; then
      if [ "${LLMCTL_JSON:-0}" = 1 ]; then
        [ $first = 1 ] || out+=','; first=0
        out+=$(json_obj name "$name" status "invalid" error "$MODEL_ERR")
      else
        printf '%-14s %-9s %s%-10s%s %s\n' "$name" "?" "$C_RED" "invalid" "$C_RESET" "$MODEL_ERR"
      fi
      continue
    fi

    size="-"
    if printf '%s\n' "$running" | grep -qx "$name	.*"; then
      status=RUNNING; colour=$C_GREEN
    elif [ "$BACKEND" != external ] && [ -n "$DIR" ] && [ ! -e "$DIR" ]; then
      status="no weights"; colour=$C_RED
    elif [ -n "$IMAGE" ] && ! rt_image_exists "$IMAGE"; then
      status="no image"; colour=$C_YELLOW
    else
      status=ready; colour=""
    fi
    [ -n "$DIR" ] && [ "$status" != "no weights" ] && size=$(dir_size "$DIR")

    if [ "${LLMCTL_JSON:-0}" = 1 ]; then
      [ $first = 1 ] || out+=','; first=0
      out+=$(json_obj name "$name" backend "$BACKEND" status "$status" \
                      image "$IMAGE" dir "$DIR" size "$size" \
                      port@ "$MODEL_PORT" description "$DESC")
    else
      printf '%-14s %-9s %s%-10s%s %-29s %-6s %s\n' \
        "$name" "$BACKEND" "$colour" "$status" "$C_RESET" \
        "$(tail_trunc "$IMAGE" 29)" "$size" "$DESC"
    fi
  done <<<"$names"

  if [ "${LLMCTL_JSON:-0}" = 1 ]; then printf '[%s]\n' "$out"; return 0; fi

  if [ -z "$running" ]; then
    local note; note=$(unmanaged_port_note)
    [ -n "$note" ] && { echo; printf '%s\n' "${note#note:      }"; }
  fi
  if [ -n "$running" ]; then
    echo
    while IFS=$'\t' read -r name _; do
      [ -z "$name" ] && continue
      load_model "$name" 2>/dev/null || continue
      prepare_model 2>/dev/null || true
      if is_serving "$MODEL_PORT" "${HEALTH:-/v1/models}"; then
        printf '%s is serving on %shttp://%s:%s%s\n' \
          "$name" "$C_GREEN" "$(printf '%s' "${BIND/0.0.0.0/localhost}")" "$MODEL_PORT" "$C_RESET"
      else
        printf '%s is up but not answering yet (llm-ctl logs -f)\n' "$name"
      fi
    done <<<"$running"
  fi
  return 0
}

# ---- start ------------------------------------------------------------------

cmd_start() {
  local name=${1:-}
  [ -z "$name" ] && die "which model? try: llm-ctl ls"
  load_model "$name" || die "$MODEL_ERR"

  if [ "$BACKEND" != external ]; then
    [ -z "$DIR" ] || [ -e "$DIR" ] || die "weights not found: $DIR"
    rt_image_exists "$IMAGE" || die "image not present: $IMAGE
  pull it with:  $RT pull $IMAGE"
  fi

  # Make room. Exclusive (the default) assumes one accelerator: starting a
  # model stops whatever else is up. With EXCLUSIVE=0 models coexist and only
  # a port clash is a conflict.
  local line other ocontainer
  while IFS=$'\t' read -r other ocontainer; do
    [ -z "$other" ] && continue
    if [ "$other" = "$name" ]; then
      info "$name is already running"; cmd_status; return 0
    fi
    local conflict=0 why=""
    if [ "$EXCLUSIVE" = 1 ]; then
      conflict=1; why="only one model runs at a time"
    else
      local oport; oport=$(load_model "$other" >/dev/null 2>&1 && printf '%s' "$MODEL_PORT")
      load_model "$name"
      [ "$oport" = "$MODEL_PORT" ] && { conflict=1; why="both want port $MODEL_PORT"; }
    fi
    if [ "$conflict" = 1 ]; then
      confirm "$other is running ($why). Stop it and start $name?" || {
        echo "cancelled"; return 1; }
      stop_model "$other" "$ocontainer"
      load_model "$name"   # stop_model loaded the other model's definition
    fi
  done <<<"$(running_models)"

  if [ "$BACKEND" = external ]; then
    start_external "$name"; return $?
  fi

  prepare_model
  if port_in_use "$MODEL_PORT"; then
    die "port $MODEL_PORT is already in use by something llm-ctl does not manage
  find it with:  ss -lntp 'sport = :$MODEL_PORT'   (or lsof -i :$MODEL_PORT)"
  fi

  build_run_argv
  [ -n "$HF_CACHE" ] && mkdir -p "$HF_CACHE"
  rt_rm "$CONTAINER"

  info "starting $name (backend: $BACKEND, image: $IMAGE)"
  debug "$(shell_quote "${RUN_ARGV[@]}")"
  "${RUN_ARGV[@]}" >/dev/null || die "$RT run failed — see: llm-ctl config $name"

  wait_ready "$MODEL_PORT" "$HEALTH" "$MODEL_READY_TIMEOUT" "$CONTAINER"
  case $? in
    0) ok "$name is serving on http://${BIND/0.0.0.0/localhost}:$MODEL_PORT (took ${READY_SECONDS}s)"
       return 0 ;;
    2) error "$name died during startup. Last lines:"
       rt logs --tail 30 "$CONTAINER" 2>&1 | sed 's/^/    /' >&2
       echo "    full log:  llm-ctl logs $name" >&2
       return 1 ;;
    *) die "not serving after ${MODEL_READY_TIMEOUT}s — check: llm-ctl logs -f" ;;
  esac
}

start_external() {
  local name=$1
  local log="${LLMCTL_LOG_DIR:-$LLM_HOME}/${name}-launch.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null
  prepare_model
  info "starting $name via $(basename "$LAUNCHER")  (nodes: $NODES, port: $MODEL_PORT)"
  info "follow along: tail -f $log"
  if ! "$LAUNCHER" >"$log" 2>&1; then
    error "$name launcher failed. Last lines:"
    tail -20 "$log" 2>/dev/null | sed 's/^/    /' >&2
    return 1
  fi
  if wait_ready "$MODEL_PORT" "$HEALTH" "$MODEL_READY_TIMEOUT" ""; then
    ok "$name is serving on http://${BIND/0.0.0.0/localhost}:$MODEL_PORT (took ${READY_SECONDS}s)"
    return 0
  fi
  die "not serving after ${MODEL_READY_TIMEOUT}s — see $log"
}

# ---- stop / restart ---------------------------------------------------------

cmd_stop() {
  local want=${1:-} stopped=0 name container
  while IFS=$'\t' read -r name container; do
    [ -z "$name" ] && continue
    [ -n "$want" ] && [ "$name" != "$want" ] && continue
    stop_model "$name" "$container" && stopped=$((stopped+1))
  done <<<"$(running_models)"
  if [ "$stopped" -eq 0 ]; then
    [ -n "$want" ] && { info "$want is not running"; return 0; }
    info "nothing running"; return 0
  fi
  info "stopped (logs kept: llm-ctl logs)"
}

cmd_restart() {
  local name=${1:-}
  if [ -z "$name" ]; then
    current_model || die "nothing running — say which model to start"
    name=$RUNNING_MODEL      # resolved by label, not by parsing a container name
  fi
  cmd_stop
  LLMCTL_YES=1 cmd_start "$name"
}

# ---- status -----------------------------------------------------------------

cmd_status() {
  local any=0 name container first=1 out=''
  while IFS=$'\t' read -r name container; do
    [ -z "$name" ] && continue
    any=1
    load_model "$name" 2>/dev/null || continue
    prepare_model 2>/dev/null || true
    local serving=false started="" image=""
    is_serving "$MODEL_PORT" "${HEALTH:-/v1/models}" && serving=true
    started=$(rt inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null | cut -c1-19)
    image=$(rt inspect -f '{{.Config.Image}}' "$container" 2>/dev/null)
    [ -z "$image" ] && image=$IMAGE

    if [ "${LLMCTL_JSON:-0}" = 1 ]; then
      [ $first = 1 ] || out+=','; first=0
      out+=$(json_obj model "$name" container "$container" backend "$BACKEND" \
                      nodes@ "${NODES:-1}" port@ "$MODEL_PORT" image "$image" \
                      started "$started" serving@ "$serving" \
                      url "http://${BIND/0.0.0.0/localhost}:$MODEL_PORT")
    else
      echo "model:     $name"
      echo "container: $container"
      echo "backend:   $BACKEND${NODES:+  nodes: $NODES}"
      echo "up:        $started"
      echo "image:     $image"
      if [ "$serving" = true ]; then
        printf 'http:      %sserving%s on http://%s:%s\n' \
          "$C_GREEN" "$C_RESET" "${BIND/0.0.0.0/localhost}" "$MODEL_PORT"
      else
        echo "http:      not answering yet (still loading? llm-ctl logs -f)"
      fi
    fi
  done <<<"$(running_models)"

  if [ "$any" = 0 ]; then
    if [ "${LLMCTL_JSON:-0}" = 1 ]; then echo '[]'; return 0; fi
    echo "nothing running"
    unmanaged_port_note
    local last
    last=$(rt ps -a --filter "label=llm-ctl.model" --format '{{.Names}}' 2>/dev/null | head -1)
    [ -n "$last" ] && echo "last:      $last ($(rt inspect -f '{{.State.Status}}, exit {{.State.ExitCode}}' "$last" 2>/dev/null))"
    return 0
  fi
  [ "${LLMCTL_JSON:-0}" = 1 ] && printf '[%s]\n' "$out"
  return 0
}

# ---- logs -------------------------------------------------------------------

cmd_logs() {
  local name="" args=()
  # A leading bare word that names a model selects it; the rest goes to the
  # runtime, so `llm-ctl logs -f` and `llm-ctl logs mymodel -f` both work.
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    # A bare word here is a model name -- `docker logs` takes only flags
    # besides the container, which llm-ctl supplies itself.
    [ -f "$(model_conf_path "$1")" ] || die "no such model: $1"
    name=$1; shift
  fi
  args=("$@")

  if [ -z "$name" ]; then
    current_model && name=$RUNNING_MODEL
  fi
  if [ -z "$name" ]; then
    local last
    last=$(rt ps -a --filter "label=llm-ctl.model" --format '{{.Names}}' 2>/dev/null | head -1)
    [ -n "$last" ] && name=$(rt inspect -f '{{index .Config.Labels "llm-ctl.model"}}' "$last" 2>/dev/null)
  fi
  [ -z "$name" ] && die "no model to show logs for"
  load_model "$name" || die "$MODEL_ERR"

  if [ "$BACKEND" = external ] && [ -n "$LOGGER" ]; then
    exec "$LOGGER" "${args[@]}"
  fi
  local target; target=$(container_for "$name")
  rt_container_exists "$target" || die "no container for $name (never started here?)"
  rt logs "${args[@]}" "$target" 2>&1
}

# ---- config (dry run) -------------------------------------------------------

cmd_config() {
  local name=${1:-}
  if [ -z "$name" ]; then current_model && name=$RUNNING_MODEL; fi
  [ -z "$name" ] && die "which model? try: llm-ctl ls"
  load_model "$name" || die "$MODEL_ERR"

  echo "# $name — from $(model_conf_path "$name")"
  echo "# backend $BACKEND ($(backend_load "$BACKEND"; backend_describe))"
  if [ "$BACKEND" = external ]; then
    echo
    echo "# started by its own launcher; llm-ctl runs no container for it"
    printf '%s\n' "$(shell_quote "$LAUNCHER")"
    echo
    echo "# stopped with"
    printf '%s\n' "$(shell_quote "${STOPPER:-<none>}")"
    echo
    echo "# watched: container $CONTAINER on port $MODEL_PORT"
    return 0
  fi
  prepare_model
  build_run_argv
  echo
  # These command lines get long and reading them is the whole point, so:
  # one flag per line, and a visible break at the image.
  local i n a indent="  "
  n=${#RUN_ARGV[@]}
  printf '%s' "$(shell_quote "${RUN_ARGV[0]}" "${RUN_ARGV[1]}" "${RUN_ARGV[2]}")"
  for (( i=3; i<n; i++ )); do
    a=${RUN_ARGV[i]}
    if [ "$i" -eq "$RUN_IMAGE_IDX" ]; then
      printf ' \\\n%s%s' "$indent" "$(shell_quote "$a")"
      indent="    "
      # everything after the image is the engine's own command line
      (( i + 1 < n )) && printf ' \\\n%s%s' "$indent" "$(shell_quote "${RUN_ARGV[i+1]}")"
      i=$((i+1))
    elif [[ "$a" == -* ]]; then
      printf ' \\\n%s%s' "$indent" "$(shell_quote "$a")"
    else
      printf ' %s' "$(shell_quote "$a")"
    fi
  done
  printf '\n'
}

# ---- doctor -----------------------------------------------------------------

_dr_ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
_dr_warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; DOCTOR_WARN=$((DOCTOR_WARN+1)); }
_dr_bad()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; DOCTOR_BAD=$((DOCTOR_BAD+1)); }

cmd_doctor() {
  DOCTOR_WARN=0; DOCTOR_BAD=0
  echo "llm-ctl $LLMCTL_VERSION"
  echo
  echo "environment"
  _dr_ok "bash $BASH_VERSION"
  if have curl; then _dr_ok "curl $(curl --version 2>/dev/null | head -1 | cut -d' ' -f2)"
  else _dr_bad "curl not found — readiness checks cannot run"; fi

  echo
  echo "container runtime"
  if have "$RT"; then
    if rt info >/dev/null 2>&1; then
      _dr_ok "$RT $(rt version -f '{{.Client.Version}}' 2>/dev/null || echo '(version unknown)')"
    else
      _dr_bad "$RT is installed but not responding (daemon down? permissions?)"
    fi
  else
    _dr_bad "$RT not found"
  fi

  echo
  echo "accelerator"
  if [ "$GPUS" = none ]; then
    _dr_warn "GPUS=none — models will run on CPU"
  elif have nvidia-smi; then
    local gpu
    # memory.total reads [N/A] on unified-memory parts, so drop it rather
    # than print a field that says nothing.
    gpu=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)
    gpu=${gpu/, \[N\/A\]/}
    if [ -n "$gpu" ]; then _dr_ok "nvidia-smi: $gpu"
    else _dr_warn "nvidia-smi present but returned nothing"; fi
    if rt info 2>/dev/null | grep -qi 'nvidia'; then
      _dr_ok "$RT reports the nvidia runtime"
    else
      _dr_warn "$RT does not list an nvidia runtime — GPU passthrough may fail"
    fi
  else
    _dr_warn "no nvidia-smi; set GPUS=none in $LLMCTL_HOME/config for CPU serving"
  fi

  echo
  echo "configuration"
  if [ -d "$LLMCTL_HOME" ]; then _dr_ok "config home: $LLMCTL_HOME"
  else _dr_warn "config home does not exist yet: $LLMCTL_HOME"; fi
  if [ -d "$LLM_HOME" ]; then _dr_ok "model home:  $LLM_HOME"
  else _dr_warn "model home does not exist: $LLM_HOME"; fi
  local n; n=$(model_names | grep -c . || true)
  if [ "$n" -gt 0 ]; then _dr_ok "$n model(s) in $MODELS_D"
  else _dr_warn "no models defined — try: llm-ctl new <name>"; fi
  _dr_ok "backends: $(backend_names | tr '\n' ' ')"

  echo
  echo "network"
  if port_in_use "$PORT"; then
    if current_model; then _dr_ok "port $PORT held by $RUNNING_MODEL"
    else _dr_warn "port $PORT is in use by something llm-ctl does not manage"; fi
  else
    _dr_ok "port $PORT is free"
  fi
  case "$BIND" in
    127.0.0.1|localhost) _dr_ok "binding $BIND (local only)" ;;
    *) _dr_warn "binding $BIND — the server is reachable from the network, unauthenticated unless API_KEY is set" ;;
  esac

  echo
  local bad=$DOCTOR_BAD warnn=$DOCTOR_WARN
  if [ "$bad" -gt 0 ]; then
    printf '%s%d problem(s)%s, %d warning(s)\n' "$C_RED" "$bad" "$C_RESET" "$warnn"; return 1
  fi
  printf '%sno problems%s, %d warning(s)\n' "$C_GREEN" "$C_RESET" "$warnn"
}

# ---- misc -------------------------------------------------------------------

cmd_lint() {
  local names=("$@") n rc=0
  [ ${#names[@]} -eq 0 ] && mapfile -t names < <(model_names)
  [ ${#names[@]} -eq 0 ] && { echo "no models to check"; return 0; }
  for n in "${names[@]}"; do lint_model "$n" || rc=1; done
  return $rc
}

cmd_backends() {
  local n f
  printf '%s%-12s %-40s %s%s\n' "$C_BOLD" NAME DESCRIPTION SOURCE "$C_RESET"
  while IFS= read -r n; do
    f=$(backend_file "$n")
    local d; d=$(backend_load "$n" >/dev/null 2>&1; backend_describe)
    local src=shipped
    [[ "$f" == "$LLMCTL_HOME/"* ]] && src=user
    printf '%-12s %-40s %s\n' "$n" "$d" "$src"
  done <<<"$(backend_names)"
}

cmd_url() {
  local name=${1:-}
  if [ -z "$name" ]; then current_model || die "nothing running"; name=$RUNNING_MODEL; fi
  load_model "$name" || die "$MODEL_ERR"
  printf 'http://%s:%s/v1\n' "${BIND/0.0.0.0/localhost}" "$MODEL_PORT"
}

cmd_env() {
  local name=${1:-}
  if [ -z "$name" ]; then current_model || die "nothing running"; name=$RUNNING_MODEL; fi
  load_model "$name" || die "$MODEL_ERR"
  local url="http://${BIND/0.0.0.0/localhost}:$MODEL_PORT/v1"
  echo "export OPENAI_BASE_URL=$url"
  echo "export OPENAI_API_KEY=${API_KEY:-dummy}"
  echo "export OPENAI_MODEL=$SERVED_NAME"
  echo "# eval \"\$(llm-ctl env)\""
}

cmd_wait() {
  local name=${1:-}
  if [ -z "$name" ]; then current_model || die "nothing running"; name=$RUNNING_MODEL; fi
  load_model "$name" || die "$MODEL_ERR"
  prepare_model
  wait_ready "$MODEL_PORT" "$HEALTH" "$MODEL_READY_TIMEOUT" "" || die "$name did not become ready"
  ok "$name is ready"
}

cmd_new() {
  local name=${1:-}
  [ -z "$name" ] && die "usage: llm-ctl new <name>"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid model name: $name"
  local conf; conf=$(model_conf_path "$name")
  [ -e "$conf" ] && die "already exists: $conf"
  mkdir -p "$MODELS_D"
  cat > "$conf" <<CONF
# $name — see \`llm-ctl help conf\` for every key.
DESC="one line, shown by llm-ctl ls"

# Where the engine runs. \`llm-ctl backends\` lists what is available.
BACKEND="$DEFAULT_BACKEND"
IMAGE="vllm/vllm-openai:latest"

# The weights: a host path, or a hub id the engine downloads itself.
DIR="\$LLM_HOME/models/$name"
#HF_MODEL="org/model"

# Flags for this model, appended last so they override the backend's defaults.
ARGS=(
  #--max-model-len 32768
)

#ENV=("SOME_VAR=1")
#MOUNTS=("/host/path:/container/path:ro")
#MODEL_PORT=8000
CONF
  ok "created $conf"
  if [ -t 0 ] && [ -n "${EDITOR:-}" ]; then "$EDITOR" "$conf"; fi
  [ "${LLMCTL_QUIET:-0}" = 1 ] && return 0
  cat <<NEXT

next:
  llm-ctl lint $name       do the paths and the image exist?
  llm-ctl config $name     what exactly will run?
  llm-ctl start $name

  llm-ctl help conf          every key you can set
NEXT
}

cmd_edit() {
  local name=${1:-}
  if [ -z "$name" ]; then current_model && name=$RUNNING_MODEL; fi
  [ -z "$name" ] && die "usage: llm-ctl edit <model>"
  local conf; conf=$(model_conf_path "$name")
  [ -f "$conf" ] || die "no such model: $name"
  "${EDITOR:-vi}" "$conf"
}

cmd_completion() {
  local shell=${1:-}
  local f="$LLMCTL_LIBEXEC/completions/llm-ctl.$shell"
  [ -f "$f" ] || die "no completion for '$shell' (have: bash, zsh, fish)"
  cat "$f"
}
