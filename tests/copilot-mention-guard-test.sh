#!/usr/bin/env bash
# The block-copilot-mention guard (hooks/guards/copilot-mention-comment.md and
# the `copilot-mention-comment` detector): a gh command that would post
# @copilot in a comment, review or PR/issue body is denied, because that
# mention summons the Copilot coding agent. Requesting Copilot as a reviewer
# is allowed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
HANDLER="$ROOT/hooks/guard-handler.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-copilot-guard-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export DEX_DIR="$ROOT"
export HOME="$TMP_DIR/home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
unset DEX_SESSION_ID
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

failures=0

# guard_rc <command> — the handler's exit code for a Bash tool call.
guard_rc() {
  local payload rc=0
  payload=$(python3 -c 'import json, sys; print(json.dumps({"tool_input": {"command": sys.argv[1]}}))' "$1")
  printf '%s' "$payload" | DEX_GUARD_EVENT=bash python3 "$HANDLER" >"$TMP_DIR/out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

expect_blocked() {
  local rc
  rc=$(guard_rc "$1")
  if [[ "$rc" != "2" ]] || ! grep -q 'block-copilot-mention' "$TMP_DIR/out"; then
    printf 'FAIL (expected block, rc=%s): %s\n' "$rc" "$1" >&2
    failures=$((failures + 1))
  fi
}

expect_allowed() {
  local rc
  rc=$(guard_rc "$1")
  if [[ "$rc" == "2" ]] || grep -q 'block-copilot-mention' "$TMP_DIR/out"; then
    printf 'FAIL (expected allow, rc=%s): %s\n' "$rc" "$1" >&2
    failures=$((failures + 1))
  fi
}

body_file="$TMP_DIR/body.md"
printf 'Thanks @Copilot, please fix this.\n' > "$body_file"
clean_file="$TMP_DIR/clean.md"
printf 'Updated: @greptileai, please re-review.\n' > "$clean_file"

# Posting @copilot in any form is blocked.
expect_blocked 'gh pr comment 7 --body "@copilot please fix the lint error"'
expect_blocked "gh issue comment 3 -b 'hey @Copilot'"
expect_blocked 'gh pr comment 7 --body "cc @github-copilot"'
expect_blocked 'gh -R owner/repo pr comment 7 --body "@copilot"'
expect_blocked 'gh pr review 7 --comment -b "@copilot can you take this"'
expect_blocked 'gh pr create --title t --body "Assigning to @copilot"'
expect_blocked 'gh pr edit 7 --body "@copilot"'
expect_blocked "gh api repos/o/r/issues/7/comments -f body='@copilot please'"
expect_blocked "gh api graphql -f query='mutation { addComment(input: {body: \"@copilot\"}) { clientMutationId } }'"
expect_blocked "$(printf 'gh pr comment 7 --body-file - <<%sEOF%s\nPlease take over, @copilot.\nEOF' "'" "'")"
expect_blocked 'MSG="hi @copilot"; gh pr comment 7 --body "$MSG"'
expect_blocked "bash -c 'gh pr comment 7 --body \"@copilot\"'"
expect_blocked "gh pr comment 7 --body-file $body_file"
expect_blocked "gh pr comment 7 --body-file=$body_file"
expect_blocked 'gh pr edit 7 --add-reviewer @copilot && gh pr comment 7 --body "@copilot review"'
# A command substitution is parsed twice; its reviewer value still counts once.
expect_blocked 'R=$(gh pr edit 7 --add-reviewer @copilot); gh pr comment 7 --body "@copilot fix"'
# A reviewer flag quoted inside the posted text is prose, so still a mention.
expect_blocked 'gh pr comment 7 --body "I ran gh pr edit 7 --add-reviewer @copilot"'
expect_blocked 'gh pr comment 7 --body "fixed -r @copilot please look"'
expect_blocked 'gh pr review 7 -r -b "@copilot please fix"'
prose_file="$TMP_DIR/prose.md"
printf 'Requested with gh pr edit 7 --add-reviewer @copilot\n' > "$prose_file"
expect_blocked "gh pr comment 7 --body-file $prose_file"
expect_blocked "gh api repos/o/r/issues/7/comments -F body=@$body_file"
expect_blocked "gh api repos/o/r/issues/7/comments --input $body_file"

# Requesting Copilot as a reviewer, and everything that is not a gh post, is fine.
expect_allowed 'gh pr edit 7 --add-reviewer @copilot'
expect_allowed 'gh pr edit 7 --add-reviewer=@copilot'
expect_allowed 'gh pr create --fill --reviewer @copilot'
expect_allowed 'gh pr create --fill -r @copilot,octocat'
expect_allowed 'gh -R owner/repo pr create --fill -r @copilot'
expect_allowed "bash -c 'gh pr edit 7 --add-reviewer @copilot'"
expect_allowed 'R=$(gh pr edit 7 --add-reviewer @copilot)'
expect_allowed 'gh pr edit 7 --add-reviewer "@copilot"'
expect_allowed 'gh pr comment 7 --body "@greptileai review"'
expect_allowed "gh pr comment 7 --body \"Copilot's review flagged the retry loop\""
expect_allowed 'gh pr comment 7 --body "mail someone@copilot.example"'
expect_allowed "gh pr comment 7 --body-file $clean_file"
expect_allowed 'gh pr view 7 --json reviews --jq ".reviews[] | select(.author.login == \"@copilot\")"'
expect_allowed "gh api repos/o/r/pulls/7/reviews --jq '.[] | select(.body | test(\"@copilot\"))'"
expect_allowed "gh api -X GET search/issues -f q='@copilot in:comments'"
expect_blocked "gh api -X PATCH repos/o/r/issues/comments/5 -f body='@copilot'"
expect_allowed 'echo "@copilot"'
expect_allowed 'git commit -m "docs: never write @copilot in a PR comment"'
expect_allowed 'grep -rn "@copilot" prompts/'

[[ "$failures" -eq 0 ]] || assert_at $LINENO
printf 'copilot mention guard tests passed\n'
