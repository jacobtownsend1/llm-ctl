#!/usr/bin/env bash
# core.sh — output helpers and small utilities. No llm-ctl-specific state here.

# Colour is on when stdout is a terminal, unless overridden. NO_COLOR is
# honoured (https://no-color.org).
_llmctl_init_colour() {
  local want=${LLMCTL_COLOR:-auto}
  case "$want" in
    never) want=off ;;
    always) want=on ;;
    *)
      if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then want=off; else want=on; fi
      ;;
  esac
  if [ "$want" = on ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
  else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
  fi
}
_llmctl_init_colour

# All diagnostics go to stderr so `--json` and pipelines stay clean.
error() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
warn()  { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }
info()  { [ "${LLMCTL_QUIET:-0}" = 1 ] || printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()    { [ "${LLMCTL_QUIET:-0}" = 1 ] || printf '%s ok %s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
debug() { [ "${LLMCTL_DEBUG:-0}" = 1 ] && printf '%s[debug]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; return 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# Ask before doing something disruptive. Non-interactive callers must pass
# --yes / set LLMCTL_YES=1; with no tty and no consent we refuse rather than
# silently proceeding.
confirm() {
  local prompt=$1
  [ "${LLMCTL_YES:-0}" = 1 ] && return 0
  if [ ! -t 0 ]; then
    error "$prompt"
    error "not a terminal and --yes was not given; refusing to proceed"
    return 1
  fi
  local reply
  read -rp "$(printf '%s%s [y/N] %s' "$C_YELLOW" "$prompt" "$C_RESET")" reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Truncate to width, keeping the informative tail (image tags are back-heavy).
tail_trunc() {
  local s=$1 w=$2
  if [ "${#s}" -gt "$w" ]; then printf '…%s' "${s: -$((w-1))}"; else printf '%s' "$s"; fi
}

# Directory size, human readable. Bounded so a cold cache or a network mount
# cannot hang `ls`; returns "-" if it takes too long or does not exist.
dir_size() {
  local p=$1
  [ -e "$p" ] || { printf '-'; return; }
  local out
  out=$(timeout "${LLMCTL_DU_TIMEOUT:-3}" du -sh "$p" 2>/dev/null | cut -f1)
  printf '%s' "${out:--}"
}

json_escape() {
  local s=$1 out='' i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    # shellcheck disable=SC1003  # the '\' branch is a literal backslash
    case "$c" in
      '"')  out+='\"' ;;
      '\')  out+='\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *)
        if [[ "$c" < $'\x20' ]]; then printf -v c '\\u%04x' "'$c"; fi
        out+="$c"
        ;;
    esac
  done
  printf '%s' "$out"
}

# Print "key":"value" pairs as a JSON object. Args are alternating key/value;
# a key suffixed with @ is emitted raw (numbers, booleans, nested JSON).
json_obj() {
  local out='{' first=1 k v
  while [ $# -gt 0 ]; do
    k=$1; v=${2-}; shift 2
    [ $first = 1 ] || out+=','
    first=0
    if [ "${k%@}" != "$k" ]; then
      out+="\"$(json_escape "${k%@}")\":${v:-null}"
    else
      out+="\"$(json_escape "$k")\":\"$(json_escape "$v")\""
    fi
  done
  printf '%s}' "$out"
}

# Quote an argv for display so `llm-ctl config` output is copy-pasteable.
shell_quote() {
  local a out=''
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then out+="$a "
    else out+="'${a//\'/\'\\\'\'}' "; fi
  done
  printf '%s' "${out% }"
}
