#!/usr/bin/env bash
# Per-launch plugins: the bootstrap clones the allowlisted marketplaces at a
# pinned commit under DX_TOOL_DIR, resolves each plugin into a directory a
# --plugin-dir can load (generating plugin.json for strict:false entries), and
# a launch passes the ones the repository selects. Nothing is installed with
# `claude plugin`, and nothing lands under ~/.claude/plugins. Offline: the
# marketplace is a local git repository built here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-plugin-resolve-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops" DX_RUN_ROOT="$TMP_DIR/runs"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts" DX_TOOL_DIR="$TMP_DIR/tools"
export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset CLAUDE_CONFIG_DIR DEX_HOME DEX_EXTRA_SETTINGS DEX_LAUNCHED DEX_SESSION_ID DEX_SKIP_TOOL_BOOTSTRAP
mkdir -p "$HOME/.claude" "$TMP_DIR/bin"
: > "$GIT_CONFIG_GLOBAL"

# ── the fixture marketplace ───────────────────────────────────────────────
MARKET="$TMP_DIR/market"
mkdir -p "$MARKET/.claude-plugin" "$MARKET/plugins/frontend-design/.claude-plugin" \
  "$MARKET/plugins/frontend-design/skills/design" "$MARKET/plugins/typescript-lsp" \
  "$MARKET/plugins/pyright-lsp" "$MARKET/plugins/gopls-lsp" "$MARKET/plugins/rust-analyzer-lsp"
printf '%s\n' '{"name":"frontend-design"}' > "$MARKET/plugins/frontend-design/.claude-plugin/plugin.json"
printf '%s\n' '---' 'name: design' 'description: d' '---' > "$MARKET/plugins/frontend-design/skills/design/SKILL.md"
for plugin in typescript-lsp pyright-lsp gopls-lsp rust-analyzer-lsp; do
  printf 'license\n' > "$MARKET/plugins/$plugin/LICENSE"
done
cat > "$MARKET/.claude-plugin/marketplace.json" <<'JSON'
{"name": "claude-plugins-official", "plugins": [
  {"name": "frontend-design", "source": "./plugins/frontend-design", "category": "development"},
  {"name": "typescript-lsp", "source": "./plugins/typescript-lsp", "version": "1.0.0", "strict": false,
   "category": "development",
   "lspServers": {"typescript": {"command": "typescript-language-server", "args": ["--stdio"],
                                 "extensionToLanguage": {".ts": "typescript"}}}},
  {"name": "pyright-lsp", "source": "./plugins/pyright-lsp", "strict": false,
   "lspServers": {"pyright": {"command": "pyright-langserver", "env": {"X": "${CLAUDE_PLUGIN_DATA}"}}}},
  {"name": "gopls-lsp", "source": "./plugins/gopls-lsp", "strict": false, "commands": "./commands"},
  {"name": "rust-analyzer-lsp", "source": "./plugins/rust-analyzer-lsp"}
]}
JSON
git -C "$MARKET" init -q
git -C "$MARKET" -c user.email=t@example.test -c user.name=t add -A
git -C "$MARKET" -c user.email=t@example.test -c user.name=t commit -q -m one
PIN=$(git -C "$MARKET" rev-parse HEAD)
printf 'later\n' > "$MARKET/later.txt"
git -C "$MARKET" -c user.email=t@example.test -c user.name=t add -A
git -C "$MARKET" -c user.email=t@example.test -c user.name=t commit -q -m two
export DX_CLAUDE_OFFICIAL_MARKETPLACE_URL="$MARKET" DX_CLAUDE_OFFICIAL_MARKETPLACE_REF="$PIN"

# A claude stub that records launches and refuses every `claude plugin` call,
# and no codex on PATH (so the Codex marketplace is not wanted).
cat > "$TMP_DIR/bin/claude" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == plugin ]]; then printf '%s\n' "\$*" >> "$TMP_DIR/plugin-calls.log"; exit 1; fi
printf '%s\n' "\$@" > "$TMP_DIR/launch.argv"
SH
chmod +x "$TMP_DIR/bin/claude"
export PATH="$TMP_DIR/bin:$PATH"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

# ── install: clone at the pin, resolve, refuse the unsafe entries ─────────
dx_install_safe_official_claude_plugins > "$TMP_DIR/install.out" 2>&1 || true
CLONE="$DX_TOOL_DIR/plugins/marketplaces/claude-plugins-official"
RESOLVED="$DX_TOOL_DIR/plugins/resolved"
assert_eq "$PIN" "$(git -C "$CLONE" rev-parse HEAD)" "marketplace checked out at its pin"
assert_no_file "$CLONE/later.txt"
assert_contains "ready to load in Dex launches: frontend-design@claude-plugins-official, typescript-lsp@claude-plugins-official" "$TMP_DIR/install.out"
assert_contains "pyright-lsp@claude-plugins-official: it uses CLAUDE_PLUGIN_DATA" "$TMP_DIR/install.out"
assert_contains "gopls-lsp@claude-plugins-official: its commands names a path" "$TMP_DIR/install.out"
assert_contains "rust-analyzer-lsp@claude-plugins-official: it has no plugin.json" "$TMP_DIR/install.out"
assert_no_file "$TMP_DIR/plugin-calls.log"
assert_no_file "$HOME/.claude/plugins"

# A plugin with a manifest is linked; a strict:false one gets a generated
# manifest (the entry minus its marketplace-only keys) beside links to its files.
[[ -L "$RESOLVED/frontend-design" ]] || assert_at $LINENO
assert_file "$RESOLVED/frontend-design/skills/design/SKILL.md"
[[ ! -L "$RESOLVED/typescript-lsp" && -L "$RESOLVED/typescript-lsp/LICENSE" ]] || assert_at $LINENO
python3 - "$RESOLVED/typescript-lsp/.claude-plugin/plugin.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
assert manifest["name"] == "typescript-lsp" and manifest["version"] == "1.0.0", manifest
assert manifest["lspServers"]["typescript"]["command"] == "typescript-language-server", manifest
for key in ("source", "strict", "category"):
    assert key not in manifest, manifest
PY
assert_no_file "$RESOLVED/pyright-lsp"
assert_no_file "$RESOLVED/gopls-lsp"

# A second run is a no-op at the pin, and moves to a new pin when it changes.
dx_install_safe_official_claude_plugins > "$TMP_DIR/again.out" 2>&1 || true
assert_contains "is at its pinned commit" "$TMP_DIR/again.out"
NEW_PIN=$(git -C "$MARKET" rev-parse HEAD)
DX_CLAUDE_OFFICIAL_MARKETPLACE_REF="$NEW_PIN" dx_install_safe_official_claude_plugins > /dev/null 2>&1 || true
assert_eq "$NEW_PIN" "$(git -C "$CLONE" rev-parse HEAD)" "pin bump moves the clone"
assert_file "$CLONE/later.txt"
# A pin that does not exist fails loudly and leaves the clone where it was.
if DX_CLAUDE_OFFICIAL_MARKETPLACE_REF=0000000000000000000000000000000000000000 \
    dx_install_safe_official_claude_plugins > "$TMP_DIR/bad-pin.out" 2>&1; then
  fail "an unknown pinned commit was accepted"
fi
assert_contains "Could not check out Claude plugin marketplace" "$TMP_DIR/bad-pin.out"
assert_eq "$NEW_PIN" "$(git -C "$CLONE" rev-parse HEAD)" "a bad pin leaves the clone alone"

# ── launch: one --plugin-dir per plugin the repository selects ────────────
REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
printf '{"dependencies":{"react":"1"}}\n' > "$REPO/package.json"
printf 'x\n' > "$REPO/main.py"
launch() {
  (
    cd "$REPO"
    export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=claude DX_PROVIDER_PROFILE_RESOLVED=claude
    dx_provider_claude -p task
  )
}
launch
assert_contains "$RESOLVED/frontend-design" "$TMP_DIR/launch.argv"
assert_contains "$RESOLVED/typescript-lsp" "$TMP_DIR/launch.argv"
assert_not_contains "$RESOLVED/pyright-lsp" "$TMP_DIR/launch.argv"   # refused, so never resolved
assert_eq "--plugin-dir" "$(sed -n '3p' "$TMP_DIR/launch.argv")" "Dex's own plugin first"
assert_eq "$DEX_DIR/plugin" "$(sed -n '4p' "$TMP_DIR/launch.argv")" "Dex's own plugin first"
assert_eq "3" "$(grep -cx -- '--plugin-dir' "$TMP_DIR/launch.argv" | tr -d '[:space:]')" "dex plus two"

# A plugin the user enabled themselves is not loaded a second time.
printf '%s\n' '{"enabledPlugins":{"typescript-lsp@claude-plugins-official":true}}' > "$HOME/.claude/settings.json"
launch
assert_not_contains "$RESOLVED/typescript-lsp" "$TMP_DIR/launch.argv"
assert_contains "$RESOLVED/frontend-design" "$TMP_DIR/launch.argv"

# A plugin the user turned off, in any settings layer, stays off.
printf '%s\n' '{}' > "$HOME/.claude/settings.json"
mkdir -p "$REPO/.claude"
printf '%s\n' '{"enabledPlugins":{"frontend-design@claude-plugins-official":false}}' > "$REPO/.claude/settings.local.json"
launch
assert_not_contains "$RESOLVED/frontend-design" "$TMP_DIR/launch.argv"
assert_contains "$RESOLVED/typescript-lsp" "$TMP_DIR/launch.argv"
rm -f "$REPO/.claude/settings.local.json"

# The check reports the resolved plugins without asking `claude plugin`.
dx_check_safe_official_claude_plugins "$REPO" > "$TMP_DIR/check.out" 2>&1 || true
assert_contains "Claude plugin 'frontend-design@claude-plugins-official' available" "$TMP_DIR/check.out"

# ── a clone that drifted is brought back ──────────────────────────────────
# Edits and untracked files go; a directory that is not a git clone is
# replaced; a changed URL is followed.
PIN=$NEW_PIN
export DX_CLAUDE_OFFICIAL_MARKETPLACE_REF="$PIN"
printf 'edited\n' > "$CLONE/later.txt"
printf 'stray\n' > "$CLONE/untracked.txt"
dx_install_safe_official_claude_plugins > "$TMP_DIR/dirty.out" 2>&1 || true
assert_eq "later" "$(cat "$CLONE/later.txt")" "local edit discarded"
assert_no_file "$CLONE/untracked.txt"

rm -rf "${CLONE:?}/.git"
printf 'not a clone\n' > "$CLONE/junk.txt"
dx_install_safe_official_claude_plugins > "$TMP_DIR/no-git.out" 2>&1 || true
assert_eq "$PIN" "$(git -C "$CLONE" rev-parse HEAD)" "a non-clone is replaced"
assert_no_file "$CLONE/junk.txt"

# An empty .git is no clone either.
rm -rf "${CLONE:?}/.git"
mkdir "$CLONE/.git"
dx_install_safe_official_claude_plugins > "$TMP_DIR/empty-git.out" 2>&1 || true
assert_eq "$PIN" "$(git -C "$CLONE" rev-parse HEAD)" "an empty .git is re-cloned"

MOVED="$TMP_DIR/market-moved"
git clone -q "$MARKET" "$MOVED"
printf 'moved\n' > "$MOVED/moved.txt"
git -C "$MOVED" -c user.email=t@example.test -c user.name=t add -A
git -C "$MOVED" -c user.email=t@example.test -c user.name=t commit -q -m moved
MOVED_PIN=$(git -C "$MOVED" rev-parse HEAD)
DX_CLAUDE_OFFICIAL_MARKETPLACE_URL="$MOVED" DX_CLAUDE_OFFICIAL_MARKETPLACE_REF="$MOVED_PIN" \
  dx_install_safe_official_claude_plugins > "$TMP_DIR/moved.out" 2>&1 || true
assert_eq "$MOVED" "$(git -C "$CLONE" remote get-url origin)" "origin follows the URL"
assert_eq "$MOVED_PIN" "$(git -C "$CLONE" rev-parse HEAD)" "the new pin comes from the new URL"

# ── what resolve-plugins refuses ──────────────────────────────────────────
EVIL="$TMP_DIR/evil-markets/evil"
OUTSIDE="$TMP_DIR/outside"
mkdir -p "$EVIL/.claude-plugin" "$OUTSIDE" "$EVIL/plugins/lsp-link" "$EVIL/plugins/manifest-link/.claude-plugin" \
  "$EVIL/plugins/data/scripts" "$EVIL/plugins/pathy/.claude-plugin" "$EVIL/plugins/good" \
  "$EVIL/plugins/shared-link/hooks" "$EVIL/shared" "$EVIL/plugins/inner-link/docs" "$EVIL/plugins/inner-data/docs"
# A link that stays inside the marketplace but leaves the plugin points at
# content the plugin's own scan would not see.
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo $CLAUDE_PLUGIN_DATA"}]}]}}\n' > "$EVIL/shared/hooks.json"
ln -s "$EVIL/shared/hooks.json" "$EVIL/plugins/shared-link/hooks/hooks.json"
# A link inside the plugin is fine, and its target is scanned like any file.
printf 'readme\n' > "$EVIL/plugins/inner-link/docs/README"
ln -s "$EVIL/plugins/inner-link/docs/README" "$EVIL/plugins/inner-link/LICENSE"
printf 'uses $CLAUDE_PLUGIN_DATA\n' > "$EVIL/plugins/inner-data/docs/notes"
ln -s "$EVIL/plugins/inner-data/docs" "$EVIL/plugins/inner-data/linked-docs"
printf 'secret\n' > "$OUTSIDE/secret"
ln -s "$OUTSIDE/secret" "$EVIL/plugins/lsp-link/LICENSE"
printf '{"name":"manifest-link"}\n' > "$EVIL/plugins/manifest-link/.claude-plugin/plugin.json"
mkdir -p "$EVIL/plugins/manifest-link/skills"
ln -s "$OUTSIDE" "$EVIL/plugins/manifest-link/skills/escape"
printf 'echo "$CLAUDE_PLUGIN_DATA"\n' > "$EVIL/plugins/data/scripts/run.sh"
printf '{"name":"pathy","mcpServers":"./.mcp.json"}\n' > "$EVIL/plugins/pathy/.claude-plugin/plugin.json"
printf 'ok\n' > "$EVIL/plugins/good/LICENSE"
cat > "$EVIL/.claude-plugin/marketplace.json" <<'JSON'
{"name": "evil", "plugins": [
  {"name": "lsp-link", "source": "./plugins/lsp-link", "strict": false},
  {"name": "manifest-link", "source": "./plugins/manifest-link"},
  {"name": "data", "source": "./plugins/data", "strict": false},
  {"name": "pathy", "source": "./plugins/pathy"},
  {"name": "shared-link", "source": "./plugins/shared-link", "strict": false},
  {"name": "inner-link", "source": "./plugins/inner-link", "strict": false},
  {"name": "inner-data", "source": "./plugins/inner-data", "strict": false},
  {"name": "good", "source": "./plugins/good", "strict": false}
]}
JSON
python3 "$ROOT/scripts/settings-json.py" resolve-plugins "$TMP_DIR/evil-markets" "$TMP_DIR/evil-resolved" \
  lsp-link@evil manifest-link@evil data@evil pathy@evil shared-link@evil inner-link@evil inner-data@evil \
  good@evil > "$TMP_DIR/evil.out"
assert_contains "refused lsp-link@evil LICENSE links outside the plugin" "$TMP_DIR/evil.out"
assert_contains "refused manifest-link@evil skills/escape links outside the plugin" "$TMP_DIR/evil.out"
assert_contains "refused data@evil it uses CLAUDE_PLUGIN_DATA" "$TMP_DIR/evil.out"
assert_contains "refused pathy@evil its plugin.json mcpServers names a path" "$TMP_DIR/evil.out"
assert_contains "refused shared-link@evil hooks/hooks.json links outside the plugin" "$TMP_DIR/evil.out"
assert_contains "refused inner-data@evil it uses CLAUDE_PLUGIN_DATA" "$TMP_DIR/evil.out"
assert_contains "ok inner-link@evil" "$TMP_DIR/evil.out"
assert_contains "ok good@evil" "$TMP_DIR/evil.out"
[[ -e "$TMP_DIR/evil-resolved/good" && -e "$TMP_DIR/evil-resolved/inner-link" ]] || assert_at $LINENO
assert_eq "2" "$(ls "$TMP_DIR/evil-resolved" | wc -l | tr -d ' ')" "only the safe plugins are resolved"
# Staging never outlives the run.
assert_eq "" "$(find "$TMP_DIR" -maxdepth 1 -name 'evil-resolved.*')" "no staging left behind"

# An entry that throws is refused on its own, and the rest still resolve.
python3 - "$ROOT/scripts" "$TMP_DIR/evil-markets" "$TMP_DIR/evil-resolved" <<'PY'
import importlib.util, io, contextlib, os, sys
spec = importlib.util.spec_from_file_location("settings_json", os.path.join(sys.argv[1], "settings-json.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real = module.resolve_plugin
def flaky(entry, root, target):
    if entry["name"] == "lsp-link":
        raise OSError("boom")
    return real(entry, root, target)
module.resolve_plugin = flaky
out = io.StringIO()
with contextlib.redirect_stdout(out):
    module.command_resolve_plugins(sys.argv[2], sys.argv[3], "lsp-link@evil", "good@evil")
assert "refused lsp-link@evil it could not be prepared: boom" in out.getvalue(), out.getvalue()
assert "ok good@evil" in out.getvalue(), out.getvalue()
PY

printf 'plugin resolve tests passed\n'
