#!/usr/bin/env bash
# runtime.sh — the container runtime, behind a thin wrapper.
#
# Everything llm-ctl does to a container goes through rt_*, so supporting
# podman/nerdctl is a matter of the flag differences below rather than a
# rewrite. Set RUNTIME in $LLMCTL_HOME/config to pin one.

rt_detect() {
  if [ -n "$RUNTIME" ]; then
    have "$RUNTIME" || die "RUNTIME is set to '$RUNTIME' but that command is not on PATH"
    RT=$RUNTIME; return 0
  fi
  local c
  for c in docker podman nerdctl; do
    if have "$c"; then RT=$c; return 0; fi
  done
  die "no container runtime found (looked for docker, podman, nerdctl) — see: llm-ctl doctor"
}

rt() { "$RT" "$@"; }

# GPU passthrough differs per runtime. GPUS=none serves on CPU, which is the
# only sane default for a machine without an accelerator.
rt_gpu_args() {
  local spec=${1:-all}
  GPU_ARGS=()
  case "$spec" in none|"") return 0 ;; esac
  case "$RT" in
    podman) GPU_ARGS=(--device "nvidia.com/gpu=$spec" --security-opt label=disable) ;;
    *)      GPU_ARGS=(--gpus "$spec") ;;
  esac
}

rt_image_exists()     { rt image inspect "$1" >/dev/null 2>&1; }
rt_container_exists() { rt container inspect "$1" >/dev/null 2>&1; }
rt_container_state()  { rt inspect -f '{{.State.Status}}' "$1" 2>/dev/null; }
rt_is_running()       { [ "$(rt_container_state "$1")" = running ]; }

# Exact names of running containers, one per line. Callers compare with = ,
# never with a regex, so a container name containing . or + is harmless.
rt_running_names() { rt ps --format '{{.Names}}' 2>/dev/null; }
rt_all_names()     { rt ps -a --format '{{.Names}}' 2>/dev/null; }

rt_stop() { rt stop "$1" >/dev/null 2>&1; }
rt_rm()   { rt rm -f "$1" >/dev/null 2>&1; }

# Is anything answering on this port? Sends the API key when one is set,
# so a secured server is not misreported as down.
is_serving() {
  local port=${1:-$PORT} path=${2:-/v1/models} hdr=()
  [ -n "$API_KEY" ] && hdr=(-H "Authorization: Bearer $API_KEY")
  curl -sf -m "${LLMCTL_CURL_TIMEOUT:-3}" "${hdr[@]}" \
    "http://${LLMCTL_PROBE_HOST:-127.0.0.1}:${port}${path}" >/dev/null 2>&1
}

# True if something already holds the port. Used as a preflight so a port
# clash surfaces as one line instead of a runtime error 40 lines deep.
port_in_use() {
  local port=$1
  if have ss; then ss -lntH "sport = :$port" 2>/dev/null | grep -q .
  elif have lsof; then lsof -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
  else return 1; fi
}
