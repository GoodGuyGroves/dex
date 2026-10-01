#!/usr/bin/env bash
# Probe: how the real Claude Code (and optionally Codex) takes Dex's
# per-launch plugins and MCP servers. plugin-resolve-test.sh and
# mcp-registry-test.sh cover Dex's side offline; this checks what they assume:
# - a typescript-lsp plugin generated from a strict:false marketplace entry
#   loads from --plugin-dir (required);
# - a server from a non-strict --mcp-config is listed beside a user-scope one
#   (required);
# - with the same name in both, which one the session keeps (reported; Dex
#   leaves such names out of its launch config, so the user's wins either way);
# - nothing lands in ~/.claude/plugins/{cache,marketplaces,data} (required);
# - with DEX_PROBE_REAL_CODEX=1, whether `codex -c mcp_servers.<name>…`
#   reaches `codex mcp list` (reported).
#
# It runs only with DEX_PROBE_REAL_CLAUDE=1, needs a real `claude` and an
# ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN, and makes two short model
# calls. HOME, CLAUDE_CONFIG_DIR and CODEX_HOME point into a sandbox; the real
# ones are not read. The FINDINGS block at the end is the result to record.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

if [[ "${DEX_PROBE_REAL_CLAUDE:-0}" != 1 ]]; then
  printf '%s\n' 'SKIP: set DEX_PROBE_REAL_CLAUDE=1 to probe the real claude'
  exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
  printf '%s\n' 'SKIP: claude is not on PATH'
  exit 0
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  printf '%s\n' 'SKIP: the sandboxed probe needs ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN'
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-plugin-mcp-probe.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SANDBOX_HOME="$TMP_DIR/home"
REPO="$TMP_DIR/repo"
OUT="$TMP_DIR/stream.jsonl"
MARKET="$TMP_DIR/market"
mkdir -p "$SANDBOX_HOME/.claude" "$REPO" "$MARKET/.claude-plugin" "$MARKET/plugins/typescript-lsp"
git -C "$REPO" init -q
printf 'license\n' > "$MARKET/plugins/typescript-lsp/LICENSE"
# The official marketplace's typescript-lsp entry: strict:false, no plugin.json.
cat > "$MARKET/.claude-plugin/marketplace.json" <<'JSON'
{"name": "claude-plugins-official", "plugins": [
  {"name": "typescript-lsp", "description": "TypeScript/JavaScript language server",
   "version": "1.0.0", "source": "./plugins/typescript-lsp", "category": "development", "strict": false,
   "lspServers": {"typescript": {"command": "typescript-language-server", "args": ["--stdio"],
                                 "extensionToLanguage": {".ts": "typescript", ".js": "javascript"}}}}
]}
JSON
python3 "$ROOT/scripts/settings-json.py" resolve-plugins "$TMP_DIR" "$TMP_DIR/resolved" \
  typescript-lsp@market > "$TMP_DIR/resolve.out"
grep -qx 'ok typescript-lsp@market' "$TMP_DIR/resolve.out" || fail "resolve-plugins: $(cat "$TMP_DIR/resolve.out")"

# A user-scope server, and a launch config with one of its own plus a
# duplicate of the user's name. The commands never start a real server; a
# failed server is still listed by name.
printf '%s\n' '{"mcpServers":{"probeUser":{"command":"probe-user-mcp"},"probeDup":{"command":"probe-dup-user"}}}' \
  > "$SANDBOX_HOME/.claude/.claude.json"
printf '%s\n' '{"mcpServers":{"probeDex":{"command":"probe-dex-mcp"},"probeDup":{"command":"probe-dup-dex"}}}' \
  > "$TMP_DIR/launch-mcp.json"

run_claude() {
  (
    cd "$REPO"
    env -u DEX_HOME HOME="$SANDBOX_HOME" CLAUDE_CONFIG_DIR="$SANDBOX_HOME/.claude" DEX_LAUNCHED=1 \
      python3 "$ROOT/tests/test-timeout.py" 300 claude -p 'Reply with the single word DONE.' \
        --plugin-dir "$ROOT/plugin" "$@" --output-format stream-json --verbose \
        --dangerously-skip-permissions --permission-mode bypassPermissions < /dev/null
  ) > "$OUT" 2> "$TMP_DIR/claude.err" || { cat "$TMP_DIR/claude.err" >&2; fail 'claude -p failed'; }
}

# init <question> — read the init event of the last run.
init() {
  python3 - "$OUT" "$1" <<'PY'
import json, sys
init = {}
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("type") == "system" and event.get("subtype") == "init":
        init = event
        break
names = lambda items: sorted((item.get("name") if isinstance(item, dict) else str(item)) for item in items or [])
if sys.argv[2] == "plugins":
    print(" ".join(names(init.get("plugins"))))
elif sys.argv[2] == "mcp":
    print(" ".join(names(init.get("mcp_servers"))))
PY
}

FINDINGS=()
finding() { FINDINGS+=("$1: $2"); }
FAILED=()

run_claude --plugin-dir "$TMP_DIR/resolved/typescript-lsp" --mcp-config "$TMP_DIR/launch-mcp.json"
plugins=$(init plugins)
servers=$(init mcp)
finding plugins-loaded "$plugins"
finding mcp-servers-listed "$servers"
[[ " $plugins " == *" typescript-lsp "* ]] || FAILED+=("the generated typescript-lsp plugin did not load")
[[ " $servers " == *" probeDex "* ]] || FAILED+=("the --mcp-config server was not listed")
[[ " $servers " == *" probeUser "* ]] || FAILED+=("the user-scope server was dropped beside a non-strict --mcp-config")
finding duplicate-name-listed "$(grep -o 'probe-dup-[a-z]*' "$OUT" | sort -u | tr '\n' ' ')"

for leftover in cache marketplaces data; do
  [[ ! -e "$SANDBOX_HOME/.claude/plugins/$leftover" ]] || FAILED+=("Claude wrote ~/.claude/plugins/$leftover")
done
finding claude-plugins-dir "$(ls -A "$SANDBOX_HOME/.claude/plugins" 2>/dev/null | tr '\n' ' ')"

if [[ "${DEX_PROBE_REAL_CODEX:-0}" == 1 ]] && command -v codex >/dev/null 2>&1; then
  mkdir -p "$TMP_DIR/codex-home"
  codex_list=$(env HOME="$SANDBOX_HOME" CODEX_HOME="$TMP_DIR/codex-home" \
    python3 "$ROOT/tests/test-timeout.py" 60 codex \
      -c 'mcp_servers.probeDex.command="probe-dex-mcp"' -c 'mcp_servers.probeDex.args=[]' \
      mcp list < /dev/null 2>&1 || true)
  if grep -q probeDex <<<"$codex_list"; then
    finding codex-c-mcp-servers honoured
  else
    finding codex-c-mcp-servers "not listed: $(head -3 <<<"$codex_list" | tr '\n' ' ')"
  fi
fi

printf '%s\n' 'FINDINGS'
printf '  %s\n' "${FINDINGS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf 'probe failed: %s\n' "${FAILED[@]}" >&2
  exit 1
fi
printf 'plugin and MCP probe passed\n'
