#!/usr/bin/env bash
# Dex's MCP registry: the bootstrap writes servers there instead of the user's
# Claude or Codex configuration, and each launch reads it back without
# shadowing a server the user configured themselves.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-mcp-registry-test.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops" DX_RUN_ROOT="$TMP_DIR/runs"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts" DX_TOOL_DIR="$TMP_DIR/tools"
export CODEX_HOME="$HOME/.codex"
unset CLAUDE_CONFIG_DIR DEX_HOME DEX_UI_MCP_SCOPE DEX_SKIP_TOOL_BOOTSTRAP DEX_CODEX_HOME_WRITES
mkdir -p "$HOME/.claude" "$CODEX_HOME" "$TMP_DIR/bin"
HELPER="$ROOT/scripts/settings-json.py"
REGISTRY="$DX_TOOL_DIR/mcp-registry.json"

# claude and codex stubs that log every call and know no servers: any
# registration Dex still made with them would show in the log.
for cli in claude codex; do
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' \"\$*\" >> \"$TMP_DIR/$cli.log\"" \
    '[[ "${1:-}" != mcp ]] || exit 1' > "$TMP_DIR/bin/$cli"
  chmod +x "$TMP_DIR/bin/$cli"
done
export PATH="$TMP_DIR/bin:$PATH"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

# ── registry-set / registry-import ────────────────────────────────────────
assert_eq added "$(python3 "$HELPER" registry-set "$REGISTRY" docs https://example.test/mcp)" "first add"
assert_eq unchanged "$(python3 "$HELPER" registry-set "$REGISTRY" docs https://example.test/mcp)" "same entry"
assert_eq added "$(python3 "$HELPER" registry-set "$REGISTRY" tool node /x/tool.cjs tool)" "stdio add"
assert_eq updated "$(python3 "$HELPER" registry-set "$REGISTRY" tool node /x/tool.cjs other)" "replaced"
python3 - "$REGISTRY" <<'PY'
import json, sys
servers = json.load(open(sys.argv[1]))["mcpServers"]
assert servers["docs"] == {"type": "http", "url": "https://example.test/mcp"}, servers
assert servers["tool"] == {"command": "node", "args": ["/x/tool.cjs", "other"]}, servers
PY
if python3 "$HELPER" registry-set "$REGISTRY" 'bad name' x >/dev/null 2>&1; then
  fail "an invalid server name was accepted"
fi

printf '%s\n' '{"mcpServers":{"docs":{"url":"https://other"},"repoServer":{"command":"repo-mcp"}}}' \
  > "$TMP_DIR/repo.mcp.json"
assert_eq repoServer "$(python3 "$HELPER" registry-import "$REGISTRY" "$TMP_DIR/repo.mcp.json" --dry-run)" "dry run names the new one"
assert_not_contains repoServer "$REGISTRY"
assert_eq repoServer "$(python3 "$HELPER" registry-import "$REGISTRY" "$TMP_DIR/repo.mcp.json")" "import"
assert_contains repo-mcp "$REGISTRY"
assert_contains https://example.test/mcp "$REGISTRY"   # an existing entry is not overwritten
assert_eq "" "$(python3 "$HELPER" registry-import "$REGISTRY" "$TMP_DIR/repo.mcp.json")" "nothing left to import"

# ── launch-mcp: the user's own names win ──────────────────────────────────
mkdir -p "$TMP_DIR/repo"
REPO="$TMP_DIR/repo"
printf '%s\n' "{\"mcpServers\":{\"docs\":{\"command\":\"mine\"}},\"projects\":{\"$REPO\":{\"mcpServers\":{\"tool\":{\"command\":\"mine\"}}}}}" \
  > "$HOME/.claude.json"
printf '%s\n' '{"mcpServers":{"repoServer":{"command":"repo"}}}' > "$REPO/.mcp.json"
python3 "$HELPER" registry-set "$REGISTRY" playwright node /x/browser-mcp.cjs playwright >/dev/null
assert_eq '{"mcpServers":{"playwright":{"command":"node","args":["/x/browser-mcp.cjs","playwright"]}}}' \
  "$(python3 "$HELPER" launch-mcp "$REGISTRY" "$REPO")" "only the names the user lacks"
python3 "$HELPER" registry-names "$REGISTRY" > "$TMP_DIR/names"
assert_contains docs "$TMP_DIR/names"
# A user's broken ~/.claude.json does not stop a launch.
printf 'not json' > "$HOME/.claude.json"
python3 "$HELPER" launch-mcp "$REGISTRY" "$REPO" > "$TMP_DIR/broken-user.json"
assert_contains '"docs"' "$TMP_DIR/broken-user.json"
rm -f "$HOME/.claude.json"
assert_eq "" "$(python3 "$HELPER" launch-mcp "$TMP_DIR/no-registry.json" "$REPO")" "no registry, no config"

# ── codex-mcp-overrides ───────────────────────────────────────────────────
printf '%s\n' 'model = "gpt-5"' '' '[mcp_servers.tool]' 'command = "mine"' > "$CODEX_HOME/config.toml"
python3 "$HELPER" registry-set "$REGISTRY" envy node /x/e.cjs >/dev/null
python3 - "$REGISTRY" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["mcpServers"]["envy"]["env"] = {"TOKEN_FILE": "/x/token"}
data["mcpServers"]["dotted.name"] = {"command": "skip-me"}
json.dump(data, open(sys.argv[1], "w"))
PY
python3 "$HELPER" codex-mcp-overrides "$REGISTRY" "$CODEX_HOME/config.toml" > "$TMP_DIR/codex.overrides"
assert_contains 'mcp_servers.docs.url="https://example.test/mcp"' "$TMP_DIR/codex.overrides"
assert_contains 'mcp_servers.playwright.command="node"' "$TMP_DIR/codex.overrides"
assert_contains 'mcp_servers.playwright.args=["/x/browser-mcp.cjs", "playwright"]' "$TMP_DIR/codex.overrides"
assert_contains 'mcp_servers.envy.env={"TOKEN_FILE" = "/x/token"}' "$TMP_DIR/codex.overrides"
assert_not_contains 'mcp_servers.tool.' "$TMP_DIR/codex.overrides"     # the user's own wins
assert_not_contains 'skip-me' "$TMP_DIR/codex.overrides"               # not a TOML bare key

# Names the user defines inline in an [mcp_servers] table, or as top-level
# dotted keys, are theirs too.
printf '%s\n' 'mcp_servers.docs.url = "https://mine"' '[mcp_servers]' 'envy = { command = "mine" }' \
  > "$TMP_DIR/inline.toml"
python3 "$HELPER" codex-mcp-overrides "$REGISTRY" "$TMP_DIR/inline.toml" > "$TMP_DIR/inline.overrides"
assert_not_contains 'mcp_servers.docs.' "$TMP_DIR/inline.overrides"
assert_not_contains 'mcp_servers.envy.' "$TMP_DIR/inline.overrides"
assert_contains 'mcp_servers.playwright.command=' "$TMP_DIR/inline.overrides"

# Every value is valid TOML and reads back as written: quotes, backslashes,
# newlines and astral characters (emoji) included. Headers become http_headers.
python3 - "$TMP_DIR/odd.json" <<'PY'
import json, sys
odd = 'a "quoted" \\ back\nslash \U0001F600 é'
json.dump({"mcpServers": {
    "odd": {"command": odd, "args": [odd, "plain"], "env": {"K": odd}},
    "web": {"type": "sse", "url": "https://x.test/" + odd, "headers": {"Authorization": "Bearer " + odd}},
}}, open(sys.argv[1], "w"))
PY
python3 "$HELPER" codex-mcp-overrides "$TMP_DIR/odd.json" "$TMP_DIR/no-config.toml" > "$TMP_DIR/odd.overrides"
python3 - "$TMP_DIR/odd.overrides" <<'PY'
import sys
try:
    import tomllib  # Python 3.11+; macOS's system python3 is 3.9
except ImportError:
    print("skip: no tomllib for the TOML round-trip")
    raise SystemExit(0)
odd = 'a "quoted" \\ back\nslash \U0001F600 é'
servers = {}
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    key, _, value = line.partition("=")
    _, name, field = key.split(".")
    servers.setdefault(name, {})[field] = tomllib.loads("v = " + value)["v"]
assert servers["odd"] == {"command": odd, "args": [odd, "plain"], "env": {"K": odd}}, servers
assert servers["web"]["url"] == "https://x.test/" + odd, servers
assert servers["web"]["http_headers"] == {"Authorization": "Bearer " + odd}, servers
PY

# The registry import keeps an entry whole: type, headers and env.
printf '%s\n' '{"mcpServers":{"sse":{"type":"sse","url":"https://s","headers":{"X":"y"}}}}' > "$TMP_DIR/sse.mcp.json"
python3 "$HELPER" registry-import "$TMP_DIR/sse-registry.json" "$TMP_DIR/sse.mcp.json" >/dev/null
assert_contains '"type": "sse"' "$TMP_DIR/sse-registry.json"
assert_contains '"X": "y"' "$TMP_DIR/sse-registry.json"

# A server the user disabled, globally or for this project, stays off.
printf '%s\n' "{\"disabledMcpServers\":[\"docs\"],\"projects\":{\"$REPO\":{\"disabledMcpjsonServers\":[\"playwright\"]}}}" \
  > "$HOME/.claude.json"
python3 "$HELPER" launch-mcp "$REGISTRY" "$REPO" > "$TMP_DIR/disabled.json"
assert_not_contains '"docs"' "$TMP_DIR/disabled.json"
assert_not_contains '"playwright"' "$TMP_DIR/disabled.json"
assert_contains '"envy"' "$TMP_DIR/disabled.json"
# A linked worktree honours what was disabled for the main checkout, and a
# project's .claude/settings*.json disabledMcpjsonServers counts too.
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@example.test -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q --detach "$TMP_DIR/worktree"
WORKTREE=$(cd "$TMP_DIR/worktree" && pwd -P)
MAIN=$(cd "$REPO" && pwd -P)
printf '%s\n' "{\"projects\":{\"$MAIN\":{\"disabledMcpServers\":[\"envy\"]}}}" > "$HOME/.claude.json"
mkdir -p "$WORKTREE/.claude"
printf '%s\n' '{"disabledMcpjsonServers":["docs"]}' > "$WORKTREE/.claude/settings.local.json"
python3 "$HELPER" launch-mcp "$REGISTRY" "$WORKTREE" > "$TMP_DIR/worktree.json"
assert_not_contains '"envy"' "$TMP_DIR/worktree.json"
assert_not_contains '"docs"' "$TMP_DIR/worktree.json"
assert_contains '"playwright"' "$TMP_DIR/worktree.json"
rm -f "$HOME/.claude.json"

# Codex: with tomllib, quoted names, spaced headers and an inline table count.
if python3 -c 'import tomllib' 2>/dev/null; then
  printf '%s\n' "[mcp_servers.'docs']" 'url = "x"' '[ mcp_servers . "envy" ]' 'command = "y"' \
    > "$TMP_DIR/quoted.toml"
  python3 "$HELPER" codex-mcp-overrides "$REGISTRY" "$TMP_DIR/quoted.toml" > "$TMP_DIR/quoted.overrides"
  assert_not_contains 'mcp_servers.docs.' "$TMP_DIR/quoted.overrides"
  assert_not_contains 'mcp_servers.envy.' "$TMP_DIR/quoted.overrides"
  printf '%s\n' 'mcp_servers = { playwright = { command = "mine" } }' > "$TMP_DIR/inline-table.toml"
  python3 "$HELPER" codex-mcp-overrides "$REGISTRY" "$TMP_DIR/inline-table.toml" > "$TMP_DIR/inline-table.overrides"
  assert_not_contains 'mcp_servers.playwright.' "$TMP_DIR/inline-table.overrides"
fi
# DEL is escaped, and a lone surrogate (which no TOML escape can carry)
# becomes U+FFFD.
python3 - "$TMP_DIR/del.json" <<'PY'
import json, sys
json.dump({"mcpServers": {"del": {"command": "a\x7fb\ud800c"}}}, open(sys.argv[1], "w"))
PY
python3 "$HELPER" codex-mcp-overrides "$TMP_DIR/del.json" "$TMP_DIR/no-config.toml" > "$TMP_DIR/del.overrides"
assert_contains 'mcp_servers.del.command="a\u007fb\ufffdc"' "$TMP_DIR/del.overrides"

# ── the bootstrap writes the registry, never the CLIs' own configuration ──
rm -f "$REGISTRY"
dx_install_openai_docs_mcp_servers > "$TMP_DIR/docs.out"
assert_contains "Added MCP server 'openaiDeveloperDocs' to Dex's registry" "$TMP_DIR/docs.out"
(
  cd "$REPO"
  dx_install_claude_ui_mcp_servers
  dx_install_codex_ui_mcp_servers
) > "$TMP_DIR/ui.out"
python3 - "$REGISTRY" "$ROOT" <<'PY'
import json, sys
servers = json.load(open(sys.argv[1]))["mcpServers"]
assert servers["openaiDeveloperDocs"] == {"type": "http", "url": "https://developers.openai.com/mcp"}, servers
for name in ("playwright", "chrome-devtools"):
    assert servers[name] == {"command": "node", "args": [sys.argv[2] + "/scripts/browser-mcp.cjs", name]}, servers
PY
for cli in claude codex; do
  if [[ -f "$TMP_DIR/$cli.log" ]] && grep -q "mcp add" "$TMP_DIR/$cli.log"; then
    fail "$cli mcp add ran with the default dex scope"
  fi
done
# With DEX_HOME set, the browser entries carry it: a Codex launch starts them
# from the entry alone.
(
  cd "$REPO"
  DEX_HOME="$TMP_DIR/dex-home" dx_install_claude_ui_mcp_servers
) > /dev/null
python3 - "$REGISTRY" "$TMP_DIR/dex-home" <<'PY'
import json, sys
servers = json.load(open(sys.argv[1]))["mcpServers"]
for name in ("playwright", "chrome-devtools"):
    assert servers[name]["env"] == {"DEX_HOME": sys.argv[2]}, servers[name]
PY
python3 "$HELPER" codex-mcp-overrides "$REGISTRY" "$TMP_DIR/no-config.toml" > "$TMP_DIR/dex-home.overrides"
assert_contains "mcp_servers.playwright.env={\"DEX_HOME\" = \"$TMP_DIR/dex-home\"}" "$TMP_DIR/dex-home.overrides"
dx_check_ui_capture_tooling > "$TMP_DIR/check.out" 2>&1 || true
assert_contains "MCP server 'playwright' loads in Dex launches (Dex registry)" "$TMP_DIR/check.out"
dx_check_openai_docs_mcp_servers > "$TMP_DIR/docs-check.out"
assert_contains "loads in Dex launches" "$TMP_DIR/docs-check.out"
# An explicit scope still registers with the CLI.
(
  cd "$REPO"
  dx_install_claude_ui_mcp_servers user
) >/dev/null 2>&1 || true
assert_contains "mcp add --scope user playwright -- node" "$TMP_DIR/claude.log"

# ── one opt-out turns every install off ───────────────────────────────────
: > "$TMP_DIR/claude.log"
(
  dx_install_ui_capture_tooling() { fail "ui-capture install ran under DEX_SKIP_TOOL_BOOTSTRAP"; }
  dx_install_safe_official_claude_plugins() { fail "plugin install ran under DEX_SKIP_TOOL_BOOTSTRAP"; }
  DEX_SKIP_TOOL_BOOTSTRAP=1 dx_bootstrap_agent_tooling "$REPO" install
) > "$TMP_DIR/skip.out"
assert_contains "DEX_SKIP_TOOL_BOOTSTRAP=1" "$TMP_DIR/skip.out"

# ── Codex home writes are opt-in ──────────────────────────────────────────
(
  dx_install_ui_capture_tooling() { return 0; }
  dx_install_rtk_binary() { return 0; }
  dx_install_safe_official_claude_plugins() { return 0; }
  dx_bootstrap_agent_tooling "$REPO" install
) > "$TMP_DIR/no-codex-home.out" 2>&1 || true
assert_contains "opt-in ('dx tools bootstrap --codex-home')" "$TMP_DIR/no-codex-home.out"
assert_no_file "$CODEX_HOME/skills"
assert_no_file "$CODEX_HOME/RTK.md"
(
  dx_install_ui_capture_tooling() { return 0; }
  dx_install_rtk_binary() { return 0; }
  dx_install_safe_official_claude_plugins() { return 0; }
  DEX_CODEX_HOME_WRITES=1 dx_bootstrap_agent_tooling "$REPO" install
) > "$TMP_DIR/codex-home.out" 2>&1 || true
assert_dir "$CODEX_HOME/skills"
# The opt-in is remembered, so later checks and the doctor know about it.
assert_file "$DX_TOOL_DIR/codex-home-writes"
dx_codex_home_writes_enabled || assert_at $LINENO
if DEX_CODEX_HOME_WRITES=0 dx_codex_home_writes_enabled; then
  fail "DEX_CODEX_HOME_WRITES=0 did not override the recorded opt-in"
fi
# --no-codex-home forgets the choice and takes back what it wrote. (The
# bootstrap itself is skipped; the opt-out runs before it.)
DEX_SKIP_TOOL_BOOTSTRAP=1 bash "$ROOT/bin/tools.sh" bootstrap --no-codex-home > "$TMP_DIR/no-codex-home.out" 2>&1
assert_no_file "$DX_TOOL_DIR/codex-home-writes"
[[ -z "$(find "$CODEX_HOME/skills" -type l 2>/dev/null)" ]] || assert_at $LINENO
# Without an explicit opt-in nothing is recorded, even with codex present.
(
  dx_install_ui_capture_tooling() { return 0; }
  dx_install_rtk_binary() { return 0; }
  dx_install_safe_official_claude_plugins() { return 0; }
  dx_bootstrap_agent_tooling "$REPO" install
) > /dev/null 2>&1 || true
assert_no_file "$DX_TOOL_DIR/codex-home-writes"

printf 'mcp registry tests passed\n'
