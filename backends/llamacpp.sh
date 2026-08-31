# llama.cpp — llama-server, GGUF. https://github.com/ggml-org/llama.cpp
#
# Point DIR at a directory of GGUFs and set MODEL_FILE to the one to load, or
# point DIR straight at the .gguf file.
backend_describe() { printf 'llama.cpp llama-server (GGUF)'; }

backend_defaults() {
  BACKEND_ARGS=(--host 0.0.0.0 --port "$PORT_IN" --alias "$SERVED_NAME")
  [ -n "$API_KEY" ] && BACKEND_ARGS+=(--api-key "$API_KEY")
  return 0
}

backend_command() { BACKEND_CMD=(-m "$MODEL_TARGET"); }
backend_health_path() { printf '/health'; }
