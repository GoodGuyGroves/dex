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

# Every network tool the guarded paths could reach logs its call and fails.
for tool in curl npm npx; do
  cat > "$TMP_DIR/bin/$tool" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$NET_LOG"
exit 1
STUB
  chmod +x "$TMP_DIR/bin/$tool"
done
export PATH="$TMP_DIR/bin:$PATH"
net_calls() { request_count "$NET_LOG"; }

# ── 2. DexCode and Factory sync ─────────────────────────────────────────────
# Offline wins over an explicit opt-in.
for check in dx_dexcode_sync_disabled dx_dexcode_context_sync_disabled dx_dexcode_factory_sync_disabled; do
  DEX_OFFLINE=1 DEXCODE_SYNC=1 DEXCODE_CONTEXT_SYNC=1 DEX_FACTORY_SYNC=true "$check" || assert_at $LINENO
done
rc=0; DEX_OFFLINE=1 DEX_FACTORY_SYNC=true DEX_FACTORY_URL=https://factory.invalid dx_factory_sync_requested || rc=$?
[[ "$rc" -ne 0 ]] || assert_at $LINENO
# Unset leaves each opt-out as it was.
rc=0; dx_dexcode_sync_disabled || rc=$?; [[ "$rc" -ne 0 ]] || assert_at $LINENO
rc=0; dx_dexcode_context_sync_disabled || rc=$?; [[ "$rc" -ne 0 ]] || assert_at $LINENO
DEXCODE_SYNC=0 dx_dexcode_sync_disabled || assert_at $LINENO
DEXCODE_CONTEXT_SYNC=off dx_dexcode_context_sync_disabled || assert_at $LINENO
DEX_FACTORY_SYNC=true dx_factory_sync_requested || assert_at $LINENO
DEX_FACTORY_URL=https://factory.invalid dx_factory_sync_requested || assert_at $LINENO
rc=0; DEX_FACTORY_SYNC=true dx_dexcode_factory_sync_disabled || rc=$?; [[ "$rc" -ne 0 ]] || assert_at $LINENO

# A connected project, a token and REQUIRED=1: offline still makes no call
# and does not fail the run; it says the requirement was ignored.
export DEXCODE_TOKEN="dxc_test_token_0123456789abcdef"
repo="$TMP_DIR/repo"
mkdir -p "$repo/.dex"
git -C "$repo" init -q
rc=0; DEX_OFFLINE=1 DEXCODE_SYNC=1 DEXCODE_SYNC_REQUIRED=1 \
  dx_dexcode_prepare_run_sync run_test1 "$repo" worktree ticket-1 "1" dx > "$OUT" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || assert_at $LINENO
assert_contains "DEXCODE_SYNC_REQUIRED=1 ignored: DEX_OFFLINE=1" "$OUT"
rc=0; DEX_OFFLINE=1 DEXCODE_CONTEXT_SYNC=1 DEXCODE_CONTEXT_SYNC_REQUIRED=1 \
  dx_dexcode_sync_project_context "$repo" > "$OUT" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || assert_at $LINENO
assert_contains "DEXCODE_CONTEXT_SYNC_REQUIRED=1 ignored: DEX_OFFLINE=1" "$OUT"
printf 'artifact\n' > "$TMP_DIR/artifact.txt"
DEX_OFFLINE=1 DEXCODE_SYNC=1 dx_dexcode_upload_artifact run_test1 "$TMP_DIR/artifact.txt" proof "Proof" > "$OUT" 2>&1 || assert_at $LINENO
assert_eq 0 "$(net_calls)" "network calls from offline DexCode sync"
# The required note stays quiet online.
rc=0; DEXCODE_SYNC=0 DEXCODE_SYNC_REQUIRED=1 dx_dexcode_prepare_run_sync run_test2 "$repo" worktree ticket-1 "1" dx > "$OUT" 2>&1 || rc=$?
assert_not_contains "ignored: DEX_OFFLINE" "$OUT"
unset DEXCODE_TOKEN

echo "offline-test: ok"
