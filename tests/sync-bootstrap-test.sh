#!/usr/bin/env bash
# dx sync checks the Claude/Codex tooling and installs it only on request
# (--bootstrap), and DEX_SKIP_TOOL_BOOTSTRAP=1 overrides even that.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-sync-bootstrap-test.XXXXXX")"
REAL_BASH=$(command -v bash)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export CODEX_HOME="$HOME/.codex"
export DEX_DIR="$ROOT"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts" DX_LOOP_DIR="$TMP_DIR/loops" DX_RUN_ROOT="$TMP_DIR/runs"
export DX_STATE_DIR="$TMP_DIR/state" DX_TOOL_DIR="$TMP_DIR/tools"
# No RTK download, no Claude (so no marketplace clone), and a Codex that does
# nothing: the bootstrap's only observable write is Dex's MCP registry.
export DX_RTK_ENABLED=0 DX_PROVIDER_PROFILE=codex-subscription DEXCODE_SYNC=0
unset CLAUDE_CONFIG_DIR DEX_HOME DEX_SKIP_TOOL_BOOTSTRAP DEX_CODEX_HOME_WRITES
mkdir -p "$HOME" "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == login && "${2:-}" == status ]]; then printf 'Logged in with ChatGPT\n'; exit 0; fi
if [[ "${1:-}" == exec && "${2:-}" == --help ]]; then printf '%s\n' --ignore-user-config --dangerously-bypass-approvals-and-sandbox; exit 0; fi
[[ "${1:-}" != mcp ]] || exit 1
exit 0
SH
chmod +x "$TMP_DIR/bin/codex"
ln -s "$(command -v python3)" "$TMP_DIR/bin/python3"
export PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
mkdir -p "$REPO/.dex/rules" "$REPO/.dex/memory"
printf '%s\n' '# Dex' '## Tech Stack' 'Shell' '## Quality Gates' 'Tests' '## Project Structure' 'Repository' > "$REPO/.dex/dex.md"
printf '%s\n' '# Rule' > "$REPO/.dex/rules/base.md"
printf '%s\n' '# Memory' > "$REPO/.dex/memory/index.md"
git -C "$REPO" -c user.email=t@example.test -c user.name=t add .
git -C "$REPO" -c user.email=t@example.test -c user.name=t commit -qm init

sync() { # <output> [sync args...]
  local out="$1"
  shift
  (cd "$REPO" && "$REAL_BASH" "$ROOT/bin/sync.sh" --no-pr --budget-minutes 1 "$@") > "$out" 2>&1 || true
}
REGISTRY="$DX_TOOL_DIR/mcp-registry.json"

sync "$TMP_DIR/default.out"
assert_contains "Checking Claude/Codex tooling bootstrap" "$TMP_DIR/default.out"
assert_contains "dx sync --bootstrap" "$TMP_DIR/default.out"
assert_not_contains "Installing Claude/Codex tooling bootstrap" "$TMP_DIR/default.out"
assert_no_file "$REGISTRY"

DEX_SKIP_TOOL_BOOTSTRAP=1 sync "$TMP_DIR/skip.out" --bootstrap
assert_contains "DEX_SKIP_TOOL_BOOTSTRAP=1" "$TMP_DIR/skip.out"
assert_no_file "$REGISTRY"

sync "$TMP_DIR/bootstrap.out" --bootstrap
assert_contains "Installing Claude/Codex tooling bootstrap" "$TMP_DIR/bootstrap.out"
assert_contains '"openaiDeveloperDocs"' "$REGISTRY"
assert_no_file "$CODEX_HOME/config.toml"
assert_no_file "$CODEX_HOME/skills"

# --dry-run never installs, --bootstrap or not.
rm -f "$REGISTRY"
sync "$TMP_DIR/dry.out" --dry-run --bootstrap
assert_no_file "$REGISTRY"

printf 'sync bootstrap tests passed\n'
