# vLLM — OpenAI-compatible server. https://docs.vllm.ai
backend_describe() { printf 'vLLM OpenAI-compatible server'; }

# Deliberately minimal: address, port, and the name the model answers to.
# Everything else — parsers, quantisation, speculative decoding, context length
# — is model-specific and belongs in that model's ARGS, not in a global default
# that is wrong for every model that is not the one it was written for.
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

backend_command() { BACKEND_CMD=(vllm serve "$MODEL_TARGET"); }
backend_run_args() { BACKEND_RUN_ARGS=(--ipc=host); }
