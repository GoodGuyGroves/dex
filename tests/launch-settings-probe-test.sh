#!/usr/bin/env bash
# Probe: how the real Claude Code combines a launch's --settings hooks with the
# user's and the project's. launch-settings-test.sh covers Dex's side with a
# stub; this checks the assumptions it rests on:
# - hooks from --settings, user settings and project settings all run
#   (arrays add up rather than one layer replacing another);
# - a global command gated on DEX_LAUNCHED stays silent in a Dex launch;
# - disableAllHooks false in --settings beats true in user or local settings;
# - --setting-sources drops the excluded layer but never the --settings file;
# - whether a byte-identical command in two layers runs once or twice
#   (reported; a legacy ungated install relies on the answer);
# - plansDirectory keeps a plan-mode run's plan out of ~/.claude/plans.
#
# It runs only with DEX_PROBE_REAL_CLAUDE=1, needs a real `claude` and an
# ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN, and makes five short model
# calls. HOME and CLAUDE_CONFIG_DIR point into a sandbox; the real ones are
# not read. The FINDINGS block at the end is the result to record.
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

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-launch-settings-probe.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

LOG="$TMP_DIR/hooks.log"
SANDBOX_HOME="$TMP_DIR/home"
REPO="$TMP_DIR/repo"
USER_SETTINGS="$SANDBOX_HOME/.claude/settings.json"
PROJECT_SETTINGS="$REPO/.claude/settings.json"
LOCAL_SETTINGS="$REPO/.claude/settings.local.json"
LAUNCH="$TMP_DIR/launch.json"
mkdir -p "$SANDBOX_HOME/.claude" "$REPO/.claude"
git -C "$REPO" init -q

# settings <file> <disableAllHooks: true|false|-> <label>... — UserPromptSubmit
# hooks that append each label.
settings() {
  local file="$1" disable="$2"
  shift 2
  python3 - "$file" "$LOG" "$disable" "$@" <<'PY'
import json, shlex, sys
file, log, disable, labels = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
def command(label):
    gate = '[ -z "${DEX_LAUNCHED:-}" ] || exit 0; ' if label == "gated" else ""
    return gate + "printf '%%s\\n' %s >> %s" % (shlex.quote(label), shlex.quote(log))
hooks = [{"type": "command", "command": command(label)} for label in labels]
document = {"hooks": {"UserPromptSubmit": [{"matcher": "", "hooks": hooks}]}}
if disable != "-":
    document["disableAllHooks"] = disable == "true"
json.dump(document, open(file, "w"))
PY
}

# run_claude [claude-option...] — one Dex-style launch with the launch file.
run_claude() {
  : > "$LOG"
  (
    cd "$REPO"
    env HOME="$SANDBOX_HOME" CLAUDE_CONFIG_DIR="$SANDBOX_HOME/.claude" DEX_LAUNCHED=1 \
      python3 "$ROOT/tests/test-timeout.py" 180 claude -p 'Reply with the single word OK.' \
        --settings "$LAUNCH" --dangerously-skip-permissions \
        --permission-mode bypassPermissions "$@" < /dev/null
  ) > "$TMP_DIR/claude.out" 2>&1 || { cat "$TMP_DIR/claude.out" >&2; fail 'claude -p failed'; }
}

count() { grep -cx "$1" "$LOG" 2>/dev/null || true; }
yes_no() { if [[ "$1" -ge 1 ]]; then printf yes; else printf no; fi; }
FINDINGS=()
finding() { FINDINGS+=("$1: $2"); }
FAILED=()

# 1. Every layer together.
settings "$USER_SETTINGS" - user shared gated
settings "$PROJECT_SETTINGS" - project
settings "$LAUNCH" false launch shared
run_claude
finding launch-hook-runs "$(yes_no "$(count launch)")"
finding user-hook-runs-beside-launch "$(yes_no "$(count user)")"
finding project-hook-runs-beside-launch "$(yes_no "$(count project)")"
finding gated-global-hook-runs-in-dex-launch "$(yes_no "$(count gated)")"
if [[ "$(count shared)" -ge 2 ]]; then
  finding identical-command-twice yes
else
  finding identical-command-twice no
fi
[[ "$(count launch)" -ge 1 ]] || FAILED+=('the --settings hook did not run')
[[ "$(count user)" -ge 1 ]] || FAILED+=('the user settings hook did not run beside --settings')
[[ "$(count gated)" -eq 0 ]] || FAILED+=('a DEX_LAUNCHED-gated command ran inside a Dex launch')

# 2. A user's disableAllHooks true against the launch file's false.
settings "$USER_SETTINGS" true user
settings "$PROJECT_SETTINGS" - project
settings "$LAUNCH" false launch
run_claude
finding launch-beats-user-disableAllHooks "$(yes_no "$(count launch)")"
[[ "$(count launch)" -ge 1 ]] || FAILED+=("--settings disableAllHooks false lost to the user's true")

# 3. The same against .claude/settings.local.json.
settings "$USER_SETTINGS" - user
settings "$LOCAL_SETTINGS" true local
run_claude
finding launch-beats-local-disableAllHooks "$(yes_no "$(count launch)")"
[[ "$(count launch)" -ge 1 ]] || FAILED+=("--settings disableAllHooks false lost to settings.local.json's true")
rm -f "$LOCAL_SETTINGS"

# 4. --setting-sources project: the user layer goes, the launch file stays.
settings "$USER_SETTINGS" - user
settings "$PROJECT_SETTINGS" - project
run_claude --setting-sources project
finding launch-hook-runs-under-setting-sources-project "$(yes_no "$(count launch)")"
finding excluded-user-hook-runs-under-setting-sources-project "$(yes_no "$(count user)")"
[[ "$(count launch)" -ge 1 ]] || FAILED+=('--setting-sources project dropped the --settings hooks')
[[ "$(count user)" -eq 0 ]] || FAILED+=('--setting-sources project still ran the user hook')

# 5. plansDirectory: a plan-mode run writes its plan under the launch
#    directory, never ~/.claude/plans. A -p run may finish without writing a
#    plan at all; that is reported, not failed.
rm -f "$PROJECT_SETTINGS" "$LOCAL_SETTINGS"
printf '%s\n' '{}' > "$USER_SETTINGS"
printf '%s\n' '{"plansDirectory":".dex/plans","promptSuggestionEnabled":false}' > "$LAUNCH"
(
  cd "$REPO"
  env HOME="$SANDBOX_HOME" CLAUDE_CONFIG_DIR="$SANDBOX_HOME/.claude" DEX_LAUNCHED=1 \
    python3 "$ROOT/tests/test-timeout.py" 300 claude -p \
      'Plan, in two short steps, how to add the line "probe" to README.md. Write the plan to your plan file, then call ExitPlanMode.' \
      --settings "$LAUNCH" --permission-mode plan < /dev/null
) > "$TMP_DIR/plan.out" 2>&1 || true
plans_here=$(find "$REPO/.dex/plans" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
plans_global=$(find "$SANDBOX_HOME/.claude/plans" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
finding plan-file-under-launch-dir "$(yes_no "$plans_here")"
finding plan-file-under-claude-plans "$(yes_no "$plans_global")"
[[ "$plans_global" -eq 0 ]] || FAILED+=('a plan file landed in ~/.claude/plans despite plansDirectory')

printf '%s\n' 'FINDINGS'
printf '  %s\n' "${FINDINGS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf 'probe failed: %s\n' "${FAILED[@]}" >&2
  exit 1
fi
printf 'launch settings probe passed\n'
