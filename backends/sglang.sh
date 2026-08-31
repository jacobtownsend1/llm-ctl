# SGLang — OpenAI-compatible server. https://docs.sglang.ai
backend_describe() { printf 'SGLang OpenAI-compatible server'; }

backend_defaults() {
  BACKEND_ARGS=(
    --host 0.0.0.0
    --port "$PORT_IN"
    --served-model-name "$SERVED_NAME"
  )
  [ "${TRUST_REMOTE_CODE:-0}" = 1 ] && BACKEND_ARGS+=(--trust-remote-code)
  [ -n "$API_KEY" ] && BACKEND_ARGS+=(--api-key "$API_KEY")
  return 0
}

backend_command() {
  BACKEND_CMD=(python3 -m sglang.launch_server --model-path "$MODEL_TARGET")
}

# SGLang's workers talk over shared memory; the docker default of 64m is far
# too small and the failure looks like an unrelated CUDA error.
backend_run_args() {
  BACKEND_RUN_ARGS=(--ipc=host --shm-size "${SHM_SIZE:-16g}")
}
