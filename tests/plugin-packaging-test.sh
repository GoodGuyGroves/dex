#!/usr/bin/env bash
# Dex's skills ship as the plugin `dex` in plugin/, loaded per launch with
# --plugin-dir. Global links in ~/.claude/skills are opt-in. Offline: the real
# claude is used only for `claude plugin validate`, in a sandboxed HOME.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-plugin-packaging-test.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops" DX_RUN_ROOT="$TMP_DIR/runs"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts" DX_TOOL_DIR="$TMP_DIR/tools" DX_RTK_ENABLED=0
unset CLAUDE_CONFIG_DIR DEX_EXTRA_SETTINGS DEX_LAUNCHED DEX_SESSION_ID
mkdir -p "$HOME/.claude"

# ── the plugin layout ─────────────────────────────────────────────────────
PLUGIN="$ROOT/plugin"
python3 - "$PLUGIN/.claude-plugin/plugin.json" "$ROOT/settings.json" <<'PY'
import json, sys
manifest, settings = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert manifest["name"] == "dex", manifest
assert "version" not in manifest, manifest  # tracks the checkout, not a release
# Only these keys take effect from a plugin root's settings.json; Dex's must
# never carry them, should the plugin root ever move to the checkout.
assert not {"agent", "subagentStatusLine"} & set(settings), settings
PY
[[ -L "$PLUGIN/skills" && "$(readlink "$PLUGIN/skills")" == "../skills" ]] || assert_at $LINENO
assert_eq "$(cd "$ROOT/skills" && ls -d -- */SKILL.md)" "$(cd "$PLUGIN/skills" && ls -d -- */SKILL.md)" \
  'plugin/skills lists exactly skills/'
# Dex's hooks reach launches through --settings, and its scripts stay off PATH.
assert_no_file "$PLUGIN/hooks/hooks.json"
[[ ! -e "$PLUGIN/bin" ]] || assert_at $LINENO

# ── --plugin-dir on every Claude engine ───────────────────────────────────
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
launch() { # <engine> <args...>
  local engine="$1"
  shift
  (
    export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE="$engine" DX_PROVIDER_PROFILE_RESOLVED="$engine"
    __dx_provider_claude_exec() { printf '%s\n' "$@" > "$TMP_DIR/$engine.argv"; }
    dx_provider_claude "$@"
  )
}
plugin_dirs() { grep -Fx -A1 -- --plugin-dir "$TMP_DIR/$1.argv" | grep -vFx -- --plugin-dir | grep -v '^--$' || true; }
for engine in claude anthropic-gateway ccr; do
  launch "$engine" -p go
  assert_eq "$PLUGIN" "$(plugin_dirs "$engine")" "$engine: Dex's --plugin-dir"
done
launch codex-plugin -p go
assert_eq $'-p\ngo' "$(cat "$TMP_DIR/codex-plugin.argv")" 'codex-plugin: argv untouched'
# A caller's own plugin directory stays beside Dex's.
launch claude --plugin-dir "$TMP_DIR/mine" -p go
assert_eq "$PLUGIN"$'\n'"$TMP_DIR/mine" "$(plugin_dirs claude)" 'caller --plugin-dir kept'

# ── prompts name Dex files by absolute path ───────────────────────────────
# A relative skills/ or prompts/ path resolves against the target repository,
# and with no global links nothing is there. Comment lines are not prompts.
# A bare `prompts/x.md`, or one spelled `./prompts/x.md` or `../prompts/x.md`.
relative_refs() {
  grep -rnE '(^|[^/A-Za-z0-9_.}$-])(\.\.?/)?(skills|prompts)/[A-Za-z0-9<*]' "$@" \
    | grep -vE '^[^:]+\.sh:[0-9]+:[[:space:]]*#' || true
}
relative=$(relative_refs "$ROOT/dx.sh" "$ROOT"/lib/*.sh "$ROOT"/hooks/*.sh "$ROOT/prompts" "$ROOT"/skills/*/SKILL.md)
[[ -z "$relative" ]] || fail "prompts name Dex files by a repo-relative path:"$'\n'"$relative"
# The guard itself catches each spelling, and leaves absolute ones alone.
for planted in 'Read `./prompts/x.md`.' 'Read ../skills/x/SKILL.md.' 'Read `prompts/x.md`.'; do
  printf '%s\n' "$planted" > "$TMP_DIR/planted.md"
  [[ -n "$(relative_refs "$TMP_DIR/planted.md")" ]] || fail "the guard missed: $planted"
done
printf '%s\n' 'Read `$DEX_DIR/prompts/x.md` and ${DEX_DIR}/skills/x/SKILL.md.' > "$TMP_DIR/planted.md"
[[ -z "$(relative_refs "$TMP_DIR/planted.md")" ]] || fail 'the guard flagged an absolute path'
grep -Fq 'Follow \`${DEX_DIR}/skills/dxreview/SKILL.md\`' "$ROOT/lib/review-loop.sh" || assert_at $LINENO
grep -Fq '__DEX_DIR__' "$ROOT/lib/review-loop.sh" && fail 'review-loop.sh still has a __DEX_DIR__ placeholder'
grep -Fq 'Read ${DEX_DIR}/skills/dxcomplete/SKILL.md' "$ROOT/dx.sh" || assert_at $LINENO

# ── skill names in generated prompts ──────────────────────────────────────
# The prefixed name cannot be captured by a user's own skill of the same name.
ref() { (export DX_PROVIDER_ENGINE="$1"; dx_skill_ref humanizer); }
for engine in claude anthropic-gateway ccr; do
  assert_eq dex:humanizer "$(ref "$engine")" "$engine: prefixed"
done
assert_eq humanizer "$(ref codex-plugin)" 'codex-plugin: bare'
assert_eq humanizer "$(unset DX_PROVIDER_ENGINE DEX_LAUNCHED; dx_skill_ref humanizer)" 'outside Dex: bare'
assert_eq dex:humanizer "$(unset DX_PROVIDER_ENGINE; DEX_LAUNCHED=1 dx_skill_ref humanizer)" 'Dex launch: prefixed'
rendered=$(DX_PROVIDER_ENGINE=claude dx_skill_refs_render 'use skill: "dxplan", then skill: "dxpr" & skill: "mine"')
assert_eq 'use skill: "dex:dxplan", then skill: "dex:dxpr" & skill: "mine"' "$rendered" 'render prefixes Dex skills only'
assert_eq 'skill: "dxplan"' "$(DX_PROVIDER_ENGINE=codex-plugin dx_skill_refs_render 'skill: "dxplan"')" 'render: codex untouched'
# Every generated `skill: "<name>"` goes through the renderer or dx_skill_ref.
# The hook runs when sourced, so take just its phase-message functions.
eval "$(sed -n '/^dx_inline_phase_message() {$/,/^dx_compact_repeat_audit_prompt() {$/p' \
  "$ROOT/hooks/phase-loop.sh" | sed '$d')"
phase_text=$(for p in 0 1 2 3 4 5 6; do DX_PROVIDER_ENGINE=claude dx_inline_phase_message "$p"; done 2> "$TMP_DIR/phase.err")
[[ ! -s "$TMP_DIR/phase.err" ]] || fail "phase messages wrote to stderr: $(cat "$TMP_DIR/phase.err")"
[[ "$phase_text" == *'skill: "dex:dximplement"'* ]] || fail 'inline phase messages keep bare skill names'
[[ "$phase_text" != *'skill: "dx'* ]] || fail 'an inline phase message names a bare Dex skill'
[[ "$phase_text" == *"$ROOT/prompts/commit-format.md"* ]] || assert_at $LINENO
[[ "$phase_text" != *"The approved plan is saved at"* ]] || fail 'plan note without a run'
# With a run that holds an approved plan, Phase 2 points at the run's copy.
SESSION_ID=packaging-plan-session
dx_run_write_for_session "$SESSION_ID" run_test_packaging
plan_copy=$(dx_run_plan_file "$SESSION_ID")
mkdir -p "$(dirname "$plan_copy")"
printf 'approved\n' > "$plan_copy"
phase2_text=$(DX_PROVIDER_ENGINE=claude dx_inline_phase_message 2 2> "$TMP_DIR/phase2.err")
[[ ! -s "$TMP_DIR/phase2.err" ]] || fail "Phase 2 message wrote to stderr: $(cat "$TMP_DIR/phase2.err")"
[[ "$phase2_text" == *"The approved plan is saved at $plan_copy."* ]] || fail 'Phase 2 message lacks the plan note'
unset SESSION_ID

# ── opt-in global links ───────────────────────────────────────────────────
status_skills() { bash "$ROOT/bin/status.sh" 2>/dev/null | grep -E '^  Skills:' || true; }
assert_eq none "$(dx_claude_global_skills_state)" 'no links by default'
dx_check_claude_dex_links > "$TMP_DIR/check.out"
assert_contains "load per launch (plugin dex)" "$TMP_DIR/check.out"
[[ "$(status_skills)" == *"loaded per launch (plugin dex)" ]] || fail "status: $(status_skills)"

# --global-skills, into a fresh ~/.claude: one directory link.
dx_install_claude_dex_links > /dev/null
assert_eq linked "$(dx_claude_global_skills_state)" 'whole-directory link'
dx_check_claude_dex_links > "$TMP_DIR/check-linked.out"
assert_contains "--no-global-skills" "$TMP_DIR/check-linked.out"
[[ "$(status_skills)" == *"plus global links"* ]] || fail "status: $(status_skills)"
dx_remove_claude_skill_links > /dev/null
[[ ! -e "$HOME/.claude/skills" ]] || assert_at $LINENO

# Beside the user's own skill: per-skill links, and the user's skill stays.
mkdir -p "$HOME/.claude/skills/my-skill"
dx_install_claude_dex_links > /dev/null
assert_eq linked "$(dx_claude_global_skills_state)" 'per-skill links'
rm "$HOME/.claude/skills/dxplan"
assert_eq partial "$(dx_claude_global_skills_state)" 'one link gone'
if dx_check_claude_dex_links > "$TMP_DIR/check-partial.out" 2>&1; then
  fail 'the doctor accepted a partial set of skill links'
fi
assert_contains "partial set" "$TMP_DIR/check-partial.out"
dx_remove_claude_skill_links > /dev/null
assert_eq none "$(dx_claude_global_skills_state)" 'links removed'
assert_dir "$HOME/.claude/skills/my-skill"

# A user's own skill under a Dex name is theirs: not a missing link, so the
# rest still counts as fully linked and nothing advises --global-skills.
mkdir -p "$HOME/.claude/skills/humanizer"
dx_install_claude_dex_links > /dev/null 2>&1 || true
assert_eq linked "$(dx_claude_global_skills_state)" 'user-owned Dex name'
dx_check_claude_dex_links > /dev/null
dx_remove_claude_skill_links > /dev/null
assert_dir "$HOME/.claude/skills/humanizer"
rm -rf "$HOME/.claude/skills/humanizer"

# A link the user pointed elsewhere is theirs: not Dex's, and never removed.
rm -rf "$HOME/.claude/skills"
ln -s "$TMP_DIR" "$HOME/.claude/skills"
assert_eq none "$(dx_claude_global_skills_state)" 'foreign link'
dx_remove_claude_skill_links > /dev/null
[[ -L "$HOME/.claude/skills" ]] || assert_at $LINENO
rm "$HOME/.claude/skills"

# ── claude plugin validate ────────────────────────────────────────────────
if command -v claude >/dev/null 2>&1; then
  env CLAUDE_CONFIG_DIR="$HOME/.claude" python3 "$ROOT/tests/test-timeout.py" 120 \
    claude plugin validate "$PLUGIN" < /dev/null > "$TMP_DIR/validate.out" 2>&1 \
    || { cat "$TMP_DIR/validate.out" >&2; fail 'claude plugin validate rejected plugin/'; }
else
  printf '%s\n' 'claude not on PATH; skipped claude plugin validate'
fi

printf 'plugin packaging tests passed\n'
