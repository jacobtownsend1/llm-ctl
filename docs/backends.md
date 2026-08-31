# Writing a backend

A backend is one shell file that says how to launch a serving engine. Nothing
in llm-ctl's core knows the name of any engine, so adding one never means
touching the core.

Put it in `~/.config/llm-ctl/backends/<name>.sh` and `BACKEND=<name>` works.
A file there shadows a shipped backend of the same name — that is the supported
way to change how `vllm` is launched without forking the project.

## The contract

Five functions, all optional except `backend_command`. Each has a default, so
a minimal backend is short:

```bash
# ~/.config/llm-ctl/backends/mlx.sh
backend_describe()    { printf 'MLX server'; }
backend_command()     { BACKEND_CMD=(mlx_lm.server --model "$MODEL_TARGET" --port "$PORT_IN"); }
backend_health_path() { printf '/health'; }
```

| function | sets | default |
|---|---|---|
| `backend_describe` | prints one line for `llm-ctl backends` | `(no description)` |
| `backend_command` | `BACKEND_CMD=()`, the argv run inside the image | required |
| `backend_defaults` | `BACKEND_ARGS=()`, flags every model of this backend gets | empty |
| `backend_run_args` | `BACKEND_RUN_ARGS=()`, extra container-runtime flags | empty |
| `backend_health_path` | prints the readiness path | `/v1/models` |

The final command line is:

    BACKEND_CMD  BACKEND_ARGS  COMMON_ARGS  ARGS

`ARGS` (the model's own flags) comes last, so a model can override anything the
backend set by repeating the flag — for engines that take last-one-wins, which
vLLM, SGLang and llama.cpp all do.

## What you can read

When those functions run, these are set:

| | |
|---|---|
| `MODEL_NAME` | the model's name, i.e. its filename minus `.conf` |
| `MODEL_TARGET` | what the engine should load: a container path, or a hub id |
| `MODEL_MOUNT` | where the weights are mounted, or empty for `HF_MODEL` |
| `SERVED_NAME` | the name clients ask for |
| `PORT_IN` | the port to listen on inside the container |
| `API_KEY`, `SHM_SIZE`, `TRUST_REMOTE_CODE` | globals a backend may want |

...plus every key the model's own conf set.

## Guidelines

**Contribute as few flags as possible.** `backend_defaults` should cover the
address, the port, and the served name — the things without which the engine
cannot be reached at all. Everything else is a property of a model, not of an
engine. A context length, a KV cache dtype or one model family's tool-call
parser in a backend default is wrong for every model that is not the one it was
written for, and every other model then has to override it.

**Bind `0.0.0.0` inside the container.** The host-side address is controlled by
`BIND`, which llm-ctl applies when it publishes the port. A backend that binds
`127.0.0.1` inside the container is unreachable.

**Honour `API_KEY` if the engine can.** llm-ctl sends it when probing for
readiness, so an engine that requires it but was not given it will look like it
never started.

**Pick the right `backend_health_path`.** llm-ctl polls it to decide the model
is up. `/v1/models` is right for OpenAI-compatible servers; `/health` for most
others.

## Testing one

```bash
llm-ctl backends              # is it found?
llm-ctl config <model>        # is the command line what you expect?
```

If you are contributing it back, add a case to `tests/run.sh` next to
`test_a_new_backend_needs_no_core_changes`.
