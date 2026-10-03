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

# ── 3. RTK ──────────────────────────────────────────────────────────────────
# No RTK yet: the download is skipped and bootstrap still succeeds.
export DX_RTK_INSTALL_DIR="$TMP_DIR/rtk/bin"
: > "$NET_LOG"
DEX_OFFLINE=1 dx_install_rtk_binary > "$OUT" 2>&1 || assert_at $LINENO
assert_contains "RTK download skipped (DEX_OFFLINE=1)" "$OUT"
assert_eq 0 "$(net_calls)" "network calls from offline RTK install"
[[ ! -e "$DX_RTK_INSTALL_DIR/rtk" ]] || assert_at $LINENO
# An installed RTK keeps working: still enabled, still found, nothing fetched.
mkdir -p "$DX_RTK_INSTALL_DIR"
cat > "$DX_RTK_INSTALL_DIR/rtk" <<'RTK'
#!/usr/bin/env bash
if [[ "${1:-}" == "rewrite" && "${2:-}" == "git status" ]]; then
  printf 'rtk git status\n'
  exit 0
fi
exit 1
RTK
chmod +x "$DX_RTK_INSTALL_DIR/rtk"
DEX_OFFLINE=1 dx_rtk_enabled || assert_at $LINENO
DEX_OFFLINE=1 dx_install_rtk_binary > "$OUT" 2>&1 || assert_at $LINENO
assert_contains "RTK available at" "$OUT"
assert_not_contains "DEX_OFFLINE" "$OUT"
assert_eq "$DX_RTK_INSTALL_DIR/rtk" "$(DEX_OFFLINE=1 dx_rtk_resolved_binary)" "offline RTK resolution"
assert_eq 0 "$(net_calls)" "network calls with RTK installed"

# ── 4. Tools bootstrap ──────────────────────────────────────────────────────
# git is real, so a wrapper logs the subcommands that reach a remote and then
# runs it. claude and codex are present so the plugin and marketplace paths run.
real_git="$(command -v git)"
cat > "$TMP_DIR/bin/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    clone|fetch|ls-remote|pull) printf 'git %s\n' "\$*" >> "\$NET_LOG"; break ;;
  esac
done
exec "$real_git" "\$@"
STUB
for tool in claude codex; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/bin/$tool"
done
chmod +x "$TMP_DIR/bin/git" "$TMP_DIR/bin/claude" "$TMP_DIR/bin/codex"
# bash already hashed the real git for the repo set up above.
hash -r
# A dead remote: if a gate went missing the clone would fail, not quietly pass.
export DX_CLAUDE_OFFICIAL_MARKETPLACE_URL="https://127.0.0.1:1/offline-guard.git"
export DX_OPENAI_CODEX_MARKETPLACE_URL="https://127.0.0.1:1/offline-guard-codex.git"
registry="$(dx_dex_mcp_registry)"
rm -f "$registry"
: > "$NET_LOG"
rc=0; DEX_OFFLINE=1 dx_bootstrap_agent_tooling "$repo" install > "$OUT" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || { cat "$OUT" >&2; assert_at $LINENO; }
assert_eq 0 "$(net_calls)" "network calls from offline tools bootstrap"
assert_contains "UI capture tooling install skipped (DEX_OFFLINE=1)" "$OUT"
assert_contains "RTK available at" "$OUT"
assert_contains "not fetched (DEX_OFFLINE=1)" "$OUT"
assert_contains "OpenAI docs MCP (remote) not registered (DEX_OFFLINE=1)" "$OUT"
[[ ! -d "$(dx_dex_plugins_dir)/marketplaces" ]] || assert_at $LINENO
rc=0; dx_mcp_registry_has openaiDeveloperDocs || rc=$?
[[ "$rc" -ne 0 ]] || assert_at $LINENO
# Positive control: online, the same bootstrap does reach for the marketplace,
# so the zero above is the gate and not a blind wrapper.
: > "$NET_LOG"
dx_install_dex_marketplace "$DX_CLAUDE_OFFICIAL_MARKETPLACE_NAME" \
  "$DX_CLAUDE_OFFICIAL_MARKETPLACE_URL" "$DX_CLAUDE_OFFICIAL_MARKETPLACE_REF" > "$OUT" 2>&1 || true
assert_contains "git clone" "$NET_LOG"
rc=0; dx_install_openai_docs_mcp_servers > "$OUT" 2>&1 || rc=$?
dx_mcp_registry_has openaiDeveloperDocs || assert_at $LINENO

# ── 5. Launches ─────────────────────────────────────────────────────────────
# A registry an earlier online bootstrap filled: one remote server, one local.
mkdir -p "$(dirname "$registry")"
cat > "$registry" <<'JSON'
{"mcpServers": {
  "openaiDeveloperDocs": {"type": "http", "url": "https://developers.openai.com/mcp"},
  "playwright": {"command": "node", "args": ["browser-mcp.cjs", "playwright"]}
}}
JSON
cd "$repo"
launch_doc="$TMP_DIR/launch.json"
DEX_OFFLINE=1 dx_dex_launch_mcp_config > "$launch_doc"
assert_not_contains openaiDeveloperDocs "$launch_doc"
assert_contains playwright "$launch_doc"
dx_dex_launch_mcp_config > "$launch_doc"
assert_contains openaiDeveloperDocs "$launch_doc"
assert_contains playwright "$launch_doc"
DEX_OFFLINE=1 dx_dex_codex_mcp_overrides > "$launch_doc"
assert_not_contains openaiDeveloperDocs "$launch_doc"
assert_contains playwright "$launch_doc"
dx_dex_codex_mcp_overrides > "$launch_doc"
assert_contains openaiDeveloperDocs "$launch_doc"
# A project that names both servers for a phase gets only the local one.
printf '%s\n' '# Dex' '## MCP' '```yaml' 'implement: [openaiDeveloperDocs, playwright]' '```' > "$repo/.dex/dex.md"
scoped="$TMP_DIR/scoped.json"
mode=$(DEX_OFFLINE=1 dx_mcp_launch_config "$repo" 2 0 "$scoped" 2>"$OUT")
assert_eq scoped "$mode" "offline phase MCP mode"
assert_not_contains openaiDeveloperDocs "$scoped"
assert_contains playwright "$scoped"
mode=$(dx_mcp_launch_config "$repo" 2 0 "$scoped" 2>"$OUT")
assert_eq scoped "$mode" "online phase MCP mode"
assert_contains openaiDeveloperDocs "$scoped"
# The local-only flag is Dex's, not the caller's: a stray value online is ignored.
DX_MCP_LOCAL_ONLY=1 dx_dex_launch_mcp_config > "$launch_doc"
assert_contains openaiDeveloperDocs "$launch_doc"
cd "$ROOT"

# browser-mcp.cjs reads DEX_OFFLINE itself; it must agree with dx_offline.
if command -v node >/dev/null 2>&1; then
  for value in 1 true TRUE yes on On "" 0 false off 2 " 1"; do
    expected=online
    DEX_OFFLINE="$value" dx_offline && expected=offline
    actual=$(DEX_OFFLINE="$value" node -e '
      const m = require(process.argv[1]); const env = { ...process.env };
      const on = m.offline(env);
      console.log(on && env.npm_config_offline === "true" ? "offline" : (!on && !env.npm_config_offline ? "online" : "mixed"));
    ' "$ROOT/scripts/browser-mcp.cjs")
    assert_eq "$expected" "$actual" "browser-mcp offline parity for '$value'"
  done
fi

# ── 6. Commands whose whole job is the network refuse ───────────────────────
refuses() { # <label> <command...> — fails, says why, and calls nothing
  local label="$1" rc=0
  shift
  : > "$NET_LOG"
  "$@" > "$OUT" 2>&1 < /dev/null || rc=$?
  [[ "$rc" -ne 0 ]] || { cat "$OUT" >&2; fail "$label did not refuse offline"; }
  assert_contains "$label needs the network; unset DEX_OFFLINE to allow it" "$OUT"
  assert_eq 0 "$(net_calls)" "network calls from refused $label"
}
export DEX_OFFLINE=1
refuses "dx login" dx_dexcode_login --no-browser
refuses "dx dexcode use" dx_dexcode_command use
refuses "dx worker register" dx_worker_command register
refuses "dx worker run" dx_worker_command run
refuses "dx ui-capture install" bash "$ROOT/bin/ui-capture.sh" install
refuses "dx router install" bash "$ROOT/bin/router.sh" router install
refuses "dx router setup" bash "$ROOT/bin/router.sh" router setup
refuses "dx router update" bash "$ROOT/bin/router.sh" router update
if command -v zsh >/dev/null 2>&1; then
  refuses "dx run --spec-url" zsh -f -c 'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; dx run --spec-url https://dexcode.invalid/spec.json'
fi
# A capture that would have to install its tooling first refuses too.
storyboard="$TMP_DIR/story.json"
printf '{}\n' > "$storyboard"
rc=0; bash "$ROOT/bin/ui-capture.sh" capture --script "$storyboard" --after-url http://127.0.0.1:9/ > "$OUT" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || assert_at $LINENO
assert_contains "Installing UI capture tooling needs the network" "$OUT"
assert_contains "Local narration off (DEX_OFFLINE=1)" "$OUT"
# Local commands still run, and whoami skips its profile refresh.
: > "$NET_LOG"
dx_worker_command status > "$OUT" 2>&1 || true
assert_not_contains "needs the network" "$OUT"
DEXCODE_TOKEN="dxc_test_token_0123456789abcdef" dx_dexcode_whoami > "$OUT" 2>&1 || true
assert_not_contains "needs the network" "$OUT"
assert_eq 0 "$(net_calls)" "network calls from offline local commands"
unset DEX_OFFLINE
# Online, nothing is refused.
rc=0; dx_offline_refuse "dx login" > "$OUT" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || assert_at $LINENO

# ── 7. dx status ────────────────────────────────────────────────────────────
(cd "$repo" && DEX_OFFLINE=1 bash "$ROOT/bin/status.sh") > "$OUT" 2>&1 || true
grep -Eq '^  Network:[[:space:]]+offline \(DEX_OFFLINE=1\)' "$OUT" || { cat "$OUT" >&2; assert_at $LINENO; }
(cd "$repo" && bash "$ROOT/bin/status.sh") > "$OUT" 2>&1 || true
grep -Eq '^  Network:[[:space:]]+online$' "$OUT" || { cat "$OUT" >&2; assert_at $LINENO; }

echo "offline-test: ok"
