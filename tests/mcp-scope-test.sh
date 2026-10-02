#!/usr/bin/env bash
# scripts/mcp-scope.py and the shell around it: a project's `## MCP` block
# (flat keys, values, fallbacks, problems), the inline union, server layers and
# disabled lists, the strict configuration it writes, review waves, and the
# rows `dx status` and `dx doctor` print.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-mcp-scope-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_SYNC=0
unset CLAUDE_CONFIG_DIR DEX_HOME DEX_LIFECYCLE_MINIMAL_MCP DEX_REVIEW_DISABLE_MCP
unset DEX_LOOP_ACTIVE DEX_LOOP_PHASE DEX_PHASE_HANDOFF GITHUB_TOKEN
mkdir -p "$HOME" "$DX_LOOP_DIR" "$DX_TOOL_DIR"

SCOPE="$ROOT/scripts/mcp-scope.py"
REPO="$TMP_DIR/repo"
REGISTRY="$DX_TOOL_DIR/mcp-registry.json"
OUT="$TMP_DIR/out.json"

git init -q "$REPO"
mkdir -p "$REPO/.dex"

# write_mcp <yaml lines…> — the repository's `## MCP` block.
write_mcp() {
  {
    printf '# Project\n\n## MCP\n\n```yaml\n'
    printf '%s\n' "$@"
    printf '```\n\n## Other\n\nprose\n'
  } > "$REPO/.dex/dex.md"
}

# launch <phase> <inline> — mode on line 1, report lines after.
launch() {
  rm -f "$OUT"
  (cd "$REPO" && python3 "$SCOPE" launch "$REPO" "$1" "$2" "$REGISTRY" "$OUT")
}

mode_of() { launch "$1" "$2" | head -n 1; }

servers_of() {
  python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["mcpServers"])))' "$OUT"
}

cat > "$HOME/.claude.json" <<'JSON'
{"mcpServers": {"github": {"type": "http", "url": "https://github.example", "headers": {"Authorization": "Bearer ${GITHUB_TOKEN}"}},
                "linear": {"url": "https://linear.example"},
                "memory": {"command": "user-memory"},
                "off": {"command": "x", "enabled": false},
                "globally-off": {"command": "y"}},
 "disabledMcpServers": ["globally-off"]}
JSON
printf '%s\n' '{"mcpServers": {"memory": {"command": "dex-memory"}, "registry-only": {"command": "r"}}}' > "$REGISTRY"

# --- no section: the built-in table is today's minimal-MCP policy ------------

printf '# Project\n\nNo MCP section.\n' > "$REPO/.dex/dex.md"
# Today: phases 4-6 and a non-inline 1 launch with no servers; the rest inherit.
expected_noninline=(inherit none inherit inherit none none none)
expected_inline=(inherit inherit inherit inherit none none none)
for phase in 0 1 2 3 4 5 6; do
  assert_eq "${expected_noninline[$phase]}" "$(mode_of "$phase" 0)" "built-in phase $phase non-inline"
  assert_eq "${expected_inline[$phase]}" "$(mode_of "$phase" 1)" "built-in phase $phase inline"
done
# The shell keeps the same table so a launch without `## MCP` starts no python3.
(
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  for phase in 0 1 2 3 4 5 6; do
    for inline in 0 1; do
      assert_eq "$(mode_of "$phase" "$inline")" \
        "$(DEX_LOOP_PHASE="$phase" __dx_provider_builtin_phase_mcp "$inline")" \
        "shell and Python built-ins agree for phase $phase inline $inline"
    done
  done
  dx_mcp_declared "$REPO" && assert_at $LINENO
  write_mcp 'plan: none'
  dx_mcp_declared "$REPO" || assert_at $LINENO
)
rm -f "$REPO/.dex/dex.md"
assert_eq none "$(mode_of 4 1)" "no dex.md at all"

# --- values and fallbacks ----------------------------------------------------

write_mcp 'plan: [github, memory]'
assert_eq scoped "$(mode_of 1 0)" "a plan list scopes a non-inline plan launch"
assert_eq "github,memory" "$(servers_of)" "only the listed servers"
# Precedence: the user's memory beats the registry's.
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["mcpServers"]; assert c["memory"]["command"]=="user-memory", c' "$OUT"
mode=$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$OUT")
assert_eq 600 "$mode" "the scoped configuration is private"
# Unnamed phases keep the built-in values.
assert_eq inherit "$(mode_of 2 0)" "implement still inherits"
assert_eq none "$(mode_of 4 0)" "verify still none"
# Inline at plan: implement inherits downstream, so the launch inherits.
assert_eq inherit "$(mode_of 1 1)" "inline plan launch inherits when implement does"

write_mcp 'default: none' 'implement: [registry-only]'
assert_eq scoped "$(mode_of 2 0)" "default none with an implement list"
assert_eq "registry-only" "$(servers_of)" "a registry-only server resolves"
# The review host session always inherits, so an inline launch before it does.
assert_eq inherit "$(mode_of 2 1)" "inline implement inherits through review"
assert_eq inherit "$(mode_of 0 1)" "setup always inherits"
assert_eq none "$(mode_of 1 0)" "default none reaches plan"

write_mcp 'default: [linear]' 'verify: none' 'pr: [github]' 'complete: [github, linear]'
assert_eq scoped "$(mode_of 4 1)" "inline verify takes pr and complete"
assert_eq "github,linear" "$(servers_of)" "union of verify..complete"
assert_eq none "$(mode_of 4 0)" "non-inline verify is none"
assert_eq scoped "$(mode_of 2 0)" "default list fills implement"
assert_eq "linear" "$(servers_of)" "default list"

write_mcp 'verify: []' 'pr:' 'complete: github'
assert_eq none "$(mode_of 4 0)" "[] means none"
assert_eq none "$(mode_of 5 0)" "an empty block list means none"
assert_eq scoped "$(mode_of 6 0)" "a bare name is a one-item list"
assert_eq "github" "$(servers_of)" "bare scalar"

write_mcp 'pr:' '  - github' '  - memory'
assert_eq scoped "$(mode_of 5 0)" "a block list"
assert_eq "github,memory" "$(servers_of)" "block list items"

# --- problems are reported, never fatal --------------------------------------

write_mcp 'plan: [github, ghost, off, globally-off]'
launch 1 0 > "$TMP_DIR/report"
assert_contains $'missing\tghost' "$TMP_DIR/report"
assert_contains $'disabled\toff' "$TMP_DIR/report"
assert_contains $'disabled\tglobally-off' "$TMP_DIR/report"
assert_contains $'unset-env\tGITHUB_TOKEN' "$TMP_DIR/report"
assert_eq "github" "$(servers_of)" "missing and disabled names are left out"
# Names only: never a URL, header or value on stdout.
assert_not_contains "https://" "$TMP_DIR/report"
assert_not_contains "Bearer" "$TMP_DIR/report"
GITHUB_TOKEN=token-value launch 1 0 > "$TMP_DIR/report"
assert_not_contains "unset-env" "$TMP_DIR/report"

write_mcp 'phases: {plan: [github]}' 'setup: none' 'review: none' 'verify: [bad name!]' 'pr: [github]'
launch 5 0 > "$TMP_DIR/report"
assert_contains "'phases' is not a ## MCP key; use flat phase keys" "$TMP_DIR/report"
assert_contains "'setup' is not a ## MCP key" "$TMP_DIR/report"
assert_contains "'review' is not a ## MCP key" "$TMP_DIR/report"
assert_contains "verify: 'bad name!' is not a valid MCP server name" "$TMP_DIR/report"
assert_eq scoped "$(head -n 1 "$TMP_DIR/report")" "valid keys still apply"
assert_eq none "$(mode_of 4 0)" "an invalid verify value falls back to the built-in"
assert_eq inherit "$(mode_of 0 0)" "an ignored setup key leaves setup inheriting"

write_mcp 'plan:' '  nested: true'
launch 1 0 > "$TMP_DIR/report"
assert_eq none "$(head -n 1 "$TMP_DIR/report")" "a malformed block falls back to the built-in"
assert_contains "not a flat mapping" "$TMP_DIR/report"

# An unreadable Claude configuration is a failure the caller handles.
write_mcp 'plan: [github]'
cp "$HOME/.claude.json" "$TMP_DIR/claude.json.good"
printf '{not json' > "$HOME/.claude.json"
rc=0
launch 1 0 > "$TMP_DIR/report" 2> "$TMP_DIR/stderr" || rc=$?
assert_eq 2 "$rc" "unreadable configuration exits 2"
assert_contains "Cannot read MCP configuration" "$TMP_DIR/stderr"
cp "$TMP_DIR/claude.json.good" "$HOME/.claude.json"

# --- layers: local servers, CLAUDE_CONFIG_DIR, settings disabled lists, worktree

python3 - "$HOME/.claude.json" "$REPO" <<'PY'
import json, sys
path, repo = sys.argv[1], sys.argv[2]
state = json.load(open(path))
state["projects"] = {repo: {"mcpServers": {"github": {"command": "local-github"}}}}
json.dump(state, open(path, "w"))
PY
launch 1 0 > /dev/null
python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["mcpServers"]; assert c["github"]=={"command":"local-github"}, c' "$OUT"

mkdir -p "$REPO/.claude"
printf '%s\n' '{"disabledMcpjsonServers": ["github"]}' > "$REPO/.claude/settings.local.json"
launch 1 0 > "$TMP_DIR/report"
assert_contains $'disabled\tgithub' "$TMP_DIR/report"
rm -rf "$REPO/.claude"

mkdir -p "$TMP_DIR/config"
printf '%s\n' '{"mcpServers": {"cfg-only": {"command": "c"}}}' > "$TMP_DIR/config/.claude.json"
write_mcp 'plan: [cfg-only, github]'
CLAUDE_CONFIG_DIR="$TMP_DIR/config" launch 1 0 > "$TMP_DIR/report"
assert_eq "cfg-only" "$(servers_of)" "CLAUDE_CONFIG_DIR replaces ~/.claude.json"
assert_contains $'missing\tgithub' "$TMP_DIR/report"

# A linked worktree keeps what the main checkout disabled.
git -C "$REPO" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m fixture
git -C "$REPO" worktree add -q --detach "$TMP_DIR/wt" HEAD
mkdir -p "$TMP_DIR/wt/.dex"
cp "$REPO/.dex/dex.md" "$TMP_DIR/wt/.dex/dex.md"
python3 - "$HOME/.claude.json" "$REPO" <<'PY'
import json, sys
path, repo = sys.argv[1], sys.argv[2]
state = json.load(open(path))
state["projects"] = {repo: {"disabledMcpServers": ["linear"]}}
json.dump(state, open(path, "w"))
PY
printf '%s\n' '# x' '' '## MCP' '' '```yaml' 'plan: [linear, github]' '```' > "$TMP_DIR/wt/.dex/dex.md"
rm -f "$OUT"
(cd "$TMP_DIR/wt" && python3 "$SCOPE" launch "$TMP_DIR/wt" 1 0 "$REGISTRY" "$OUT") > "$TMP_DIR/report"
assert_contains $'disabled\tlinear' "$TMP_DIR/report"
assert_eq "github" "$(servers_of)" "the main checkout's disabled list applies to a worktree"

# --- review waves and the status report --------------------------------------

write_mcp 'plan: [github]'
rm -f "$OUT"
assert_eq unset "$(cd "$REPO" && python3 "$SCOPE" review-waves "$REPO" "$REGISTRY" "$OUT")" "undeclared review waves"
write_mcp 'review_waves: [memory]'
assert_eq scoped "$(cd "$REPO" && python3 "$SCOPE" review-waves "$REPO" "$REGISTRY" "$OUT" | head -n 1)" "review_waves list"
assert_eq "memory" "$(servers_of)" "review wave servers"
write_mcp 'review_waves: inherit'
assert_eq inherit "$(cd "$REPO" && python3 "$SCOPE" review-waves "$REPO" "$REGISTRY" "$OUT")" "review_waves inherit"

# The review loop's flags for its waves.
wave_flags() { # <env assignments…> — prints review_mcp_flags, one per line
  (
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    local review_mcp_flags=()
    cd "$REPO"
    for assignment in "$@"; do export "${assignment?}"; done
    __dx_review_wave_mcp_flags "$REPO" "$DX_LOOP_DIR/empty-mcp.json" "$TMP_DIR/wave.json"
    printf '%s\n' ${review_mcp_flags[@]+"${review_mcp_flags[@]}"}
  )
}
EMPTY_FLAGS=$'--strict-mcp-config\n--mcp-config\n'"$DX_LOOP_DIR/empty-mcp.json"
write_mcp 'plan: [github]'
assert_eq "$EMPTY_FLAGS" "$(wave_flags)" "undeclared review waves keep the empty default"
assert_eq "" "$(wave_flags DEX_REVIEW_DISABLE_MCP=0)" "DEX_REVIEW_DISABLE_MCP=0 still inherits"
write_mcp 'review_waves: inherit'
assert_eq "" "$(wave_flags)" "review_waves: inherit"
assert_eq "$EMPTY_FLAGS" "$(wave_flags DEX_REVIEW_DISABLE_MCP=1)" "a set DEX_REVIEW_DISABLE_MCP beats review_waves"
write_mcp 'review_waves: [memory, ghost]'
wave_flags > "$TMP_DIR/wave.flags" 2> "$TMP_DIR/wave.err"
assert_eq $'--strict-mcp-config\n--mcp-config\n'"$TMP_DIR/wave.json" "$(cat "$TMP_DIR/wave.flags")" "review_waves list"
assert_contains "MCP (review waves): 'ghost' is not defined" "$TMP_DIR/wave.err"
assert_eq "memory" "$(OUT="$TMP_DIR/wave.json" servers_of)" "the wave servers"
write_mcp 'review_waves: none'
assert_eq "$EMPTY_FLAGS" "$(wave_flags)" "review_waves: none"
[[ ! -e "$TMP_DIR/wave.json" ]] || assert_at $LINENO

write_mcp 'default: none' 'plan: [github, ghost]' 'implement: inherit'
(cd "$REPO" && python3 "$SCOPE" report "$REPO" "$REGISTRY") > "$TMP_DIR/report"
assert_eq "$(printf 'phase\tplan\tgithub (missing: ghost)')" "$(grep '^phase.plan' "$TMP_DIR/report")" "plan row"
assert_eq "$(printf 'phase\timplement\tinherited')" "$(grep '^phase.implement' "$TMP_DIR/report")" "implement row"
assert_contains $'phase\tverify\tnone [default]' "$TMP_DIR/report"
assert_contains $'phase\treview_waves\tnone [built-in]' "$TMP_DIR/report"
assert_contains $'missing\tplan\tghost' "$TMP_DIR/report"

# dx status prints the rows; dx doctor warns about the problems.
(cd "$REPO" && bash "$ROOT/bin/status.sh") > "$TMP_DIR/status.out" 2>&1
assert_contains "  MCP:        ## MCP in .dex/dex.md (Claude launches; Codex ignores it)" "$TMP_DIR/status.out"
assert_contains "    plan:         github (missing: ghost)" "$TMP_DIR/status.out"
assert_contains "    implement:    inherited" "$TMP_DIR/status.out"
assert_contains "    review waves: none [built-in]" "$TMP_DIR/status.out"
assert_contains "An inline launch loads its own phase's servers and every later phase's." "$TMP_DIR/status.out"
(cd "$REPO" && bash "$ROOT/bin/doctor.sh") > "$TMP_DIR/doctor.out" 2>&1
assert_contains "MCP (this repo):" "$TMP_DIR/doctor.out"
assert_contains "[warn]  plan lists 'ghost', which no Claude MCP configuration or Dex's registry defines." "$TMP_DIR/doctor.out"
write_mcp 'plan: [github]' 'phases: x'
(cd "$REPO" && bash "$ROOT/bin/status.sh") > "$TMP_DIR/status.out" 2>&1
assert_contains "    ignored:      'phases' is not a ## MCP key; use flat phase keys" "$TMP_DIR/status.out"
write_mcp 'plan: [github]'
(cd "$REPO" && bash "$ROOT/bin/doctor.sh") > "$TMP_DIR/doctor.out" 2>&1
assert_contains "[ok]    Every server ## MCP names resolves" "$TMP_DIR/doctor.out"
rm -f "$REPO/.dex/dex.md"
(cd "$REPO" && bash "$ROOT/bin/status.sh") > "$TMP_DIR/status.out" 2>&1
assert_contains "  MCP:        built-in (plan, verify, pr, complete: none; others inherited)" "$TMP_DIR/status.out"
(cd "$REPO" && bash "$ROOT/bin/doctor.sh") > "$TMP_DIR/doctor.out" 2>&1
assert_not_contains "MCP (this repo):" "$TMP_DIR/doctor.out"

# Usage errors.
rc=0
python3 "$SCOPE" launch "$REPO" 9 0 "$REGISTRY" "$OUT" 2>/dev/null || rc=$?
assert_eq 2 "$rc" "phase out of range"
rc=0
python3 "$SCOPE" nope 2>/dev/null || rc=$?
assert_eq 2 "$rc" "unknown command"

echo "mcp-scope-test: ok"
