# Text Generation Inference. https://github.com/huggingface/text-generation-inference
backend_describe() { printf 'HuggingFace Text Generation Inference'; }

backend_defaults() {
  BACKEND_ARGS=(--hostname 0.0.0.0 --port "$PORT_IN")
  [ "${TRUST_REMOTE_CODE:-0}" = 1 ] && BACKEND_ARGS+=(--trust-remote-code)
  return 0
}

backend_command() { BACKEND_CMD=(--model-id "$MODEL_TARGET"); }
backend_run_args() { BACKEND_RUN_ARGS=(--shm-size "${SHM_SIZE:-1g}"); }
backend_health_path() { printf '/health'; }
