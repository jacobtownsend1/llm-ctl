# Changelog

## 1.0.0

First release.

- **Model definitions as files.** One `.conf` per model in
  `~/.config/llm-ctl/models.d`, holding the image, the weights and the engine
  flags — and room for the reasons behind them.
- **Backend plugins.** A serving engine is one shell file in `backends/`.
  Ships with `vllm`, `sglang`, `llamacpp`, `tgi`, `custom` and `external`. A
  file in your config directory shadows a shipped one, so an engine can be
  adjusted without forking. Nothing in the core names an engine.
- **Commands:** `ls`, `start`, `stop`, `restart`, `status`, `logs`, `config`
  (dry run), `wait`, `url`, `env`, `new`, `edit`, `lint`, `backends`,
  `doctor`, `completion`.
- `--json` output for `ls` and `status`; completion for bash, zsh and fish.
- Weights from a local path, a single GGUF file, or a hub id (`HF_MODEL`).
- docker, podman and nerdctl; `GPUS=none` for CPU serving.
- `EXCLUSIVE=0` runs several models side by side on different ports.
- `API_KEY` is passed to the engine and used when probing for readiness.
- Binds `127.0.0.1` by default; `--trust-remote-code` is opt-in per model.
- 42 tests stubbing the container runtime, `curl` and `ss`: no GPU, docker,
  network or model weights needed. shellcheck clean.
