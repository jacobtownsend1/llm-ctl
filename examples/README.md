# Example model definitions

Copy one into `~/.config/llm-ctl/models.d/`, change the paths, and
`llm-ctl lint` it.

| | |
|---|---|
| `llama-8b.conf` | the simplest useful definition |
| `hub-model.conf` | no local weights — the engine pulls from the hub |
| `gemma-gguf.conf` | llama.cpp and GGUF, picking one quantisation |
| `qwen-coder.conf` | a tuned one, with the reasoning written down |
| `cpu-small.conf` | no GPU, and a second port |
| `big-moe.conf` | `external`: a launcher that owns its own containers |

The images, paths and flag values in these files are illustrative — they are
not a tuning recommendation, and any number in a comment is a placeholder for
one you measured. Never copy a measurement you did not take.

`qwen-coder.conf` is the one worth reading. The flags are half the file and the
reasons are the other half, which is the difference between a config you can
maintain and a config you are afraid to touch.
