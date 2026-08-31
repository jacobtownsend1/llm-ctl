# Notes for coding agents

Read this before adding a model or a backend to someone's llm-ctl setup. The
full guides are [docs/adding-a-model.md](docs/adding-a-model.md) and
[docs/backends.md](docs/backends.md); this is what you need to not get it
wrong.

## Where things live

| | |
|---|---|
| `~/.config/llm-ctl/config` | global settings (`LLM_HOME`, `PORT`, `BIND`, `GPUS`, …) |
| `~/.config/llm-ctl/models.d/<name>.conf` | one model |
| `~/.config/llm-ctl/backends/<name>.sh` | a user backend; shadows a shipped one |

Override the root with `LLMCTL_HOME`. Do not write inside the llm-ctl checkout:
nothing there is user configuration.

## Adding a model

1. `llm-ctl backends` — see what engines exist before choosing one.
2. Write `~/.config/llm-ctl/models.d/<name>.conf`. The filename minus `.conf` is
   the model's name. Required: `IMAGE`, and one of `DIR` or `HF_MODEL`.
3. `llm-ctl lint <name>` — parses it and checks every path really exists.
4. `llm-ctl config <name>` — prints the exact command `start` would run. **Read
   this before starting anything.** It is the cheapest way to catch a wrong
   flag; starting a model and waiting for it to fail is the expensive way.
5. `llm-ctl start <name>` only if the user asked you to run it.

`llm-ctl help conf` prints the full key list with the site's own defaults filled
in — prefer it over guessing from memory.

## Rules that are easy to get wrong

- **`ARGS` are the engine's flags, not llm-ctl's.** They are passed through
  untouched and llm-ctl does not validate them. Check them against the version
  of the engine in `IMAGE`, not against the latest docs.
- **Only `DIR` is mounted.** Anything else the flags reference needs a `MOUNTS`
  entry, and the flag must then use the *container* path, not the host path.
  This is the single most common broken definition.
- **`ARGS` come last** and override the backend's defaults. To change a
  backend-set flag, repeat it in `ARGS`.
- **Do not put model-specific flags in `COMMON_ARGS`** or in a backend's
  `backend_defaults`. `COMMON_ARGS` applies to every model whatever the engine;
  a backend default applies to every model of that engine. A context length, a
  KV cache dtype, or a tool-call parser belongs to one model.
- **`TRUST_REMOTE_CODE=1` is opt-in per model.** Do not enable it to make an
  error go away; it executes code from the checkpoint. Enable it when the
  architecture genuinely requires it, and say so in the file.
- **Never widen `BIND` on your own.** `0.0.0.0` exposes an unauthenticated
  endpoint to the network. If the user needs it, set `API_KEY` too.
- **Pin `IMAGE` to a version** rather than `latest` in anything you write.
- **`BACKEND=external` ignores `ARGS`.** Those models are started by their own
  `LAUNCHER`, which builds its own command line; serving knobs live wherever
  that launcher reads them. Adding flags to `ARGS` there changes nothing, and
  looks like it should. `STOPPER` must tear down every node, not just the local
  container. See docs/adding-a-model.md, "Models that are not one container".

## Writing the comments

A definition that records only flags is half-written. When you know why a value
is what it is — a measurement, a constraint, an upstream bug — put it in the
file next to the flag. When you do not know, say that instead of inventing a
justification. Never write a measurement you did not take.

## Adding a backend

One file, five optional functions, `backend_command` required. See
[docs/backends.md](docs/backends.md) for the contract and the variables it can
read. Verify with `llm-ctl backends` and `llm-ctl config <model>`. If it is an
engine other people run, it belongs in `backends/` in the repo with a test.

## Working on llm-ctl itself

    make check     # shellcheck + tests
    ./tests/run.sh # ~3s, stubs docker/curl/ss -- no GPU or network needed

Add a test for a behaviour change; the suite is the reason this is reviewable.
Do not add back-compatibility shims for old key names or container naming.
