#!/usr/bin/env bash
# Probe: how the real Claude Code serves Dex's skills from --plugin-dir.
# plugin-packaging-test.sh covers Dex's side offline; this checks the
# assumptions it rests on:
# - every Dex skill loads as dex:<name> with no ~/.claude/skills at all;
# - the Skill tool takes both the bare name and dex:<name>;
# - beside a user skill of the same name, which skill the bare name loads
#   (reported) and that dex:<name> still loads Dex's (required);
# - beside a caller's second plugin also named dex, which one dex:<name>
#   loads (reported);
# - a Task subagent can call a plugin skill.
#
# It runs only with DEX_PROBE_REAL_CLAUDE=1, needs a real `claude` and an
# ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN, and makes six short model
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

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-plugin-skills-probe.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SANDBOX_HOME="$TMP_DIR/home"
REPO="$TMP_DIR/repo"
OUT="$TMP_DIR/stream.jsonl"
mkdir -p "$SANDBOX_HOME/.claude" "$REPO"
git -C "$REPO" init -q
EXPECTED=$(find "$ROOT/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')

# run_claude <prompt> [claude-option...] — one Dex-style launch with Dex's
# plugin directory first, as dx_provider_claude passes it.
run_claude() {
  local prompt="$1"
  shift
  (
    cd "$REPO"
    env -u DEX_HOME HOME="$SANDBOX_HOME" CLAUDE_CONFIG_DIR="$SANDBOX_HOME/.claude" DEX_LAUNCHED=1 \
      python3 "$ROOT/tests/test-timeout.py" 300 claude -p "$prompt" \
        --plugin-dir "$ROOT/plugin" "$@" --output-format stream-json --verbose \
        --dangerously-skip-permissions --permission-mode bypassPermissions < /dev/null
  ) > "$OUT" 2> "$TMP_DIR/claude.err" || { cat "$TMP_DIR/claude.err" >&2; fail 'claude -p failed'; }
}

# winner <marker>... — which humanizer the last run's Skill call loaded: the
# label of the first marker found, dex for Dex's own, or none.
DEX_HUMANIZER_MARKER='# Skill: Humanizer'
winner() {
  local label marker
  while [[ $# -gt 1 ]]; do
    label="$1" marker="$2"
    shift 2
    if [[ "$(inspect contains "$marker")" == yes ]]; then
      printf '%s\n' "$label"
      return 0
    fi
  done
  if [[ "$(inspect contains "$DEX_HUMANIZER_MARKER")" == yes ]]; then
    printf 'dex\n'
  else
    printf 'none\n'
  fi
}

# inspect <question> [arg] — read the last run's stream.
#   loaded           how many dex:* skills the session listed
#   skill-ok <name>  yes when a Skill call for <name> came back without error
#   subagent-skill   yes when a Skill call ran inside a subagent
#   contains <text>  yes when <text> appears anywhere in the stream
inspect() {
  python3 - "$OUT" "$@" <<'PY'
import json, sys
path, question, arg = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
events = []
for line in open(path):
    try:
        events.append(json.loads(line))
    except ValueError:
        pass
if question == "contains":
    print("yes" if arg in open(path).read() else "no")
    raise SystemExit
if question == "loaded":
    init = next((e for e in events if e.get("type") == "system" and e.get("subtype") == "init"), {})
    names = set(init.get("skills") or []) | set(init.get("slash_commands") or [])
    print(sum(1 for n in names if n.startswith("dex:")))
    raise SystemExit
calls, results = {}, {}
for e in events:
    for block in (e.get("message") or {}).get("content") or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "tool_use" and block.get("name") == "Skill":
            calls[block["id"]] = (block.get("input", {}).get("skill"), e.get("parent_tool_use_id"))
        elif block.get("type") == "tool_result":
            results[block.get("tool_use_id")] = bool(block.get("is_error"))
ok = lambda cid: cid in results and not results[cid]
if question == "skill-ok":
    print("yes" if any(name == arg and ok(cid) for cid, (name, _) in calls.items()) else "no")
elif question == "subagent-skill":
    print("yes" if any(parent and ok(cid) for cid, (_, parent) in calls.items()) else "no")
PY
}

ONLY_SKILL='Call the Skill tool exactly once, with skill "%s" and no arguments. Do not follow the skill or use any other tool. Then reply with the single word DONE.'
FINDINGS=()
finding() { FINDINGS+=("$1: $2"); }
FAILED=()

# 1. No ~/.claude/skills: the plugin alone, and the bare name.
# shellcheck disable=SC2059  # the format is ours
run_claude "$(printf "$ONLY_SKILL" humanizer)"
loaded=$(inspect loaded)
finding dex-skills-listed "$loaded/$EXPECTED"
finding bare-name-skill-call "$(inspect skill-ok humanizer)"
[[ "$loaded" -eq "$EXPECTED" ]] || FAILED+=("the session listed $loaded of $EXPECTED dex:* skills")
[[ "$(inspect skill-ok humanizer)" == yes ]] || FAILED+=('the Skill tool refused the bare name')

# 2. The prefixed name.
# shellcheck disable=SC2059
run_claude "$(printf "$ONLY_SKILL" dex:humanizer)"
finding prefixed-name-skill-call "$(inspect skill-ok dex:humanizer)"
[[ "$(inspect skill-ok dex:humanizer)" == yes ]] || FAILED+=('the Skill tool refused dex:humanizer')

# 3. A user skill with the same name: which one each name reaches. Dex's
# generated prompts use dex:<name> because of this case.
mkdir -p "$SANDBOX_HOME/.claude/skills/humanizer"
printf '%s\n' '---' 'name: humanizer' 'description: user copy for the Dex probe' '---' \
  'USER-SKILL-MARKER-8271' > "$SANDBOX_HOME/.claude/skills/humanizer/SKILL.md"
# shellcheck disable=SC2059
run_claude "$(printf "$ONLY_SKILL" humanizer)"
finding bare-humanizer-beside-user-humanizer-loads "$(winner user USER-SKILL-MARKER-8271)"
# shellcheck disable=SC2059
run_claude "$(printf "$ONLY_SKILL" dex:humanizer)"
prefixed_winner=$(winner user USER-SKILL-MARKER-8271)
finding dex:humanizer-beside-user-humanizer-loads "$prefixed_winner"
[[ "$prefixed_winner" == dex ]] || FAILED+=("dex:humanizer loaded $prefixed_winner, not Dex's skill, beside a user skill")
rm -rf "$SANDBOX_HOME/.claude/skills"

# 3b. A caller's own --plugin-dir whose plugin is also named dex, after Dex's.
OTHER="$TMP_DIR/other-plugin"
mkdir -p "$OTHER/.claude-plugin" "$OTHER/skills/humanizer"
printf '%s\n' '{"name":"dex"}' > "$OTHER/.claude-plugin/plugin.json"
printf '%s\n' '---' 'name: humanizer' 'description: another dex plugin for the Dex probe' '---' \
  'OTHER-PLUGIN-MARKER-5530' > "$OTHER/skills/humanizer/SKILL.md"
# shellcheck disable=SC2059
run_claude "$(printf "$ONLY_SKILL" dex:humanizer)" --plugin-dir "$OTHER"
finding dex:humanizer-with-second-dex-plugin-loads "$(winner other OTHER-PLUGIN-MARKER-5530)"
finding dex-skills-listed-with-second-dex-plugin "$(inspect loaded)/$EXPECTED"

# 4. A Task subagent reaching a plugin skill.
run_claude 'Use the Task tool once to start a general-purpose subagent. Its only job: call the Skill tool exactly once with skill "dex:humanizer" and no arguments, without following the skill, then reply DONE. After it returns, reply with the single word DONE.'
finding subagent-skill-call "$(inspect subagent-skill)"
[[ "$(inspect subagent-skill)" == yes ]] || FAILED+=('a subagent could not call a plugin skill')

printf '%s\n' 'FINDINGS'
printf '  %s\n' "${FINDINGS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf 'probe failed: %s\n' "${FAILED[@]}" >&2
  exit 1
fi
printf 'plugin skills probe passed\n'
