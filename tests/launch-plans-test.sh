#!/usr/bin/env bash
# Claude Code plan files and prompt suggestions in Dex launches: every launch
# file sends plans to .dex/plans inside the launch directory and turns prompt
# suggestions off, git ignores the plans in a worktree and in an in-place
# checkout, and the run keeps its own copy of the approved plan.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-launch-plans-test.XXXXXX")"
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
unset CLAUDE_CONFIG_DIR DEX_EXTRA_SETTINGS DEX_LAUNCHED DEX_SESSION_ID DEX_RUN_ID
mkdir -p "$HOME/.claude"
printf '[user]\n\temail = dex@example.test\n\tname = Dex Test\n' > "$GIT_CONFIG_GLOBAL"
HELPER="$ROOT/scripts/settings-json.py"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
export DX_RTK_ENABLED=0

# ── The launch file ───────────────────────────────────────────────────────
python3 "$HELPER" launch-settings "$ROOT/settings.json" "$ROOT" '' '' 0 > "$TMP_DIR/plain.json"
printf '%s\n' '{"promptSuggestionEnabled":true,"plansDirectory":"/elsewhere"}' > "$TMP_DIR/extra.json"
DEX_EXTRA_SETTINGS="$TMP_DIR/extra.json" python3 "$HELPER" launch-settings "$ROOT/settings.json" \
  "$ROOT" '' '' 0 > "$TMP_DIR/extra-out.json"
python3 - "$TMP_DIR" "$DX_CLAUDE_PLANS_SUBDIR" <<'PY'
import json, sys
tmp, subdir = sys.argv[1], sys.argv[2]
plain = json.load(open(tmp + "/plain.json"))
extra = json.load(open(tmp + "/extra-out.json"))
assert plain["plansDirectory"] == subdir == ".dex/plans", plain     # shell and Python agree
assert plain["promptSuggestionEnabled"] is False, plain
assert extra["promptSuggestionEnabled"] is True, extra              # a deliberate opt-in wins
assert extra["plansDirectory"] == subdir, extra                     # the run's copy depends on it
PY

# ── git ignores the plans: in-place checkout, Dex worktree, subdirectory ──
REPO="$TMP_DIR/repo"
git init -q "$REPO"
printf 'x\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m init
git -C "$REPO" worktree add -q "$REPO/.dex/worktrees/wt" -b wt-branch
EXCLUDE="$(git -C "$REPO" rev-parse --absolute-git-dir)/info/exclude"
WT="$REPO/.dex/worktrees/wt"
mkdir -p "$REPO/sub"

ignored() { # <dir>
  git -C "$1" check-ignore -q --no-index -- "$DX_CLAUDE_PLANS_SUBDIR/plan.md"
}
ignored "$REPO" && fail "the fixture repo already ignores .dex/plans"
# dx_claude_plans_ignore runs from the launch directory, as the provider does.
(cd "$WT" && dx_claude_plans_ignore "$PWD")
ignored "$WT" || fail "worktree: .dex/plans is not ignored"
ignored "$REPO" || fail "in-place checkout: .dex/plans is not ignored"
(cd "$REPO/sub" && dx_claude_plans_ignore "$PWD")
ignored "$REPO/sub" || fail "a subdirectory launch: .dex/plans is not ignored"
(cd "$REPO" && dx_claude_plans_ignore "$PWD")
assert_eq 1 "$(grep -cxF '**/.dex/plans/' "$EXCLUDE")" 'one exclude line, however many launches'
for dir in "$REPO" "$WT"; do
  mkdir -p "$dir/.dex/plans"
  printf 'plan\n' > "$dir/.dex/plans/a-plan.md"
  printf 'agent\n' > "$dir/.dex/plans/a-plan-agent-a1b2.md"
  [[ -z "$(git -C "$dir" status --porcelain --untracked-files=all -- .dex/plans)" ]] \
    || fail "plan files show in git status in $dir"
done
# A repository that ignores the plans itself keeps its exclude file untouched.
OWN="$TMP_DIR/own"
git init -q "$OWN"
mkdir -p "$OWN/.dex"
printf 'plans/\n' > "$OWN/.dex/.gitignore"
(cd "$OWN" && dx_claude_plans_ignore "$PWD")
grep -qF '.dex/plans/' "$(git -C "$OWN" rev-parse --absolute-git-dir)/info/exclude" 2>/dev/null \
  && fail "an exclude line was added where .dex/.gitignore already ignores the plans"
# Outside a repository there is nothing to do.
mkdir -p "$TMP_DIR/not-a-repo"
(cd "$TMP_DIR/not-a-repo" && dx_claude_plans_ignore "$PWD")
assert_no_file "$TMP_DIR/not-a-repo/.git"

# ── dx_provider_claude: the launch carries the settings and leaves the
# checkout alone (a session-only launch must not touch .git either) ───────
FRESH="$TMP_DIR/fresh"
git init -q "$FRESH"
FRESH_EXCLUDE="$(git -C "$FRESH" rev-parse --absolute-git-dir)/info/exclude"
cp "$FRESH_EXCLUDE" "$TMP_DIR/fresh-exclude.before"
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  [[ "$1" == --settings ]] && cp "$2" "$STUB_OUT"
  shift
done
STUB
chmod +x "$TMP_DIR/bin/claude"
(
  cd "$FRESH"
  export PATH="$TMP_DIR/bin:$PATH" STUB_OUT="$TMP_DIR/launch.json"
  export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=claude DX_PROVIDER_PROFILE_RESOLVED=claude
  dx_provider_claude --dangerously-skip-permissions "go"
)
python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); assert s["plansDirectory"] == ".dex/plans" and s["promptSuggestionEnabled"] is False, s' \
  "$TMP_DIR/launch.json"
cmp -s "$FRESH_EXCLUDE" "$TMP_DIR/fresh-exclude.before" || fail "a launch edited the checkout's info/exclude"
# Worktree setup ignores them for every later launch there.
printf 'x\n' > "$FRESH/f.txt"
git -C "$FRESH" add f.txt
git -C "$FRESH" commit -q -m init
git -C "$FRESH" worktree add -q "$FRESH/.dex/worktrees/fresh-wt" -b fresh-wt
dx_exclude_claude_artifacts "$FRESH/.dex/worktrees/fresh-wt"
ignored "$FRESH/.dex/worktrees/fresh-wt" || fail "worktree setup did not make git ignore .dex/plans"

# ── The run's copy of the approved plan ──────────────────────────────────
# new_run <session> <dir> — a run whose spec predates everything written after.
new_run() {
  local run_id="run_test_$1"
  dx_run_write_for_session "$1" "$run_id"
  mkdir -p "$(dx_run_dir "$run_id")"
  printf '{}\n' > "$(dx_run_spec_file "$run_id")"
  touch -t 202601010000 "$(dx_run_spec_file "$run_id")"
  printf '%s\n' "$(dx_run_artifacts_dir "$run_id")"
}

PROJECT="$TMP_DIR/project"
mkdir -p "$PROJECT/.dex/plans"
ARTIFACTS=$(new_run sess-a "$PROJECT")
printf 'older run\n' > "$PROJECT/.dex/plans/old.md"
touch -t 202501010000 "$PROJECT/.dex/plans/old.md"
printf 'first draft\n' > "$PROJECT/.dex/plans/brave-plan.md"
touch -t 202602010000 "$PROJECT/.dex/plans/brave-plan.md"
printf 'approved\n' > "$PROJECT/.dex/plans/calm-plan.md"
printf 'explored\n' > "$PROJECT/.dex/plans/calm-plan-agent-a82e30f.md"
dx_run_archive_plans sess-a "$PROJECT" 2> "$TMP_DIR/archive.err"
assert_eq approved "$(cat "$ARTIFACTS/plan.md")" 'plan.md is the newest plan'
assert_eq "$ARTIFACTS/plan.md" "$(dx_run_plan_file sess-a)" 'dx_run_plan_file'
for name in brave-plan.md calm-plan.md calm-plan-agent-a82e30f.md; do
  assert_file "$ARTIFACTS/plans/$name"
done
assert_no_file "$ARTIFACTS/plans/old.md"
[[ ! -s "$TMP_DIR/archive.err" ]] || fail "a plan in .dex/plans warned: $(cat "$TMP_DIR/archive.err")"
assert_file "$PROJECT/.dex/plans/calm-plan.md"   # copied, never moved

# Claude Code before 2.1.9 ignores plansDirectory: the plan is copied from
# ~/.claude/plans, only it and its own subagent files, with a warning.
GLOBAL="$HOME/.claude/plans"
mkdir -p "$GLOBAL" "$TMP_DIR/empty-project"
ARTIFACTS=$(new_run sess-b "$TMP_DIR/empty-project")
printf 'someone else\n' > "$GLOBAL/other-session.md"
touch -t 202602010000 "$GLOBAL/other-session.md"
printf 'ours\n' > "$GLOBAL/swift-orbit.md"
printf 'ours, explored\n' > "$GLOBAL/swift-orbit-agent-a7a6238.md"
dx_run_archive_plans sess-b "$TMP_DIR/empty-project" 2> "$TMP_DIR/fallback.err"
assert_eq ours "$(cat "$ARTIFACTS/plan.md")" 'fallback plan.md'
assert_file "$ARTIFACTS/plans/swift-orbit-agent-a7a6238.md"
assert_no_file "$ARTIFACTS/plans/other-session.md"
assert_contains "does not support plansDirectory" "$TMP_DIR/fallback.err"
assert_file "$GLOBAL/swift-orbit.md"             # ~/.claude is only read

# Nothing written since the run began: no copy, no failure.
rm -f "$GLOBAL"/*.md
ARTIFACTS=$(new_run sess-c "$TMP_DIR/empty-project")
dx_run_archive_plans sess-c "$TMP_DIR/empty-project"
assert_no_file "$ARTIFACTS/plan.md"
# A session with no run is not an error either.
dx_run_archive_plans no-such-session "$PROJECT"

# ── Before a worktree goes, its plans go to its run ────────────────────────
WT_SESSION=$(cd "$REPO" && dx_session_id wt)
ARTIFACTS=$(new_run "$WT_SESSION" "$WT")
printf 'worktree plan\n' > "$WT/.dex/plans/a-plan.md"
# Inside another Dex session: its DEX_RUN_ID must not claim this worktree's plan.
(cd "$REPO" && DEX_RUN_ID=run_test_somebody_else dx_wt_remove "$WT" "$REPO") > /dev/null 2>&1
[[ ! -d "$WT" ]] || fail "dx_wt_remove left the worktree"
assert_eq 'worktree plan' "$(cat "$ARTIFACTS/plan.md")" 'plan copied before the worktree was removed'
assert_no_file "$DX_RUN_ROOT/run_test_somebody_else/artifacts/plan.md"

printf 'launch plans tests passed\n'
