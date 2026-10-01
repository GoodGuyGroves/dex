#!/usr/bin/env bash
# DEX_HOME as the one state root (issue #7).
#
# lib/common.sh, hooks/dex_paths.py and scripts/dex-paths.cjs each resolve the
# same table. Hooks and Node scripts run without common.sh in a session Dex did
# not launch, so all four readers (bash, zsh, Python, Node) are run from
# `env -i` with only HOME and the mode's variables, and must agree. Then the
# readers wired to them, the writers that used to hardcode ~/.dex and
# ~/.claude, the cache defaults, and the doctor warning about a second root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-home-paths-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

SANDBOX_HOME="$TMP_DIR/home"
DH="$TMP_DIR/dex-home"
mkdir -p "$SANDBOX_HOME" "$DH"
NAMES=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import dex_paths; print(" ".join(dex_paths.PATHS))' "$ROOT/hooks")
[[ -n "$NAMES" ]] || assert_at $LINENO

# clean <VAR=value...> -- <command...> — a plain environment: no DX_*, no
# DEX_*, no CLAUDE_CONFIG_DIR, only HOME, PATH and what the mode names.
clean() {
  local assignments=()
  while [[ "$1" != "--" ]]; do assignments+=("$1"); shift; done
  shift
  env -i HOME="$SANDBOX_HOME" PATH="$PATH" TMPDIR="$TMP_DIR" DEX_DIR="$ROOT" \
    ${assignments[@]+"${assignments[@]}"} "$@"
}

# resolve <reader> <VAR=value...> — NAME=value for every entry in the table.
resolve() {
  local reader="$1"
  shift
  case "$reader" in
    bash)
      clean "$@" -- bash -c 'DX_COMMON_MODULES=output; source "$DEX_DIR/lib/common.sh"
        for n in '"$NAMES"'; do printf "%s=%s\n" "$n" "${!n}"; done' ;;
    zsh)
      clean "$@" -- zsh -fc 'DX_COMMON_MODULES=output; source "$DEX_DIR/lib/common.sh"
        for n in '"$NAMES"'; do print -r -- "$n=${(P)n}"; done' ;;
    python) clean "$@" -- python3 "$ROOT/hooks/dex_paths.py" ;;
    node) clean "$@" -- node "$ROOT/scripts/dex-paths.cjs" ;;
  esac
}

# check_mode <label> <expected DX_STATE_DIR> <expected DX_LOOP_DIR>
#   <expected DX_PROVIDER_GLOBAL_CONFIG> <VAR=value...>
check_mode() {
  local label="$1" state="$2" loops="$3" providers="$4" reader reference out
  shift 4
  reference=$(resolve bash "$@")
  assert_contains "DX_STATE_DIR=$state" <(printf '%s\n' "$reference")
  assert_contains "DX_LOOP_DIR=$loops" <(printf '%s\n' "$reference")
  assert_contains "DX_PROVIDER_GLOBAL_CONFIG=$providers" <(printf '%s\n' "$reference")
  [[ $(printf '%s\n' "$reference" | grep -c '=/') -eq $(wc -w <<<"$NAMES") ]] \
    || fail "$label: a path came out empty or relative: $reference"
  for reader in zsh python node; do
    if [[ "$reader" == node ]] && ! command -v node >/dev/null 2>&1; then
      continue
    fi
    out=$(resolve "$reader" "$@")
    assert_eq "$reference" "$out" "$label: $reader agrees with bash"
  done
}

check_mode unset "$SANDBOX_HOME/.claude/.dex-phases" "$SANDBOX_HOME/.claude/.dex-loops" \
  "$SANDBOX_HOME/.dex/providers.json"
check_mode set "$DH/state" "$DH/loops" "$DH/providers.json" DEX_HOME="$DH"
check_mode override "$DH/state" "$TMP_DIR/my-loops" "$TMP_DIR/mine.json" \
  DEX_HOME="$DH" DX_LOOP_DIR="$TMP_DIR/my-loops" DX_PROVIDER_GLOBAL_CONFIG="$TMP_DIR/mine.json"
# Empty counts as unset, for DEX_HOME and for each override: an empty
# DX_STATE_DIR once gave the guard handler a relative path.
check_mode empty "$SANDBOX_HOME/.claude/.dex-phases" "$SANDBOX_HOME/.claude/.dex-loops" \
  "$SANDBOX_HOME/.dex/providers.json" DEX_HOME= DX_STATE_DIR=
# A trailing / is dropped; a relative or `~` DEX_HOME is ignored everywhere.
check_mode trailing-slash "$DH/state" "$DH/loops" "$DH/providers.json" DEX_HOME="$DH//"
# shellcheck disable=SC2088  # the literal ~ is the case under test
for rejected in relative/dex '~/dex'; do
  check_mode "rejected $rejected" "$SANDBOX_HOME/.claude/.dex-phases" "$SANDBOX_HOME/.claude/.dex-loops" \
    "$SANDBOX_HOME/.dex/providers.json" DEX_HOME="$rejected"
  out=$(clean DEX_HOME="$rejected" -- bash -c 'DX_COMMON_MODULES=output; source "$DEX_DIR/lib/common.sh"; printf "%s\n" "${DEX_HOME-unset}"' 2>"$TMP_DIR/rejected.err")
  assert_eq unset "$out" "a rejected DEX_HOME is not passed on"
  assert_contains "Ignoring DEX_HOME=$rejected" "$TMP_DIR/rejected.err"
done

# Without DEX_HOME only the original five are exported, as before.
out=$(clean -- bash -c 'DX_COMMON_MODULES=output; source "$DEX_DIR/lib/common.sh"; env' | grep -v '^DX_PATHS_FROM=' | grep -cE '^(DX_[A-Z_]+|DEX_ROUTER_HOME)=' || true)
assert_eq 5 "$out" "unset DEX_HOME exports only the original five paths"

# A child that changes HOME or DEX_HOME resolves for its own values, not the
# ones its parent exported; a real override the parent carried still wins.
clean -- bash -c 'source "$DEX_DIR/lib/common.sh"
  HOME="$1" bash "$DEX_DIR/bin/setup.sh" --direct >/dev/null' _ "$TMP_DIR/home-b"
assert_file "$TMP_DIR/home-b/.dex/setup.json"
[[ ! -e "$SANDBOX_HOME/.dex" ]] || fail "HOME=B setup.sh wrote under the parent's HOME"
out=$(clean -- bash -c 'source "$DEX_DIR/lib/common.sh"
  HOME="$1" bash -c "DX_COMMON_MODULES=output; source \"\$DEX_DIR/lib/common.sh\"; printf \"%s\n\" \"\$DX_STATE_DIR\""' _ "$TMP_DIR/home-b")
assert_eq "$TMP_DIR/home-b/.claude/.dex-phases" "$out" "an exported default follows the child's HOME"
out=$(clean DEX_HOME="$DH" DX_LOOP_DIR="$TMP_DIR/my-loops" -- bash -c 'source "$DEX_DIR/lib/common.sh"
  DEX_HOME="$1" bash -c "DX_COMMON_MODULES=output; source \"\$DEX_DIR/lib/common.sh\"; printf \"%s|%s|%s\n\" \"\$DX_STATE_DIR\" \"\$DX_SETUP_FILE\" \"\$DX_LOOP_DIR\""' _ "$TMP_DIR/dex-home-2")
assert_eq "$TMP_DIR/dex-home-2/state|$TMP_DIR/dex-home-2/setup.json|$TMP_DIR/my-loops" "$out" \
  "child with another DEX_HOME"
out=$(clean DEX_HOME="$DH" -- bash -c 'source "$DEX_DIR/lib/common.sh"
  env -u DEX_HOME bash -c "DX_COMMON_MODULES=output; source \"\$DEX_DIR/lib/common.sh\"; printf \"%s|%s\n\" \"\$DX_STATE_DIR\" \"\${DEXCODE_CONFIG_DIR-unset}\""')
assert_eq "$SANDBOX_HOME/.claude/.dex-phases|unset" "$out" "child that drops DEX_HOME"

# Shell-only entries: DEXCODE_CONFIG_DIR keeps its XDG default when unset.
out=$(clean DEX_HOME="$DH" -- bash -c 'DX_COMMON_MODULES=output; source "$DEX_DIR/lib/common.sh"; printf "%s|%s\n" "$DEXCODE_CONFIG_DIR" "$DEX_HOME"')
assert_eq "$DH/dexcode|$DH" "$out" "DEXCODE_CONFIG_DIR under DEX_HOME"
out=$(clean -- bash -c 'DX_COMMON_MODULES=output; source "$DEX_DIR/lib/common.sh"; printf "%s\n" "${DEXCODE_CONFIG_DIR-unset}"')
assert_eq "unset" "$out" "DEXCODE_CONFIG_DIR is not exported without DEX_HOME"

# An interactive shell that sourced dx.sh before DEX_HOME was exported: the
# next dx command re-resolves, so in-shell state lands under the new root.
# An empty exported DEX_HOME ends up unset, like a rejected one.
clean -- zsh -fic 'source "$DEX_DIR/dx.sh" >/dev/null 2>&1
  export DEX_HOME="$1"
  dx provider use claude-subscription >/dev/null' _ "$TMP_DIR/late-home" </dev/null
assert_file "$TMP_DIR/late-home/providers.json"
[[ ! -e "$SANDBOX_HOME/.dex/providers.json" ]] || fail "dx kept the paths resolved before DEX_HOME was exported"
out=$(clean -- zsh -fc 'export DEX_HOME=""; DX_COMMON_MODULES=output; source "$DEX_DIR/lib/common.sh"; print -r -- "${DEX_HOME-unset}"')
assert_eq unset "$out" "an empty exported DEX_HOME is unset"

# ── Readers wired to the resolvers ──────────────────────────────────────────
out=$(clean DEX_HOME="$DH" -- python3 - "$ROOT/hooks/guard-handler.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard_handler", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module._heavy_command_cache_file())
print(module.provider_global_config_path())
PY
)
assert_eq "$DH/state/guard-heavy-commands.json
$DH/providers.json" "$out" "guard handler follows DEX_HOME in a plain session"

if command -v node >/dev/null 2>&1; then
  out=$(clean DEX_HOME="$DH" -- node -e 'console.log(require(process.argv[1]).root())' "$ROOT/scripts/ccr/state.cjs")
  assert_eq "$DH/router" "$out" "CCR state root follows DEX_HOME"
  out=$(clean DEX_HOME="$DH" PLAYWRIGHT_BROWSERS_PATH=/nix/browsers -- node -e '
    const env = { ...process.env }; require(process.argv[1]).caches(env);
    console.log(`${env.PLAYWRIGHT_BROWSERS_PATH}|${env.npm_config_cache}`);' "$ROOT/scripts/browser-mcp.cjs")
  assert_eq "/nix/browsers|$DH/tools/npm-cache" "$out" "browser MCP caches: user value wins, npm cache under tools"
  out=$(clean -- node -e '
    const env = { ...process.env }; require(process.argv[1]).caches(env);
    console.log(`${env.PLAYWRIGHT_BROWSERS_PATH || "-"}|${env.npm_config_cache || "-"}`);' "$ROOT/scripts/browser-mcp.cjs")
  assert_eq "-|-" "$out" "browser MCP leaves caches alone without DEX_HOME"
fi

# ── UI capture caches: only inside the spawn, only with DEX_HOME ────────────
out=$(clean DEX_HOME="$DH" -- bash -c 'source "$DEX_DIR/lib/common.sh"
  printf "%s|" "${PLAYWRIGHT_BROWSERS_PATH-none}"
  (__dx_ui_capture_export_caches; printf "%s|%s\n" "$PLAYWRIGHT_BROWSERS_PATH" "$npm_config_cache")')
assert_eq "none|$DH/tools/ms-playwright|$DH/tools/npm-cache" "$out" "caches set in the subshell, not by common.sh"
out=$(clean -- bash -c 'source "$DEX_DIR/lib/common.sh"
  (__dx_ui_capture_export_caches; printf "%s|%s\n" "${PLAYWRIGHT_BROWSERS_PATH-none}" "${npm_config_cache-none}")')
assert_eq "none|none" "$out" "no cache defaults without DEX_HOME"

# ── Writers land under DEX_HOME and nowhere in HOME ─────────────────────────
clean DEX_HOME="$DH" -- bash -c 'source "$DEX_DIR/lib/common.sh"
  dx_provider_command use claude-subscription >/dev/null
  dx_set_session_messaging_preference off
  [[ "$(dx_session_messaging_preference)" == off ]]' || assert_at $LINENO
clean DEX_HOME="$DH" -- bash "$ROOT/bin/setup.sh" --direct >/dev/null
assert_file "$DH/providers.json"
assert_file "$DH/setup.json"
assert_file "$DH/install-state.json"
[[ ! -e "$SANDBOX_HOME/.dex" && ! -e "$SANDBOX_HOME/.claude/.dex-install-state.json" ]] \
  || fail "a writer ignored DEX_HOME: $(find "$SANDBOX_HOME" -mindepth 1 | head)"
grep -q '"routing": "direct"' "$DH/setup.json" || assert_at $LINENO

# Unset, the same writers keep their legacy files.
clean -- bash "$ROOT/bin/setup.sh" --direct >/dev/null
assert_file "$SANDBOX_HOME/.dex/setup.json"
clean -- bash -c 'source "$DEX_DIR/lib/common.sh"; dx_set_session_messaging_preference on'
assert_file "$SANDBOX_HOME/.claude/.dex-install-state.json"

# ── dx doctor: live sessions under another root ─────────────────────────────
legacy_holder="$SANDBOX_HOME/.claude/.dex-loops/other-session.process"
mkdir -p "$legacy_holder"
printf '%s\n' "$$" > "$legacy_holder/holder"
clean DEX_HOME="$DH" -- bash "$ROOT/bin/doctor.sh" > "$TMP_DIR/doctor.out" 2>&1
assert_contains "1 live session(s) under $SANDBOX_HOME/.claude/.dex-loops" "$TMP_DIR/doctor.out"
assert_contains "Legacy install state" "$TMP_DIR/doctor.out"
clean -- bash "$ROOT/bin/doctor.sh" > "$TMP_DIR/doctor-unset.out" 2>&1
assert_not_contains "live session(s) under" "$TMP_DIR/doctor-unset.out"
printf '%s\n' "dead" > "$legacy_holder/holder"
clean DEX_HOME="$DH" -- bash "$ROOT/bin/doctor.sh" > "$TMP_DIR/doctor-dead.out" 2>&1
assert_not_contains "live session(s) under" "$TMP_DIR/doctor-dead.out"
assert_not_contains "is outside DEX_HOME" "$TMP_DIR/doctor-dead.out"
# An inherited legacy DX_LOOP_DIR splits the host's budget too.
clean DEX_HOME="$DH" DX_LOOP_DIR="$TMP_DIR/elsewhere" -- bash "$ROOT/bin/doctor.sh" > "$TMP_DIR/doctor-outside.out" 2>&1
assert_contains "DX_LOOP_DIR=$TMP_DIR/elsewhere is outside DEX_HOME=$DH" "$TMP_DIR/doctor-outside.out"

printf 'dex-home-paths tests passed\n'
