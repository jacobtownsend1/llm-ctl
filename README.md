# llm-ctl

Run one local model server at a time, from files you can read.

```console
$ llm-ctl ls
MODEL          BACKEND   STATUS    IMAGE                          SIZE   DESCRIPTION
llama-8b       vllm      ready     vllm/vllm-openai:latest        16G    Llama 3.1 8B Instruct, AWQ
qwen-coder     vllm      RUNNING   vllm/vllm-openai:latest        22G    Qwen3 Coder 30B, speculative decoding
gemma-gguf     llamacpp  ready     ghcr.io/ggml-org/llama.cpp:…   6.4G   Gemma 3 12B, Q4_K_M
big-moe        external  no image  ghcr.io/example/two-node:1.0   284G   284B across two boxes, TP=2

qwen-coder is serving on http://127.0.0.1:8000

$ llm-ctl start llama-8b
==> stopping qwen-coder
==> starting llama-8b (backend: vllm, image: vllm/vllm-openai:latest)
    loading........
 ok  llama-8b is serving on http://127.0.0.1:8000 (took 41s)
```

`llm-ctl` is a single bash script and a directory of model definitions. It is
for the machine under your desk with a GPU in it, where you keep several
models, swap between them, and have spent real time working out which flags
each one actually needs.

## Why this and not Ollama

Ollama and LM Studio give you a catalogue and hide the engine. That is the
right trade for most people, and if it is the right trade for you, use them.

This is for when it is not: when you are running vLLM or SGLang or llama.cpp
against a container image you chose, with flags you tuned, and the reason a
model is fast is a specific combination of quantisation, speculative decoding
and cache settings that took you an afternoon to find. `llm-ctl` gives that
combination a name, a file, and a place to write down *why*:

```bash
# models.d/qwen-coder.conf
DESC="Qwen3 Coder 30B, NVFP4 + speculative decoding"
BACKEND="vllm"
IMAGE="vllm/vllm-openai:v0.11.0"
DIR="$LLM_HOME/models/qwen3-coder-30b-nvfp4"

# Why 3 and not the 5 on the model card: measured both on this box, wrote the
# numbers down, 3 won on throughput and draft acceptance. vLLM warns that >1
# reruns the same MTP layer and can lower acceptance. Your numbers go here.
ARGS=(
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
  --max-model-len 262144
  --gpu-memory-utilization 0.40
  --tool-call-parser qwen3_xml
)
```

That file is the point. It is version-controllable, diffable, and six months
later it still tells you why the number is 3.

## Install

```bash
git clone https://github.com/jacobtownsend1/llm-ctl
cd llm-ctl
./install.sh
```

That symlinks `llm-ctl` into `~/.local/bin` and writes a starter config to
`~/.config/llm-ctl`. Nothing else is touched; `./install.sh --uninstall` puts it
back. Requires bash 4.4+, curl, and docker (or podman, or nerdctl).

Then:

```bash
llm-ctl doctor          # can this machine actually serve a model?
llm-ctl new my-model    # write your first definition
llm-ctl lint my-model   # do the paths and the image exist?
llm-ctl config my-model # what exactly will run?
llm-ctl start my-model
```

**[docs/adding-a-model.md](docs/adding-a-model.md)** walks through that
properly — where weights can come from, choosing a backend and image, what to
write down, and the handful of things that commonly go wrong. If you are
pointing a coding agent at this, [AGENTS.md](AGENTS.md) is the short version.

## Commands

| | |
|---|---|
| `llm-ctl ls` | every model you have defined, and what state it is in |
| `llm-ctl start <model>` | start it, and wait until it actually answers |
| `llm-ctl stop [model]` | stop what is running |
| `llm-ctl restart [model]` | restart, or switch to another model |
| `llm-ctl status` | what is up: backend, uptime, image, whether it serves |
| `llm-ctl logs [model] [-f]` | logs; extra arguments go to the container runtime |
| `llm-ctl config <model>` | print the exact command `start` would run |
| `llm-ctl doctor` | check runtime, GPU, ports, config |
| `llm-ctl lint` | check your definitions for mistakes |
| `llm-ctl new` / `edit` | scaffold or open a definition |
| `llm-ctl wait` / `url` / `env` | for scripting against a running server |
| `llm-ctl backends` | serving engines available here |

`llm-ctl help conf` prints the full model schema.

### `llm-ctl config` is the one to know about

Serving flags fail in ways that are hard to read from a stack trace. `config`
prints the command without running it:

```console
$ llm-ctl config qwen-coder
# qwen-coder — from ~/.config/llm-ctl/models.d/qwen-coder.conf
# backend vllm (vLLM OpenAI-compatible server)

docker run -d \
  --name llm-ctl-qwen-coder \
  --label llm-ctl.model=qwen-coder \
  --gpus all \
  -p 127.0.0.1:8000:8000 \
  --ipc=host \
  -v /home/you/llm/models/qwen3-coder-30b-nvfp4:/models/qwen-coder:ro \
  vllm/vllm-openai:v0.11.0 \
    vllm serve /models/qwen-coder \
    --host 0.0.0.0 \
    --port 8000 \
    --served-model-name qwen-coder \
    --speculative-config {"method":"mtp","num_speculative_tokens":3} \
    --max-model-len 262144
```

It is built by the same code path `start` uses, so it is what runs, not a
reconstruction of it.

## Backends

A serving engine is one file. These ship:

| backend | what it runs |
|---|---|
| `vllm` | `vllm serve` |
| `sglang` | `sglang.launch_server` |
| `llamacpp` | `llama-server`, GGUF |
| `tgi` | Text Generation Inference |
| `custom` | an argv you supply in the conf |
| `external` | your own launcher — a compose stack, a multi-node recipe |

Adding one is about ten lines, and needs no change to the core:

```bash
# ~/.config/llm-ctl/backends/mlx.sh
backend_describe()    { printf 'MLX server'; }
backend_command()     { BACKEND_CMD=(mlx_lm.server --model "$MODEL_TARGET" --port "$PORT_IN"); }
backend_health_path() { printf '/health'; }
```

A file in your config directory shadows a shipped backend of the same name, so
you can change how `vllm` is launched without forking anything. See
[docs/backends.md](docs/backends.md).

`external` is the escape hatch for anything that is not one container: it calls
your `LAUNCHER`, then watches the container you name on the port you name, and
`STOPPER` tears the whole thing down. That is how a two-node tensor-parallel
deployment fits in the same `ls` output as an 8B on a laptop GPU.

To be clear about the boundary: llm-ctl does not do distributed serving. It
does not move weights, start remote containers, or coordinate ranks — your
recipe does that. What it adds is that the deployment gets a name, a
definition, and the same verbs as everything else. See
[docs/adding-a-model.md](docs/adding-a-model.md#models-that-are-not-one-container).

## Configuration

```
~/.config/llm-ctl/
├── config          global settings
├── models.d/       one .conf per model
└── backends/       your own serving engines
```

Every global has a default, and an environment variable that overrides it
(`LLMCTL_PORT`, `LLMCTL_BIND`, `LLMCTL_GPUS`, …).

| | |
|---|---|
| [docs/adding-a-model.md](docs/adding-a-model.md) | adding a model, end to end |
| [docs/configuration.md](docs/configuration.md) | every setting and every model key |
| [docs/backends.md](docs/backends.md) | writing a backend |
| [AGENTS.md](AGENTS.md) | the same, condensed, for coding agents |

`llm-ctl help conf` prints the model schema with your own defaults filled in.

Model definitions are shell, sourced by `llm-ctl`. That buys arrays and
comments, and the trade is the obvious one: **do not use a `.conf` you did not
write**, the same way you would not run someone's `Makefile` unread.

### Some defaults worth knowing

- **The server binds `127.0.0.1`.** Set `BIND=0.0.0.0` to expose it, and set
  `API_KEY` when you do — `doctor` will warn if you do the first without the second.
- **`--trust-remote-code` is off.** It runs Python from the checkpoint. Turn it
  on per model with `TRUST_REMOTE_CODE=1` when a model needs it.
- **One model at a time**, since they are competing for the same GPU. Set
  `EXCLUSIVE=0` and give them different `MODEL_PORT`s to run several.
- **Backends contribute almost no flags** — address, port, served name. Tuning
  is per model, because a flag that is right for one model is rarely right for
  the next one.

## Development

```bash
make check     # shellcheck + tests
make test      # tests only, about three seconds
```

The suite stubs the container runtime, `curl` and `ss`, so it runs anywhere:
no GPU, no docker, no network, no weights. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT.
