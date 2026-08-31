# Contributing

## Running the tests

    make check          # shellcheck + the suite
    ./tests/run.sh      # just the suite
    ./tests/run.sh port # just the tests matching "port"

The suite stubs the container runtime, `curl` and `ss` (see `tests/stubs/`), so
it needs no GPU, no docker, no network and no model weights. It should run in
about three seconds. Every bug fix wants a test named after the behaviour, not
the fix — look at the ones marked `# Regression:` for the shape.

## Adding a backend

A serving engine is one file in `backends/`. See [docs/backends.md](docs/backends.md);
the smallest useful one is about ten lines. If it is an engine other people
run, send it as a pull request with a test in `tests/run.sh` alongside
`test_a_new_backend_needs_no_core_changes`.

## Style

- bash 4.4+, `shellcheck` clean with the repo's `.shellcheckrc`.
- Diagnostics go to stderr; anything a script might parse goes to stdout.
- No dependency beyond bash, coreutils and a container runtime. If a change
  needs python, jq or curl-with-a-flag-from-2024, it probably belongs in a
  backend file rather than the core.
- Comments explain why, not what. A comment that restates the line below it
  will be removed; one that records a measurement, a trap, or the reason a
  default is what it is, will not.
