#!/usr/bin/env bash
# The reviewer adapters are wired through the lifecycle prompts: the adapter
# prompts exist and say what they must, Phase 6 and the PR watcher use the
# reviewer gate, CI readiness and cycle accounting, and no shipped command
# posts an @copilot comment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

GREPTILE="$ROOT/prompts/reviewers/greptile.md"
COPILOT="$ROOT/prompts/reviewers/copilot.md"
PHASE6="$ROOT/prompts/phase-audits/6-complete.md"
WATCH="$ROOT/prompts/workflows/dxwatchpr.md"
COMPLETE="$ROOT/skills/dxcomplete/SKILL.md"

assert_file "$GREPTILE"
assert_file "$COPILOT"

# Greptile: triggered through the helper, and targeted review is a documented tool.
assert_contains 'dx_reviewer_trigger' "$GREPTILE"
assert_contains '## Targeted review' "$GREPTILE"
assert_contains 'greptile "<area> and how it interacts with <other area>"' "$GREPTILE"
assert_contains 'Please focus on <focus>.' "$GREPTILE"
assert_contains 'prompts/untrusted-input.md' "$GREPTILE"

# Copilot: requested as a reviewer, never mentioned in a comment.
assert_contains '## Never write @copilot' "$COPILOT"
assert_contains '--add-reviewer @copilot' "$COPILOT"
assert_contains 'Request it again after' "$COPILOT"
assert_contains 'prompts/untrusted-input.md' "$COPILOT"

# Phase 6 holds completion for waited reviewers and does not spend the idle
# budget while CI or a reviewer is still running.
for doc in "$PHASE6" "$COMPLETE"; do
  assert_contains 'dx_reviewers_rows' "$doc"
  assert_contains 'dx_reviewer_trigger' "$doc"
  assert_contains 'dx_reviewer_comment' "$doc"
  assert_contains 'dx_reviewer_gate' "$doc"
  assert_contains 'dx_complete_ci_state' "$doc"
  assert_contains 'dx_complete_record_cycle "$SESSION_ID" waiting' "$doc"
  assert_contains 'dx_complete_record_cycle "$SESSION_ID" idle' "$doc"
  assert_contains 'dx_complete_record_cycle "$SESSION_ID" progress' "$doc"
done
assert_contains '### Case W — Waiting on CI or a waited reviewer' "$PHASE6"
assert_contains 'Case A requires `CI_STATE` green, `GATE_RC` 0' "$PHASE6"
assert_contains 'reported as "not reviewed"' "$PHASE6"
assert_contains 'no reviewer row has `wait: yes`' "$PHASE6"

# The watcher must not cancel itself before waited reviewers report.
assert_contains 'dx_complete_ci_state' "$WATCH"
assert_contains 'dx_reviewer_gate' "$WATCH"
assert_contains 'CI green, `GATE_RC` 0, `THREADS_RC` 0, and no actionable comments' "$WATCH"
assert_contains 'dx_reviewer_comment "$SESSION_ID" "$PR_NUM" "Updated:' "$WATCH"

# The review-thread policy: /dxprreview replies through the helper, clears a
# stray pending review only after saving it, and Phase 6 reads open threads
# through the helper, reports disagreements and never blocks on them.
REVIEW="$ROOT/prompts/workflows/dxprreview.md"
assert_contains 'dx_pr_thread_policy' "$REVIEW"
assert_contains 'dx_pr_thread_respond' "$REVIEW"
assert_contains 'dx_pr_pending_review_clear' "$REVIEW"
assert_contains 'draft-comment count and backup file path' "$REVIEW"
# dx maintain respond's provider makes no GitHub writes, the cleanup included.
assert_contains 'it under `dx maintain respond`: that provider makes no GitHub writes' "$REVIEW"
assert_contains '**Left open for the maintainer (disagreements):**' "$REVIEW"
assert_not_contains 'resolveReviewThread' "$REVIEW"
for doc in "$PHASE6" "$COMPLETE" "$WATCH"; do
  assert_contains 'dx_pr_threads_open "$SESSION_ID" "$REPO" "$PR_NUM"' "$doc"
  assert_contains 'Disagreements left open for the maintainer' "$doc"
  assert_contains 'THREADS_RC' "$doc"
  assert_not_contains 'reviewThreads(first: 100' "$doc"
done
for doc in "$GREPTILE" "$COPILOT"; do
  assert_contains 'thread_policy' "$doc"
  assert_contains 'dx_pr_thread_respond' "$doc"
  assert_not_contains 'issue #12' "$doc"
done
assert_contains 'thread_policy: keep-disagreements-open' "$ROOT/prompts/init-analysis.md"
assert_contains '`thread_policy`' "$ROOT/docs/autonomous-mode.md"

# Adapter bots post under their own logins; their comments are feedback.
assert_contains 'dx_reviewer_adapter_logins' "$ROOT/prompts/workflows/dxprreview.md"
assert_contains 'prompts/reviewers/<adapter>.md' "$ROOT/prompts/workflows/dxpr.md"
assert_contains 'prompts/reviewers/<adapter>.md' "$ROOT/prompts/phase-audits/5-pr.md"

# No shipped command posts PR or issue text that mentions @copilot. Prose that
# warns against it is fine; a gh posting command or a dx_reviewer_comment call
# on the same line as the mention is not. Reviewer flags are the supported way
# to name Copilot and are ignored.
hits=$(cd "$ROOT" && git ls-files -z -- prompts skills lib bin hooks templates .github docs \
    dx.sh AGENTS.md README.md settings.json \
  | xargs -0 grep -nEi '(^|[^A-Za-z0-9_.-])@(github-)?copilot' 2>/dev/null \
  | grep -Ei 'gh +(-R +[^ ]+ +)?(pr|issue) +(comment|review|create|edit)|gh +api|dx_reviewer_comment ' \
  | grep -Ev -- '--add-reviewer|--reviewer|-r @copilot' || true)
if [[ -n "$hits" ]]; then
  printf 'shipped commands that post @copilot:\n%s\n' "$hits" >&2
  assert_at $LINENO
fi

printf 'reviewer adapter contract tests passed\n'
