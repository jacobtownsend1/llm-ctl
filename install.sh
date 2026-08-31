#!/usr/bin/env bash
# Install llm-ctl.
#
#   ./install.sh                  install for the current user
#   ./install.sh --prefix /usr/local   system-wide (needs write access)
#   ./install.sh --uninstall      remove it again
#
# The install is a symlink to this checkout by default, so `git pull` updates
# the tool. Pass --copy to install a snapshot instead.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
MODE=link
ACTION=install

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX=${2:?--prefix needs a directory}; shift 2 ;;
    --copy)      MODE=copy; shift ;;
    --uninstall) ACTION=uninstall; shift ;;
    -h|--help)   sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

BIN="$PREFIX/bin"
LIBEXEC="$PREFIX/lib/llm-ctl"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/llm-ctl"

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

if [ "$ACTION" = uninstall ]; then
  say "removing $BIN/llm-ctl and $LIBEXEC"
  rm -f "$BIN/llm-ctl"
  rm -rf "$LIBEXEC"
  echo
  echo "Your configuration in $CONFIG was left alone."
  echo "Remove it yourself if you want it gone."
  exit 0
fi

command -v bash >/dev/null || { echo "bash is required" >&2; exit 1; }
if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  warn "this shell is bash ${BASH_VERSION}; llm-ctl needs 4.4+ at run time"
fi

mkdir -p "$BIN"

if [ "$MODE" = link ]; then
  say "linking $BIN/llm-ctl -> $SRC/bin/llm-ctl"
  ln -sfn "$SRC/bin/llm-ctl" "$BIN/llm-ctl"
else
  say "copying into $LIBEXEC"
  rm -rf "$LIBEXEC"
  mkdir -p "$LIBEXEC"
  cp -r "$SRC/bin" "$SRC/lib" "$SRC/backends" "$SRC/completions" "$LIBEXEC/"
  ln -sfn "$LIBEXEC/bin/llm-ctl" "$BIN/llm-ctl"
fi

# First run: give them somewhere to put models, and a config to edit.
if [ ! -d "$CONFIG" ]; then
  say "creating $CONFIG"
  mkdir -p "$CONFIG/models.d" "$CONFIG/backends"
  cat > "$CONFIG/config" <<CONF
# llm-ctl global settings. Everything here has a default; uncomment to change.
# Environment variables (LLMCTL_PORT, LLMCTL_BIND, ...) override this file.

# Where your weights live. Model definitions refer to it as \$LLM_HOME.
LLM_HOME="\$HOME/llm"

# Port the server binds, and the address it is published on. 127.0.0.1 keeps
# it on this machine; 0.0.0.0 exposes it to your network, so set API_KEY too.
PORT=8000
BIND=127.0.0.1

# GPU passthrough: all, none, or a runtime-specific device spec.
GPUS=all

# One model at a time (the usual case with one accelerator). Set to 0 to let
# models on different ports run side by side.
EXCLUSIVE=1

# Seconds to wait for a server to answer before giving up. Big models on slow
# disks genuinely take minutes.
READY_TIMEOUT=900

# Sent to the engine and used when probing it. Set this if BIND is not local.
#API_KEY=""

# Shared HuggingFace cache, mounted into every container.
#HF_CACHE="\$LLM_HOME/hf-home"

# Flags added to every model, whatever the backend. Usually empty: a flag that
# is right for one engine is rarely right for another.
#COMMON_ARGS=()
CONF
fi

echo
say "installed"
echo "  llm-ctl       $BIN/llm-ctl"
echo "  config        $CONFIG/config"
echo "  models        $CONFIG/models.d/"
echo

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) warn "$BIN is not on your PATH — add it to your shell profile:"
     echo "    export PATH=\"$BIN:\$PATH\"" ;;
esac

cat <<'NEXT'
next:
  llm-ctl doctor          check this machine can actually serve a model
  llm-ctl new my-model    write your first model definition
  llm-ctl ls              see where things stand

shell completion:
  bash    eval "$(llm-ctl completion bash)"     # in ~/.bashrc
  zsh     eval "$(llm-ctl completion zsh)"      # in ~/.zshrc
  fish    llm-ctl completion fish | source      # in config.fish
NEXT
