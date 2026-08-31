#!/usr/bin/env bash
# config.sh — where configuration lives, and how a model definition is loaded.
#
# Layout of $LLMCTL_HOME (default ~/.config/llm-ctl):
#   config          global settings, sourced (optional)
#   models.d/*.conf one file per model
#   backends/*.sh   user backends; a file here shadows a shipped one of the
#                   same name, so a backend can be overridden without a fork

llmctl_resolve_home() {
  if [ -n "${LLMCTL_HOME:-}" ]; then printf '%s' "$LLMCTL_HOME"; return; fi
  local xdg=${XDG_CONFIG_HOME:-$HOME/.config}
  printf '%s' "$xdg/llm-ctl"
}

# Global defaults. Every one of these is overridable in $LLMCTL_HOME/config,
# and then again by the environment, which wins.
llmctl_load_config() {
  LLMCTL_HOME=$(llmctl_resolve_home)
  MODELS_D="$LLMCTL_HOME/models.d"

  # Defaults before the config file gets a say.
  LLM_HOME="${LLM_HOME:-$HOME/llm}"
  PORT=8000
  BIND=127.0.0.1
  RUNTIME=""
  GPUS=all
  READY_TIMEOUT=900
  DEFAULT_BACKEND=vllm
  EXCLUSIVE=1
  API_KEY=""
  HF_CACHE=""
  COMMON_ARGS=()

  if [ -f "$LLMCTL_HOME/config" ]; then
    # shellcheck disable=SC1091
    source "$LLMCTL_HOME/config" || die "failed to read $LLMCTL_HOME/config"
  fi

  # Environment overrides the config file.
  PORT=${LLMCTL_PORT:-$PORT}
  BIND=${LLMCTL_BIND:-$BIND}
  RUNTIME=${LLMCTL_RUNTIME:-$RUNTIME}
  GPUS=${LLMCTL_GPUS:-$GPUS}
  READY_TIMEOUT=${LLMCTL_READY_TIMEOUT:-$READY_TIMEOUT}
  DEFAULT_BACKEND=${LLMCTL_BACKEND:-$DEFAULT_BACKEND}
  API_KEY=${LLMCTL_API_KEY:-$API_KEY}
  LLM_HOME=${LLMCTL_LLM_HOME:-$LLM_HOME}
  HF_CACHE=${LLMCTL_HF_CACHE:-${HF_CACHE:-$LLM_HOME/hf-home}}
  [ -n "${LLMCTL_EXCLUSIVE:-}" ] && EXCLUSIVE=$LLMCTL_EXCLUSIVE
  case "$EXCLUSIVE" in true|yes|1) EXCLUSIVE=1 ;; false|no|0) EXCLUSIVE=0 ;; esac

}

model_names() {
  [ -d "$MODELS_D" ] || return 0
  local f
  for f in "$MODELS_D"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done | sort
}

model_conf_path() { printf '%s/%s.conf' "$MODELS_D" "$1"; }

# Load a model definition into globals. Returns 1 (with a warning) on a bad
# definition rather than exiting: one broken conf must not take down `ls`.
# MODEL_ERR carries the reason for callers that want to report it.
load_model() {
  local name=$1 conf
  conf=$(model_conf_path "$name")
  MODEL_ERR=""
  [ -f "$conf" ] || { MODEL_ERR="no such model: $name"; return 1; }

  # Reset every key the schema defines, so nothing leaks between loads.
  MODEL_NAME=$name
  DESC=""; DIR=""; HF_MODEL=""; MODEL_FILE=""; IMAGE=""
  BACKEND=""
  ARGS=()
  ENV=(); MOUNTS=(); CMD=()
  MODEL_PORT=""; SERVED_NAME=""; HEALTH_PATH=""; MODEL_GPUS=""
  MODEL_READY_TIMEOUT=""; SHM_SIZE=""
  LAUNCHER=""; STOPPER=""; LOGGER=""; CONTAINER_NAME=""; NODES=1

  # A conf is shell, sourced. That is a deliberate trade: it buys arrays and
  # comments, and these files are yours, like a Makefile or .bashrc. Never
  # source a conf you did not write.
  # shellcheck disable=SC1090
  source "$conf" || { MODEL_ERR="$name.conf: failed to parse"; return 1; }

  [ -n "$BACKEND" ] || BACKEND=$DEFAULT_BACKEND

  MODEL_PORT=${MODEL_PORT:-$PORT}
  MODEL_GPUS=${MODEL_GPUS:-$GPUS}
  MODEL_READY_TIMEOUT=${MODEL_READY_TIMEOUT:-$READY_TIMEOUT}
  SERVED_NAME=${SERVED_NAME:-$name}

  backend_exists "$BACKEND" || {
    MODEL_ERR="$name.conf: unknown backend '$BACKEND' (llm-ctl backends)"; return 1; }

  if [ "$BACKEND" = external ]; then
    [ -n "$LAUNCHER" ]       || { MODEL_ERR="$name.conf: external needs LAUNCHER"; return 1; }
    [ -n "$CONTAINER_NAME" ] || { MODEL_ERR="$name.conf: external needs CONTAINER_NAME"; return 1; }
    CONTAINER="$CONTAINER_NAME"   # its launcher named it, not us
  else
    [ -n "$IMAGE" ] || { MODEL_ERR="$name.conf: IMAGE is not set"; return 1; }
    [ -n "$DIR" ] || [ -n "$HF_MODEL" ] || {
      MODEL_ERR="$name.conf: set DIR (local weights) or HF_MODEL (hub id)"; return 1; }
    CONTAINER="${LLMCTL_PREFIX:-llm-ctl}-$name"
  fi
  return 0
}

# Everything `lint` checks that `load_model` does not: things that are wrong
# but not fatal, and things only checkable against the filesystem.
lint_model() {
  local name=$1 issues=0 conf
  conf=$(model_conf_path "$name")
  if ! load_model "$name"; then
    printf '%s%s%s  %s\n' "$C_RED" "$name" "$C_RESET" "$MODEL_ERR"
    return 1
  fi
  _lint_note() { printf '%s%s%s  %s\n' "$C_YELLOW" "$name" "$C_RESET" "$1"; issues=$((issues+1)); }

  if [ "$BACKEND" != external ]; then
    [ -n "$DIR" ] && [ ! -e "$DIR" ] && _lint_note "DIR does not exist: $DIR"
    [ -n "$MODEL_FILE" ] && [ -n "$DIR" ] && [ ! -e "$DIR/$MODEL_FILE" ] &&
      _lint_note "MODEL_FILE not found: $DIR/$MODEL_FILE"
    local m
    for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do
      [ -e "${m%%:*}" ] || _lint_note "MOUNTS source does not exist: ${m%%:*}"
    done
    for m in ${ENV[@]+"${ENV[@]}"}; do
      [[ "$m" == *=* ]] || _lint_note "ENV entry is not KEY=value: $m"
    done
  else
    [ -x "$LAUNCHER" ] || _lint_note "LAUNCHER is not executable: $LAUNCHER"
    [ -n "$STOPPER" ] && [ ! -x "$STOPPER" ] && _lint_note "STOPPER is not executable: $STOPPER"
    [ -z "$STOPPER" ] && _lint_note "no STOPPER: stop will fall back to killing $CONTAINER_NAME"
  fi

  unset -f _lint_note
  [ "$issues" -eq 0 ] && printf '%s%s%s  ok\n' "$C_GREEN" "$name" "$C_RESET"
  return 0
}
