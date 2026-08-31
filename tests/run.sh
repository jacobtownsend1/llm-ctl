#!/usr/bin/env bash
# tests/run.sh — the whole test suite. No dependencies beyond bash and coreutils.
#
# Every container-runtime and HTTP call is served by a stub in tests/stubs, so
# these run anywhere: no GPU, no docker, no network, no model weights.
#
#   ./tests/run.sh            run everything
#   ./tests/run.sh port       run tests whose name matches "port"
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STUBS="$ROOT/tests/stubs"
PASS=0; FAIL=0; CURRENT=""
FILTER=${1:-}

red=$'\033[31m'; green=$'\033[32m'; dim=$'\033[2m'; rst=$'\033[0m'
[ -t 1 ] || { red=''; green=''; dim=''; rst=''; }

# ---- harness ----------------------------------------------------------------

setup() {
  TMP=$(mktemp -d)
  export LLMCTL_HOME="$TMP/config"
  export STUB_STATE="$TMP/state"
  export PATH="$STUBS:$PATH"
  export LLMCTL_COLOR=never LLMCTL_POLL_INTERVAL=1 LLMCTL_DU_TIMEOUT=1
  export LLMCTL_READY_TIMEOUT=4
  export STUB_SERVING="" STUB_PORTS_BUSY="" STUB_RUN_FAILS=0 STUB_RUN_DEAD=0
  unset LLMCTL_YES LLMCTL_JSON LLMCTL_QUIET LLMCTL_EXCLUSIVE LLMCTL_PORT 2>/dev/null
  mkdir -p "$LLMCTL_HOME/models.d" "$STUB_STATE" "$TMP/models/demo"
  cat >"$LLMCTL_HOME/config" <<EOF
LLM_HOME="$TMP"
HF_CACHE=""
EOF
}

teardown() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }

llm-ctl() { "$ROOT/bin/llm-ctl" "$@" 2>&1; }

have_image() { echo "$1" >>"$STUB_STATE/images"; }
serving()    { export STUB_SERVING="$*"; }

# Write a model conf. First arg is the name, stdin is the body.
model() { cat >"$LLMCTL_HOME/models.d/$1.conf"; }

fail() { printf '  %s✗%s %s\n    %s\n' "$red" "$rst" "$CURRENT" "$1"; FAIL=$((FAIL+1)); FAILED_THIS=1; }

assert_contains() {
  case "$1" in *"$2"*) return 0 ;; esac
  fail "expected to find: $2
    in output:
$(printf '%s' "$1" | sed 's/^/      /')"
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "did NOT expect: $2
    in output:
$(printf '%s' "$1" | sed 's/^/      /')" ;; esac
}
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_status() { [ "$1" = "$2" ] || fail "expected exit $2, got $1"; }

run_tests() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]] && continue
    CURRENT=${t#test_}; CURRENT=${CURRENT//_/ }
    FAILED_THIS=0
    setup
    "$t"
    teardown
    if [ "$FAILED_THIS" = 0 ]; then
      printf '  %s✓%s %s\n' "$green" "$rst" "$CURRENT"; PASS=$((PASS+1))
    fi
  done
}

# ---- fixtures ---------------------------------------------------------------

fixture_demo() {
  have_image "demo/image:1"
  model demo <<'EOF'
DESC="a demo model"
BACKEND=vllm
IMAGE="demo/image:1"
DIR="$LLM_HOME/models/demo"
ARGS=(--max-model-len 4096)
EOF
}

# ---- tests ------------------------------------------------------------------

test_ls_with_no_models_says_so() {
  local out; out=$(llm-ctl ls)
  assert_contains "$out" "no models defined"
  assert_contains "$out" "llm-ctl new"
}

test_ls_reports_a_ready_model() {
  fixture_demo
  local out; out=$(llm-ctl ls)
  assert_contains "$out" "demo"
  assert_contains "$out" "vllm"
  assert_contains "$out" "ready"
}

test_ls_reports_missing_image_and_weights() {
  model noimage <<'EOF'
DESC="x"
IMAGE="nope/nope:1"
DIR="$LLM_HOME/models/demo"
EOF
  model noweights <<'EOF'
DESC="x"
IMAGE="nope/nope:1"
DIR="/definitely/not/here"
EOF
  local out; out=$(llm-ctl ls)
  assert_contains "$out" "no image"
  assert_contains "$out" "no weights"
}

# One unusable definition must not take down commands that do not need it:
# loading a model reports an error, it does not exit.
test_one_broken_conf_does_not_break_ls() {
  fixture_demo
  model broken <<'EOF'
DESC="no IMAGE, no DIR"
EOF
  local out; out=$(llm-ctl ls)
  assert_contains "$out" "demo"       # the good one still lists
  assert_contains "$out" "invalid"
  assert_contains "$out" "broken"
}

test_config_prints_the_command_start_would_run() {
  fixture_demo
  local out; out=$(llm-ctl config demo)
  assert_contains "$out" "docker run -d"
  assert_contains "$out" "--label llm-ctl.model=demo"
  assert_contains "$out" "-p 127.0.0.1:8000:8000"
  assert_contains "$out" "demo/image:1"
  assert_contains "$out" "vllm serve /models/demo"
  assert_contains "$out" "--max-model-len 4096"
}

test_start_waits_for_the_server_then_reports_the_url() {
  fixture_demo; serving 8000
  local out; out=$(llm-ctl start demo)
  assert_contains "$out" "starting demo"
  assert_contains "$out" "serving on http://127.0.0.1:8000"
  assert_contains "$(llm-ctl status)" "model:     demo"
}

test_start_refuses_when_the_image_is_absent() {
  model demo <<'EOF'
IMAGE="missing/image:1"
DIR="$LLM_HOME/models/demo"
EOF
  local out rc
  out=$(llm-ctl start demo); rc=$?
  assert_status "$rc" 1
  assert_contains "$out" "image not present"
  assert_contains "$out" "docker pull missing/image:1"
}

test_start_reports_a_container_that_dies() {
  fixture_demo
  export STUB_RUN_DEAD=1
  local out rc
  out=$(llm-ctl start demo); rc=$?
  assert_status "$rc" 1
  assert_contains "$out" "died during startup"
  assert_contains "$out" "stub log line"
}

test_start_is_idempotent() {
  fixture_demo; serving 8000
  llm-ctl start demo >/dev/null
  local out; out=$(llm-ctl start demo)
  assert_contains "$out" "already running"
}

test_start_stops_the_other_model_when_exclusive() {
  fixture_demo; serving 8000
  have_image "other/image:1"
  model other <<'EOF'
IMAGE="other/image:1"
DIR="$LLM_HOME/models/demo"
EOF
  llm-ctl start demo >/dev/null
  local out; out=$(llm-ctl --yes start other)
  assert_contains "$out" "stopping demo"
  assert_contains "$out" "starting other"
}

test_start_refuses_without_consent_when_not_a_terminal() {
  fixture_demo; serving 8000
  have_image "other/image:1"
  model other <<'EOF'
IMAGE="other/image:1"
DIR="$LLM_HOME/models/demo"
EOF
  llm-ctl start demo >/dev/null
  local out rc
  out=$(llm-ctl start other </dev/null); rc=$?
  assert_status "$rc" 1
  assert_contains "$out" "--yes was not given"
  assert_not_contains "$out" "starting other"
}

test_non_exclusive_lets_models_on_different_ports_coexist() {
  fixture_demo; serving "8000 8001"
  have_image "other/image:1"
  model other <<'EOF'
IMAGE="other/image:1"
DIR="$LLM_HOME/models/demo"
MODEL_PORT=8001
EOF
  echo 'EXCLUSIVE=0' >>"$LLMCTL_HOME/config"
  llm-ctl start demo >/dev/null
  local out; out=$(llm-ctl start other)
  assert_not_contains "$out" "stopping demo"
  assert_contains "$out" "serving on http://127.0.0.1:8001"
  assert_contains "$(llm-ctl status)" "demo"
  assert_contains "$(llm-ctl status)" "other"
}

# MODEL_PORT has to reach both the published port and the engine's own flag.
# Honouring it in one place but not the other leaves a model that never looks
# ready no matter how long you wait.
test_model_port_reaches_both_the_publish_and_the_engine() {
  have_image "demo/image:1"
  model demo <<'EOF'
IMAGE="demo/image:1"
DIR="$LLM_HOME/models/demo"
MODEL_PORT=9001
EOF
  local out; out=$(llm-ctl config demo)
  assert_contains "$out" "-p 127.0.0.1:9001:9001"
  assert_contains "$out" "--port 9001"
  serving 9001
  assert_contains "$(llm-ctl start demo)" "serving on http://127.0.0.1:9001"
}

# A container llm-ctl did not start is not adopted just because its name looks
# familiar; the port preflight is what keeps the two from colliding.
test_a_foreign_container_is_not_adopted_by_name() {
  fixture_demo
  printf 'vllm-demo\t\tdemo/image:1\n' >>"$STUB_STATE/running"
  printf 'vllm-demo\t\tdemo/image:1\n' >>"$STUB_STATE/all"
  assert_contains "$(llm-ctl status)" "nothing running"
  export STUB_PORTS_BUSY=8000
  local out rc
  out=$(llm-ctl start demo); rc=$?
  assert_status "$rc" 1
  assert_contains "$out" "llm-ctl does not manage"
}

test_start_refuses_when_the_port_is_taken_by_a_stranger() {
  fixture_demo
  export STUB_PORTS_BUSY=8000
  local out rc
  out=$(llm-ctl start demo); rc=$?
  assert_status "$rc" 1
  assert_contains "$out" "port 8000 is already in use"
}

test_stop_stops_the_running_model() {
  fixture_demo; serving 8000
  llm-ctl start demo >/dev/null
  local out; out=$(llm-ctl stop)
  assert_contains "$out" "stopping demo"
  assert_contains "$(llm-ctl status)" "nothing running"
}

# The container llm-ctl would name and the container actually serving a model
# differ whenever a launcher named it. stop and logs must address the latter.
test_stop_and_logs_address_the_container_that_is_actually_up() {
  cat >"$LLMCTL_HOME/launch" <<EOF
#!/usr/bin/env bash
printf 'launcher-chose-this\t\text/image:1\n' >>"\$STUB_STATE/running"
printf 'launcher-chose-this\t\text/image:1\n' >>"\$STUB_STATE/all"
EOF
  cat >"$LLMCTL_HOME/stop" <<'EOF'
#!/usr/bin/env bash
grep -v '^launcher-chose-this	' "$STUB_STATE/running" >"$STUB_STATE/r.tmp" || :
mv "$STUB_STATE/r.tmp" "$STUB_STATE/running"
EOF
  chmod +x "$LLMCTL_HOME/launch" "$LLMCTL_HOME/stop"
  model ext <<EOF
BACKEND=external
IMAGE="ext/image:1"
DIR="\$LLM_HOME/models/demo"
MODEL_PORT=8888
CONTAINER_NAME="launcher-chose-this"
LAUNCHER="$LLMCTL_HOME/launch"
STOPPER="$LLMCTL_HOME/stop"
EOF
  serving 8888
  llm-ctl start ext >/dev/null
  assert_contains "$(llm-ctl status)" "container: launcher-chose-this"
  assert_contains "$(llm-ctl logs)" "stub log line"
  llm-ctl stop >/dev/null
  assert_contains "$(llm-ctl status)" "nothing running"
}

test_stop_with_nothing_running_is_not_an_error() {
  fixture_demo
  local out rc; out=$(llm-ctl stop); rc=$?
  assert_status "$rc" 0
  assert_contains "$out" "nothing running"
}

# restart has to resolve the model from what is running. Deriving it from the
# container name is wrong for any container llm-ctl did not name: it would stop
# the model and then fail to start anything.
test_restart_of_an_external_model_finds_the_right_model() {
  cat >"$LLMCTL_HOME/launch" <<EOF
#!/usr/bin/env bash
printf 'ext-head\t\text/image:1\n' >>"\$STUB_STATE/running"
printf 'ext-head\t\text/image:1\n' >>"\$STUB_STATE/all"
EOF
  cat >"$LLMCTL_HOME/stop" <<'EOF'
#!/usr/bin/env bash
grep -v '^ext-head	' "$STUB_STATE/running" >"$STUB_STATE/r.tmp" || :
mv "$STUB_STATE/r.tmp" "$STUB_STATE/running"
EOF
  chmod +x "$LLMCTL_HOME/launch" "$LLMCTL_HOME/stop"
  model ext <<EOF
DESC="two-node thing with its own launcher"
BACKEND=external
IMAGE="ext/image:1"
DIR="\$LLM_HOME/models/demo"
NODES=2
MODEL_PORT=8888
CONTAINER_NAME="ext-head"
LAUNCHER="$LLMCTL_HOME/launch"
STOPPER="$LLMCTL_HOME/stop"
EOF
  serving 8888
  llm-ctl start ext >/dev/null
  assert_contains "$(llm-ctl status)" "model:     ext"
  local out; out=$(llm-ctl restart)
  assert_contains "$out" "stopping ext"
  assert_contains "$out" "starting ext"
  assert_not_contains "$out" "unknown"
}

test_external_stop_uses_the_stopper() {
  cat >"$LLMCTL_HOME/launch" <<EOF
#!/usr/bin/env bash
printf 'ext-head\t\text/image:1\n' >>"\$STUB_STATE/running"
printf 'ext-head\t\text/image:1\n' >>"\$STUB_STATE/all"
EOF
  cat >"$LLMCTL_HOME/stop" <<'EOF'
#!/usr/bin/env bash
echo stopped >"$STUB_STATE/stopper-ran"
grep -v '^ext-head	' "$STUB_STATE/running" >"$STUB_STATE/r.tmp" || :
mv "$STUB_STATE/r.tmp" "$STUB_STATE/running"
EOF
  chmod +x "$LLMCTL_HOME/launch" "$LLMCTL_HOME/stop"
  model ext <<EOF
BACKEND=external
IMAGE="ext/image:1"
DIR="\$LLM_HOME/models/demo"
MODEL_PORT=8888
CONTAINER_NAME="ext-head"
LAUNCHER="$LLMCTL_HOME/launch"
STOPPER="$LLMCTL_HOME/stop"
EOF
  serving 8888
  llm-ctl start ext >/dev/null
  llm-ctl stop >/dev/null
  [ -f "$STUB_STATE/stopper-ran" ] || fail "STOPPER was not run"
}

# Container names are compared as strings, never as patterns: a name holding a
# regex character must not match containers it merely resembles.
test_container_names_with_regex_characters_are_matched_literally() {
  cat >"$LLMCTL_HOME/launch" <<EOF
#!/usr/bin/env bash
printf 'my.model+v1\t\tw/image:1\n' >>"\$STUB_STATE/running"
printf 'my.model+v1\t\tw/image:1\n' >>"\$STUB_STATE/all"
EOF
  chmod +x "$LLMCTL_HOME/launch"
  model weird <<EOF
BACKEND=external
IMAGE="w/image:1"
DIR="\$LLM_HOME/models/demo"
MODEL_PORT=8080
CONTAINER_NAME="my.model+v1"
LAUNCHER="$LLMCTL_HOME/launch"
STOPPER="/bin/true"
EOF
  # A container whose name the old regex would also have matched.
  printf 'myXmodelllv1\t\tw/image:1\n' >>"$STUB_STATE/running"
  printf 'myXmodelllv1\t\tw/image:1\n' >>"$STUB_STATE/all"
  serving 8080
  llm-ctl start weird >/dev/null
  local out; out=$(llm-ctl status)
  assert_contains "$out" "container: my.model+v1"
  assert_not_contains "$out" "myXmodelllv1"
}

test_status_json_is_valid_and_complete() {
  fixture_demo; serving 8000
  llm-ctl start demo >/dev/null
  local out; out=$(llm-ctl --json status)
  python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert len(d)==1, d
m=d[0]
assert m['model']=='demo', m
assert m['serving'] is True, m
assert m['port']==8000, m
assert m['url']=='http://127.0.0.1:8000', m
" "$out" 2>/dev/null || fail "not valid/complete JSON: $out"
}

test_ls_json_is_valid() {
  fixture_demo
  local out; out=$(llm-ctl --json ls)
  python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d[0]['name']=='demo' and d[0]['backend']=='vllm', d
" "$out" 2>/dev/null || fail "not valid JSON: $out"
}

test_logs_default_to_the_running_model() {
  fixture_demo; serving 8000
  llm-ctl start demo >/dev/null
  assert_contains "$(llm-ctl logs)" "stub log line"
}

test_a_user_backend_shadows_a_shipped_one() {
  have_image "demo/image:1"
  mkdir -p "$LLMCTL_HOME/backends"
  cat >"$LLMCTL_HOME/backends/vllm.sh" <<'EOF'
backend_describe() { printf 'my patched vllm'; }
backend_defaults() { BACKEND_ARGS=(--my-flag); }
backend_command()  { BACKEND_CMD=(my-vllm "$MODEL_TARGET"); }
EOF
  fixture_demo
  local out; out=$(llm-ctl config demo)
  assert_contains "$out" "my-vllm /models/demo"
  assert_contains "$out" "--my-flag"
  assert_contains "$(llm-ctl backends)" "user"
}

test_a_new_backend_needs_no_core_changes() {
  have_image "demo/image:1"
  mkdir -p "$LLMCTL_HOME/backends"
  cat >"$LLMCTL_HOME/backends/mlx.sh" <<'EOF'
backend_describe()    { printf 'MLX server'; }
backend_command()     { BACKEND_CMD=(mlx_lm.server --model "$MODEL_TARGET" --port "$PORT_IN"); }
backend_health_path() { printf '/health'; }
EOF
  model m <<'EOF'
BACKEND=mlx
IMAGE="demo/image:1"
DIR="$LLM_HOME/models/demo"
EOF
  local out; out=$(llm-ctl config m)
  assert_contains "$out" "mlx_lm.server"
  assert_contains "$out" "--model /models/m"
  assert_contains "$out" "--port 8000"
  assert_contains "$(llm-ctl backends)" "MLX server"
}

test_custom_backend_runs_the_given_argv() {
  have_image "demo/image:1"
  model c <<'EOF'
BACKEND=custom
IMAGE="demo/image:1"
DIR="$LLM_HOME/models/demo"
CMD=(my-server --model "{model}" --listen "0.0.0.0:{port}")
EOF
  local out; out=$(llm-ctl config c)
  assert_contains "$out" "my-server"
  assert_contains "$out" "--model /models/c"
  assert_contains "$out" "--listen 0.0.0.0:8000"
}

test_llamacpp_resolves_a_gguf_inside_the_directory() {
  have_image "gg/image:1"
  mkdir -p "$TMP/models/demo"
  : >"$TMP/models/demo/model-Q4_K_M.gguf"
  model gg <<'EOF'
BACKEND=llamacpp
IMAGE="gg/image:1"
DIR="$LLM_HOME/models/demo"
MODEL_FILE="model-Q4_K_M.gguf"
EOF
  local out; out=$(llm-ctl config gg)
  assert_contains "$out" "-m /models/gg/model-Q4_K_M.gguf"
  assert_contains "$out" "--alias gg"
}

test_llamacpp_accepts_a_path_straight_to_a_gguf() {
  have_image "gg/image:1"
  : >"$TMP/models/single.gguf"
  model gg <<'EOF'
BACKEND=llamacpp
IMAGE="gg/image:1"
DIR="$LLM_HOME/models/single.gguf"
EOF
  local out; out=$(llm-ctl config gg)
  assert_contains "$out" "-m /models/gg/single.gguf"
}

test_hf_model_is_passed_through_without_a_mount() {
  have_image "demo/image:1"
  model hub <<'EOF'
IMAGE="demo/image:1"
HF_MODEL="org/some-model"
EOF
  local out; out=$(llm-ctl config hub)
  assert_contains "$out" "vllm serve org/some-model"
  assert_not_contains "$out" ":/models/hub"
}

test_gpus_none_serves_on_cpu() {
  fixture_demo
  echo 'GPUS=none' >>"$LLMCTL_HOME/config"
  local out; out=$(llm-ctl config demo)
  assert_not_contains "$out" "--gpus"
}

test_api_key_reaches_the_engine_and_the_probe() {
  fixture_demo
  echo 'API_KEY=secret123' >>"$LLMCTL_HOME/config"
  assert_contains "$(llm-ctl config demo)" "--api-key secret123"
  assert_contains "$(llm-ctl env demo)" "OPENAI_API_KEY=secret123"
}

test_trust_remote_code_is_opt_in() {
  fixture_demo
  assert_not_contains "$(llm-ctl config demo)" "--trust-remote-code"
  model demo2 <<'EOF'
IMAGE="demo/image:1"
DIR="$LLM_HOME/models/demo"
TRUST_REMOTE_CODE=1
EOF
  assert_contains "$(llm-ctl config demo2)" "--trust-remote-code"
}

test_bind_defaults_to_loopback() {
  fixture_demo
  assert_contains "$(llm-ctl config demo)" "-p 127.0.0.1:8000:8000"
  echo 'BIND=0.0.0.0' >>"$LLMCTL_HOME/config"
  assert_contains "$(llm-ctl config demo)" "-p 0.0.0.0:8000:8000"
}

test_env_and_url_describe_the_running_server() {
  fixture_demo; serving 8000
  llm-ctl start demo >/dev/null
  assert_eq "$(llm-ctl url)" "http://127.0.0.1:8000/v1"
  assert_contains "$(llm-ctl env)" "export OPENAI_BASE_URL=http://127.0.0.1:8000/v1"
  assert_contains "$(llm-ctl env)" "export OPENAI_MODEL=demo"
}

test_new_scaffolds_a_conf_that_lints() {
  EDITOR='' llm-ctl new scaffolded >/dev/null
  [ -f "$LLMCTL_HOME/models.d/scaffolded.conf" ] || fail "conf not created"
  assert_contains "$(llm-ctl lint scaffolded)" "scaffolded"
}

test_new_tells_you_what_to_do_next() {
  local out; out=$(EDITOR='' llm-ctl new fresh)
  assert_contains "$out" "llm-ctl lint fresh"
  assert_contains "$out" "llm-ctl config fresh"
  assert_contains "$out" "llm-ctl help conf"
}

test_help_points_at_the_adding_a_model_path() {
  local out; out=$(llm-ctl help)
  assert_contains "$out" "adding a model:"
  assert_contains "$out" "docs/adding-a-model.md"
}

test_new_refuses_to_clobber() {
  fixture_demo
  local out rc; out=$(EDITOR='' llm-ctl new demo); rc=$?
  assert_status "$rc" 1
  assert_contains "$out" "already exists"
}

test_doctor_reports_on_the_machine() {
  fixture_demo
  local out; out=$(llm-ctl doctor)
  assert_contains "$out" "container runtime"
  assert_contains "$out" "docker 99.0-stub"
  assert_contains "$out" "1 model(s)"
  assert_contains "$out" "port 8000 is free"
  assert_contains "$out" "binding 127.0.0.1 (local only)"
}

test_doctor_warns_about_a_public_bind() {
  fixture_demo
  echo 'BIND=0.0.0.0' >>"$LLMCTL_HOME/config"
  assert_contains "$(llm-ctl doctor)" "reachable from the network"
}

test_unknown_command_exits_two() {
  local out rc; out=$(llm-ctl frobnicate); rc=$?
  assert_status "$rc" 2
  assert_contains "$out" "unknown command"
}

test_unknown_backend_is_reported_not_crashed() {
  model bogus <<'EOF'
BACKEND=nosuchengine
IMAGE="x/y:1"
DIR="/tmp"
EOF
  local out; out=$(llm-ctl ls)
  assert_contains "$out" "unknown backend"
}

test_help_conf_documents_the_schema() {
  local out; out=$(llm-ctl help conf)
  assert_contains "$out" "MODEL_PORT"
  assert_contains "$out" "HF_MODEL"
  assert_contains "$out" "BACKEND=external"
}

# ---- go ---------------------------------------------------------------------

printf '%sllm-ctl test suite%s\n' "$dim" "$rst"
run_tests
echo
if [ "$FAIL" -gt 0 ]; then
  printf '%s%d failed%s, %d passed\n' "$red" "$FAIL" "$rst" "$PASS"; exit 1
fi
printf '%s%d passed%s\n' "$green" "$PASS" "$rst"
