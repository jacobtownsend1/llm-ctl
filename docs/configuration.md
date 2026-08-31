# Configuration

```
~/.config/llm-ctl/
├── config          global settings
├── models.d/       one .conf per model
└── backends/       your own serving engines
```

Override the location with `LLMCTL_HOME`, or per-invocation with `--home`.

## Globals

Set in `~/.config/llm-ctl/config`. Each has an environment variable that wins
over the file, so you can override one for a single command.

| setting | env | default | |
|---|---|---|---|
| `LLM_HOME` | `LLMCTL_LLM_HOME` | `~/llm` | where weights live; model confs refer to it as `$LLM_HOME` |
| `PORT` | `LLMCTL_PORT` | `8000` | default port |
| `BIND` | `LLMCTL_BIND` | `127.0.0.1` | host address the port is published on |
| `GPUS` | `LLMCTL_GPUS` | `all` | GPU spec, or `none` for CPU |
| `RUNTIME` | `LLMCTL_RUNTIME` | autodetect | `docker`, `podman` or `nerdctl` |
| `EXCLUSIVE` | `LLMCTL_EXCLUSIVE` | `1` | one model at a time |
| `READY_TIMEOUT` | `LLMCTL_READY_TIMEOUT` | `900` | seconds to wait for a server |
| `DEFAULT_BACKEND` | `LLMCTL_BACKEND` | `vllm` | backend for confs that do not say |
| `API_KEY` | `LLMCTL_API_KEY` | empty | passed to the engine and used when probing |
| `HF_CACHE` | `LLMCTL_HF_CACHE` | `$LLM_HOME/hf-home` | shared HF cache; empty to not mount one |
| `COMMON_ARGS` | — | empty | flags added to every model, whatever the backend |

`COMMON_ARGS` exists for the rare case where you genuinely want a flag on
everything. It is empty by default and should usually stay that way: a flag
that suits one engine rarely suits another.

## Model definitions

`llm-ctl help conf` prints this list with the current defaults filled in.

| key | |
|---|---|
| `DESC` | one line, shown by `llm-ctl ls` |
| `BACKEND` | serving engine; see `llm-ctl backends` |
| `IMAGE` | container image **(required)** |
| `DIR` | host path to the weights, or to a single `.gguf` |
| `HF_MODEL` | hub id instead of `DIR`; the engine downloads it |
| `MODEL_FILE` | file inside `DIR` to load, for repos with several |
| `ARGS` | array of engine flags, appended last so they win |
| `ENV` | array of `KEY=value` passed into the container |
| `MOUNTS` | array of `host:container[:ro]` for anything outside `DIR` |
| `MODEL_PORT` | port for this model |
| `SERVED_NAME` | name clients ask for; defaults to the model name |
| `MODEL_GPUS` | GPU spec for this model, or `none` |
| `SHM_SIZE` | shared memory for the container |
| `HEALTH_PATH` | readiness path, if the backend's default is wrong |
| `TRUST_REMOTE_CODE` | `1` to let the checkpoint run its own Python |
| `MODEL_READY_TIMEOUT` | seconds to wait for this model |
| `CMD` | argv to run, for `BACKEND=custom` |

For `BACKEND=external`: `LAUNCHER`, `STOPPER`, `LOGGER`, `CONTAINER_NAME`, `NODES`.

### `MOUNTS` and container paths

llm-ctl mounts `DIR` and nothing else. Anything outside it — a chat template, a
speculative-decoding drafter, a calibration file — needs a `MOUNTS` entry, and
the flag that refers to it must use the **container** path:

```bash
MOUNTS=("$LLM_HOME/chat-templates/mine:/templates:ro")
ARGS=(--chat-template /templates/template.jinja)
```

A `$LLM_HOME` path in `ARGS` does not exist inside the container, and the
engine will die on startup saying the file is missing.

## Security

Model definitions are shell, sourced by llm-ctl. Do not use one you did not
write.

`BIND=127.0.0.1` is the default because a serving engine on `0.0.0.0` is an
unauthenticated endpoint that will happily use your GPU for whoever finds it.
If you change it, set `API_KEY` as well; `llm-ctl doctor` warns when you have
done one without the other.

`--trust-remote-code` executes Python shipped inside the checkpoint. It is
off unless a model asks for it with `TRUST_REMOTE_CODE=1`.
