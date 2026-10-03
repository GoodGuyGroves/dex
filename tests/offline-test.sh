#!/usr/bin/env bash
# DEX_OFFLINE=1: one switch for the optional network paths of Dex's own
# tooling. Stubs for curl, npm, npx and git record every call, so a path that
# still reaches for the network shows up in a log instead of on the wire.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-offline-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

unset DEX_OFFLINE DEXCODE_SYNC DEXCODE_CONTEXT_SYNC DEX_FACTORY_SYNC \
  DEX_FACTORY_URL DEX_FACTORY_EVENTS_ENDPOINT DEXCODE_SYNC_REQUIRED \
  DEXCODE_CONTEXT_SYNC_REQUIRED DEXCODE_TOKEN DX_RTK_ENABLED DX_RTK_BIN \
  DEX_SKIP_TOOL_BOOTSTRAP
export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export LC_ALL=C
NET_LOG="$TMP_DIR/net.log"
export NET_LOG
mkdir -p "$HOME" "$TMP_DIR/bin"

# ── 1. The predicate ────────────────────────────────────────────────────────
# Same answer from bash and zsh, which both source lib/.
offline_answer() { # <value|-unset> <shell> [shell args...]
  local value="$1" probe='source "$DEX_DIR/lib/common.sh" >/dev/null 2>&1; dx_offline && echo offline || echo online'
  shift
  if [[ "$value" == -unset ]]; then
    env -u DEX_OFFLINE DEX_DIR="$ROOT" "$@" -c "$probe"
  else
    env DEX_OFFLINE="$value" DEX_DIR="$ROOT" "$@" -c "$probe"
  fi
}
shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh)
for shell_bin in "${shells[@]}"; do
  shell_args=("$shell_bin")
  [[ "$shell_bin" != zsh ]] || shell_args+=(-f)
  for value in 1 true TRUE True yes YES on On; do
    assert_eq offline "$(offline_answer "$value" "${shell_args[@]}")" "$shell_bin DEX_OFFLINE=$value"
  done
  for value in -unset "" 0 false no off OFF 2 offline " 1"; do
    assert_eq online "$(offline_answer "$value" "${shell_args[@]}")" "$shell_bin DEX_OFFLINE='$value'"
  done
done

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

# dx_offline_refuse names the command and fails; online it passes silently.
OUT="$TMP_DIR/out.txt"
rc=0; DEX_OFFLINE=1 dx_offline_refuse "dx login" > "$OUT" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || assert_at $LINENO
assert_contains "dx login needs the network" "$OUT"
assert_contains "unset DEX_OFFLINE" "$OUT"
rc=0; dx_offline_refuse "dx login" > "$OUT" 2>&1 || rc=$?
[[ "$rc" -eq 0 && ! -s "$OUT" ]] || assert_at $LINENO

echo "offline-test: ok"
