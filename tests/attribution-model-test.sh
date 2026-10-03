#!/usr/bin/env bash
# dex-test-lane: fast
# The optional model trailer: the model is resolved at commit time from the
# current session's own transcript, the CCR router, then the provider config.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-attribution-model.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DEX_HOME="$TMP_DIR/dex-home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEX_ROUTER_HOME="$TMP_DIR/router"
export CLAUDE_CONFIG_DIR="$TMP_DIR/claude"
unset DEX_SESSION_ID DX_ROUTER_SESSION_ID DX_MODEL DX_MODEL_OVERRIDE DX_AGENT DX_AGENT_OVERRIDE DX_PROVIDER_PROFILE
mkdir -p "$HOME" "$DX_STATE_DIR"
# The provider fallback reads the current repository's profile; keep it neutral.
cd "$TMP_DIR"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

repo="$TMP_DIR/repo"
git init -q "$repo"
git -C "$repo" config user.email "dex@example.test"
git -C "$repo" config user.name "Dex Test"
mkdir -p "$repo/.dex"
cat > "$repo/.dex/dex.md" <<'CONTRACT'
## Attribution

```yaml
model_trailer: AI-Model
```
CONTRACT
dx_install_repo_attribution "$repo" > "$TMP_DIR/install.out"

session="repo-test-worktree-model"
conversation="0379286e-0000-4000-8000-000000000001"
dx_agent_session_handle_write "$session" claude "$conversation"
dx_meta_write "$session" "wt_dir=$repo"
encoded=$(printf '%s' "$repo" | sed 's/[^A-Za-z0-9]/-/g')
transcript="$CLAUDE_CONFIG_DIR/projects/$encoded/$conversation.jsonl"
mkdir -p "$(dirname "$transcript")"

# assistant_row <model> [padding-bytes]
assistant_row() {
  python3 - "$1" "${2:-0}" <<'PY'
import json, sys
model, padding = sys.argv[1], int(sys.argv[2])
print(json.dumps({"type": "assistant", "message": {
    "model": model, "usage": {"input_tokens": 1},
    "content": [{"type": "text", "text": "x" * padding}]}}))
PY
}

commit_in_session() {
  printf '%s\n' "$RANDOM" >> "$repo/file.txt"
  git -C "$repo" add file.txt
  DEX_SESSION_ID="$session" git -C "$repo" commit -q -m "$1"
}

model_trailer() {
  git -C "$repo" log -1 --format='%(trailers:key=AI-Model,valueonly)' | sed '/^$/d'
}

{
  printf '{"type":"user","message":{"content":"hi"}}\n'
  assistant_row claude-model-a
} > "$transcript"
commit_in_session "feat: first"
first_commit=$(git -C "$repo" rev-parse HEAD)
[[ "$(model_trailer)" == "claude-model-a" ]] || assert_at $LINENO

# A mid-session model switch shows on the next commit. Synthetic rows (Claude
# Code's local notices) and rows without usage are not model turns.
{
  assistant_row claude-model-b
  printf '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0}}}\n'
  printf '{"type":"assistant","message":{"model":"claude-no-usage"}}\n'
  printf 'not json\n'
} >> "$transcript"
commit_in_session "feat: second"
[[ "$(model_trailer)" == "claude-model-b" ]] || assert_at $LINENO

# A turn longer than one read chunk is still found whole.
assistant_row claude-model-large 400000 >> "$transcript"
commit_in_session "feat: third"
[[ "$(model_trailer)" == "claude-model-large" ]] || assert_at $LINENO

# An amend records the model that made it, replacing the earlier line.
assistant_row claude-model-c >> "$transcript"
DEX_SESSION_ID="$session" git -C "$repo" commit -q --amend --no-edit
[[ "$(model_trailer)" == "claude-model-c" ]] || assert_at $LINENO
[[ "$(git -C "$repo" log -1 --format=%B | grep -c '^AI-Model:')" -eq 1 ]] || assert_at $LINENO

# Commits a person makes outside a Dex session get no model trailer.
printf 'human\n' >> "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m "fix: by hand"
[[ -z "$(model_trailer)" ]] || assert_at $LINENO

# The CCR router's record of the model it served comes first.
mkdir -p "$DEX_ROUTER_HOME/sessions"
printf '{"current_model":"routed-model"}\n' > "$DEX_ROUTER_HOME/sessions/route-1.json"
[[ "$(DX_ROUTER_SESSION_ID=route-1 dx_attribution_model "$session" "$repo")" == "routed-model" ]] || assert_at $LINENO

# Only the session's own transcript is read. A file with the same conversation
# id under another project directory is never found.
other_session="repo-test-worktree-other"
other_conversation="0379286e-0000-4000-8000-000000000002"
dx_agent_session_handle_write "$other_session" claude "$other_conversation"
dx_meta_write "$other_session" "wt_dir=$TMP_DIR/elsewhere"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-unrelated-project"
assistant_row claude-wrong-project > "$CLAUDE_CONFIG_DIR/projects/-unrelated-project/$other_conversation.jsonl"
[[ "$(dx_attribution_model "$other_session" "$repo")" == "unknown" ]] || assert_at $LINENO

# With no transcript, the configured provider model is used.
[[ "$(DX_MODEL=claude-configured dx_attribution_model "$other_session" "$repo")" == "claude-configured" ]] || assert_at $LINENO

# Without a valid session, only the configuration can answer.
[[ "$(dx_attribution_model "" "$repo")" == "unknown" ]] || assert_at $LINENO
[[ "$(dx_attribution_model "../escape" "$repo")" == "unknown" ]] || assert_at $LINENO

# The branch's models: distinct trailer values plus the current model.
DEX_SESSION_ID="$session" dx_attribution_branch_models "$repo" "$first_commit" > "$TMP_DIR/branch-models.out"
assert_contains "claude-model-b" "$TMP_DIR/branch-models.out"
assert_contains "claude-model-c" "$TMP_DIR/branch-models.out"
assert_not_contains "claude-model-a" "$TMP_DIR/branch-models.out"
[[ "$(grep -c 'claude-model-c' "$TMP_DIR/branch-models.out")" -eq 1 ]] || assert_at $LINENO

# The same list through the command the prompts call.
(cd "$repo" && DEX_SESSION_ID="$session" bash "$ROOT/bin/attribution.sh" models "$first_commit") > "$TMP_DIR/cli-models.out"
assert_contains "claude-model-b" "$TMP_DIR/cli-models.out"
assert_contains "claude-model-c" "$TMP_DIR/cli-models.out"
[[ "$(cd "$repo" && bash "$ROOT/bin/attribution.sh" mode)" == "dex" ]] || assert_at $LINENO
bash "$ROOT/bin/attribution.sh" --help > "$TMP_DIR/cli-help.out"
assert_contains "Usage: dx attribution" "$TMP_DIR/cli-help.out"
! (cd "$repo" && bash "$ROOT/bin/attribution.sh" bogus) > /dev/null 2>&1 || assert_at $LINENO
! (cd "$TMP_DIR" && bash "$ROOT/bin/attribution.sh" mode) > /dev/null 2>&1 || assert_at $LINENO

# With the trailer off there is nothing to list.
printf '# Project\n' > "$repo/.dex/dex.md"
[[ -z "$(DEX_SESSION_ID="$session" dx_attribution_branch_models "$repo" "$first_commit")" ]] || assert_at $LINENO

printf 'attribution model tests passed\n'
