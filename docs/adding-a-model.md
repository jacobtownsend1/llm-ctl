# Adding a model

Start to finish, with the failure modes named. If you just want the list of
keys, that is [configuration.md](configuration.md) or `llm-ctl help conf`.

## The short version

```bash
llm-ctl new my-model     # writes a definition and opens it in $EDITOR
llm-ctl lint my-model    # do the paths and the image exist?
llm-ctl config my-model  # what exactly will run?
llm-ctl start my-model   # run it
```

Four steps, and the middle two are why this is quicker than it looks: `lint`
catches the wrong path and `config` catches the wrong flag, both without
waiting three minutes for a checkpoint to load and fail.

## 1. Decide where the weights come from

Three options, and they change one line of the definition.

**A directory you already have.** The usual case.

```bash
DIR="$LLM_HOME/models/llama-3.1-8b-instruct-awq"
```

`$LLM_HOME` is set in `~/.config/llm-ctl/config` and is just a convenience — an
absolute path works too. llm-ctl mounts this directory read-only inside the
container at `/models/<name>`.

**A hub id, downloaded by the engine on first start.**

```bash
HF_MODEL="mistralai/Mistral-7B-Instruct-v0.3"
```

Nothing is mounted; the engine pulls into the shared cache (`HF_CACHE`), so the
first start is slow and later ones are not. Good for trying something before
committing disk to it. Gated repos need `HF_TOKEN` in `ENV`.

**A single GGUF file**, for llama.cpp. Either point `DIR` straight at the file,
or at the directory and name the quantisation:

```bash
DIR="$LLM_HOME/models/gemma-3-12b-gguf"
MODEL_FILE="gemma-3-12b-it-Q4_K_M.gguf"
```

## 2. Pick a backend and an image

`llm-ctl backends` lists what is installed. The backend decides how the engine
is invoked; the image decides which build of it you get.

| backend | a working image to start from |
|---|---|
| `vllm` | `vllm/vllm-openai:latest` |
| `sglang` | `lmsysorg/sglang:latest` |
| `llamacpp` | `ghcr.io/ggml-org/llama.cpp:server-cuda` |
| `tgi` | `ghcr.io/huggingface/text-generation-inference:latest` |

Pin a version rather than `latest` once it works. A serving engine that changes
under you is the single most common reason a model that ran last month does not
run today.

If your engine is not listed, you have two options: `BACKEND=custom` with a
`CMD=()` for a one-off, or [write a backend](backends.md) — about ten lines,
and no change to llm-ctl itself.

Pull the image before the first start; llm-ctl will not do it for you:

```bash
docker pull vllm/vllm-openai:latest
```

## 3. Write the definition

`llm-ctl new <name>` scaffolds one. The filename minus `.conf` is the name you
pass to `start`, so keep it short.

```bash
# ~/.config/llm-ctl/models.d/llama-8b.conf
DESC="Llama 3.1 8B Instruct, AWQ"
BACKEND="vllm"
IMAGE="vllm/vllm-openai:v0.11.0"
DIR="$LLM_HOME/models/llama-3.1-8b-instruct-awq"

ARGS=(
  --quantization awq
  --max-model-len 32768
)
```

`ARGS` are the engine's own flags, passed through untouched and appended last,
so they override anything the backend set. **llm-ctl does not validate them** —
they are your engine's flags, not llm-ctl's, and a typo surfaces as the engine
refusing to start. `llm-ctl config` shows you the line before you commit to it.

The file is shell, sourced by llm-ctl. That is what buys you arrays and
comments, and the trade is the obvious one: **never use a `.conf` you did not
write**, exactly as you would not run an unread `Makefile`.

### Write down why

The flags are the smaller half of a good definition. Six months from now the
question is not *what* the number is, it is whether you may change it:

```bash
ARGS=(
  # Why 3 and not the model card's number: measure both, put what you got
  # here. Raising it reruns the same MTP layer and can lower acceptance, so
  # this is a measurement, not a default to copy.
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}'

  # A value that looks too low is often correct: past some point the
  # reservation is KV this configuration cannot reach, taken from the weights.
  # Say which it is, so nobody "fixes" it later.
  --gpu-memory-utilization 0.40
  --max-num-seqs 4
)
```

`examples/models.d/qwen-coder.conf` is a worked example of this.

## 4. Check it before you run it

```bash
llm-ctl lint my-model
```

Checks the definition parses, the backend exists, and the paths in `DIR`,
`MOUNTS` and `MODEL_FILE` are really there. It does not start anything.

```bash
llm-ctl config my-model
```

Prints the exact command `start` will run, built by the same code path, so it
is the command and not a reconstruction of it. Read the engine flags at the
bottom: that is where a wrong quantisation or a path that does not exist inside
the container becomes obvious.

## 5. Start it

```bash
llm-ctl start my-model
```

It waits until the server actually answers, not just until the container is up
— big checkpoints take minutes, and "started" is not "ready". If the container
dies on the way, you get its last 30 log lines instead of silence.

```bash
llm-ctl status          # is it serving, on what port
llm-ctl logs -f         # follow it
eval "$(llm-ctl env)"   # point an OpenAI client at it
```

## Models that are not one container

Some deployments cannot be a single `run`: a compose stack, a vendor recipe, or
a model tensor-parallel across two machines that has to start the worker before
the head. `BACKEND=external` hands those off. llm-ctl stops trying to build a
command line and instead calls your launcher, then watches the container you
name on the port you name:

```bash
DESC="284B MoE, TP=2 across two boxes"
BACKEND="external"
IMAGE="ghcr.io/example/two-node-vllm:1.0"

NODES=2                     # shown by status; documentation, not orchestration
MODEL_PORT=8888
CONTAINER_NAME="big-moe-head"          # the name YOUR launcher gives it
LAUNCHER="$LLM_HOME/recipes/big-moe/start.sh"
STOPPER="$LLM_HOME/recipes/big-moe/stop.sh"
LOGGER="$LLM_HOME/recipes/big-moe/logs.sh"   # optional
```

`ARGS` is ignored for these — the launcher builds its own command line. Put the
serving knobs wherever that launcher reads them and say so in a comment, or the
next person will change `ARGS` and wonder why nothing happens.

### What llm-ctl expects of a launcher

Three things, and they are the whole contract:

1. **`LAUNCHER` exits 0 once it has handed off.** It does not need to wait for
   the model to be ready — llm-ctl polls `MODEL_PORT` until it answers. A
   non-zero exit is reported with the last 20 lines of its log.
2. **A container named `CONTAINER_NAME` is running afterwards.** That is how
   `ls`, `status` and `logs` find the deployment. It is matched as an exact
   string, so any name is fine.
3. **`STOPPER` tears down every node**, not just the one on this machine. This
   is the one that bites: `docker stop` on the head leaves the worker holding
   the other machine's GPU. If a model has no `STOPPER`, llm-ctl says so rather
   than pretending the stop was clean.

Output goes to `$LLM_HOME/<model>-launch.log`, which `start` names as it runs.

### What this does and does not give you

llm-ctl does not do distributed serving. It does not copy weights between
machines, start remote containers, coordinate ranks, or know what a rank is.
The engine and the recipe do all of that. What llm-ctl adds is that a two-node
deployment gets a name, a definition, and the same four verbs as everything
else — it appears in the same `ls` as an 8B on a laptop GPU, `start` waits for
it to actually answer, `stop` tears down all of it, and starting it stops
whatever single-node model was using the GPU first.

That is a real convenience and a deliberately small claim. If you need llm-ctl
to *orchestrate* multiple machines, it is the wrong tool; write the recipe, and
point `LAUNCHER` at it.

## Things that commonly go wrong

**A file the flags refer to does not exist inside the container.** llm-ctl
mounts `DIR` and nothing else. A chat template, a draft model, a calibration
file living elsewhere needs a `MOUNTS` entry, and the flag must use the
**container** path:

```bash
MOUNTS=("$LLM_HOME/chat-templates/mine:/templates:ro")
ARGS=(--chat-template /templates/template.jinja)   # NOT $LLM_HOME/...
```

A `$LLM_HOME` path in `ARGS` does not exist inside the container and the engine
dies on startup saying the file is missing.

**The model needs to run its own Python.** Custom architectures often do. It is
off by default because it executes code shipped inside the checkpoint:

```bash
TRUST_REMOTE_CODE=1
```

**The port is taken.** `start` refuses rather than colliding. `llm-ctl status`
shows what llm-ctl has running; if it says nothing is running, something else on
the machine has the port — the error message tells you how to find it. Give the
model its own with `MODEL_PORT`.

**It never becomes ready.** Almost always the engine failing slowly rather than
llm-ctl waiting wrongly: `llm-ctl logs`. If the model is genuinely just slow to
load, raise `MODEL_READY_TIMEOUT` in the definition.

**Clients cannot find the model by name.** The id clients ask for is
`SERVED_NAME`, which defaults to the model's name. Set it explicitly if
something is already pointed at a different id.

**Out of memory on a second model.** By default one model runs at a time and
starting another stops the first. If you have the memory for both, set
`EXCLUSIVE=0` and give them different `MODEL_PORT`s.
