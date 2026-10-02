Phase 6 (Complete) is the bounded autonomous PR monitoring loop. Phase 5 should
have left the PR ready for review; verify that state and repair it if an
interrupted or pre-existing draft remains. Then request reviews, monitor CI and
review comments through the PR watcher, address failures, and close the ticket
once CI is green and actionable review feedback is resolved. Do not merge the
PR.

When `.dex/dex.md` § Resources declares `full_gate: ci`, Phase 5 deliberately
left the PR a draft and CI is this ticket's complete gate: fix and re-push
through this same loop until it is green, then mark the PR ready before
completing. CI is the final arbiter either way.

This phase runs as a **cycle loop**. Each cycle is one Stop hook iteration. Between cycles you wait — the loop infrastructure handles wall-clock time, not you.

Before posting PR comments, ticket updates, or free-form status summaries, invoke
the `humanizer` skill. Preserve reviewer handles, PR numbers, ticket IDs,
commands, counts, status labels, and required audit wording exactly.

Follow § Resource Discipline in `prompts/guardrails.md`: heavy work queues through `dx run-gate`; own what you start, the PR watcher loop included.

Apply `prompts/issue-hygiene.md` whenever CI, review comments, or completion
work reveals material new context. Reconcile accepted findings once through
the lifecycle owner; do not let scheduled watcher cycles create duplicate
issues. Every cycle summary, including idle and terminal cycles, ends with the
contract's exact `Issue/PR work:` line.

---

## Setup (only on the very first invocation)

Detect the cycle counter and whether setup has already run:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
COMPLETE_STATE_FILE="$(dx_complete_state_file "$SESSION_ID")"
CYCLE=0
LAST_EPOCH=0
SETUP_DONE=0
if [[ -f "$COMPLETE_STATE_FILE" ]]; then
  SETUP_DONE=1   # state file exists → setup ran in a prior iteration
  RAW=$(cat "$COMPLETE_STATE_FILE" 2>/dev/null || echo "")
  if [[ "$RAW" =~ ^([0-9]+):([0-9]+)$ ]]; then
    CYCLE="${BASH_REMATCH[1]}"
    LAST_EPOCH="${BASH_REMATCH[2]}"
  fi
fi
```

If `SETUP_DONE -eq 0` (state file did not exist — this is the very first invocation), perform the setup steps below. Otherwise skip directly to Monitoring.

The state file is the canonical "setup has run" marker. Do NOT use `CYCLE -eq 0` as the gate — `CYCLE` stays at `0` for the entire first wait window (it only increments when Outcome runs after the window matures), so gating on `CYCLE` would re-run setup on every audit iteration during that window and post duplicate `@mention` comments.

### Verify the PR is ready for review

```bash
PR_NUM=$(gh pr view --json number -q .number)
PR_DRAFT=$(gh pr view --json isDraft -q .isDraft)
if [[ "$PR_DRAFT" == "true" ]]; then
  gh pr ready "$PR_NUM"
fi
```

### Read the reviewer config

Read the `## Reviewers` rows through the shared parser:

```bash
REVIEWER_ROWS=$(dx_reviewers_rows "$(git rev-parse --show-toplevel)") || REVIEWER_ROWS=""
# One line per reviewer: handle<TAB>type<TAB>wait<TAB>adapter
```

Rows whose adapter is `generic` are today's `request` and `mention` rows. Rows
with adapter `greptile` or `copilot` are adapter rows: read
`$DEX_DIR/prompts/reviewers/<adapter>.md` before acting on them. `wait` is `yes` only
when the project opted that reviewer into the Phase 6 wait gate. The parser
already drops the `_none_` placeholder and makes every Copilot row a `request`
row. If there are no rows, skip directly to Monitoring (the user has chosen
not to assign anyone).

### Request reviewers (`request` type)

For each generic `request` reviewer, normalize the handle with
`dx_maintenance_request_reviewer "$PR_NUM" "<handle>"`. This strips the leading
`@` for normal usernames, but preserves GitHub CLI's special `@copilot` value
for Copilot review requests. This is idempotent when GitHub accepts the reviewer.
If GitHub says a reviewer is not requestable for this repository, log the warning
and continue. Do not pipe review-request command output into `jq`.
Reviewer rows route notifications; they do not create Dex-specific approval
requirements. GitHub's aggregate `reviewDecision` is useful merge-readiness
information, but Phase 6 does not merge and must not wait for an approval.

### Trigger adapter reviewers

For each adapter row (`greptile` or `copilot`), ask for a review of the head
through the adapter helper instead of the plain request or mention:

```bash
dx_reviewer_trigger "$SESSION_ID" "$(git rev-parse --show-toplevel)" "$PR_NUM" "<handle>" "<adapter>"
```

It requests Copilot with `--add-reviewer @copilot`, posts Greptile's review
comment, and records the trigger time that the wait gate measures from.

### Post mention comment (`mention` type)

If there are any generic `mention` reviewers, post a single comment on the PR
mentioning all of them, through the comment helper:

```bash
dx_reviewer_comment "$SESSION_ID" "$PR_NUM" "Requesting review from @bot1 @bot2."
```

Run the body through `humanizer` before posting if you customize it. The point
is the `@mention` so the bots see it. Never mention `@copilot` in a comment:
it summons the Copilot coding agent. The helper refuses such a body, and the
`block-copilot-mention` guard denies the command.

---

## Monitoring (every cycle)

Launch the PR watcher loop if it isn't already running. `/loop` is a built-in Claude Code skill — `/loop <interval> <slash-command>` runs the command on a recurring interval in the background.

```
/loop 5m /dxwatchpr
```

This runs between turns and won't consume context. `/dxwatchpr` checks CI status, fixes CI failures when appropriate, reads review comments, hands them to `/dxprreview`, pushes fixes, replies inline, and resolves review threads when Dex's reply closes the comment.

If the user sends a direct prompt while Phase 6 is active, the `UserPromptSubmit` hook writes a watcher-pause marker. Scheduled `/dxwatchpr` invocations must no-op while that marker is active and must not run GitHub/CI commands. Running `/dxcomplete` or explicitly asking to resume watchers clears the marker. The default pause TTL is `60m 0s`.

Each watcher invocation reads `dx_watch_cycle_timeout_seconds` (default `2m 0s`). If the previous watcher cycle is still locked within that current runtime budget, the next `/loop` tick must no-op instead of overlapping.

---

## Wait window

Each cycle reads its minimum wait from `dx_complete_wait_minutes` (default 5) before declaring the cycle idle and moving on. You don't sleep — you simply stop and let the Stop hook's audit loop re-engage you on the next iteration. Compute elapsed time:

```bash
NOW=$(date +%s)
ELAPSED=$((NOW - LAST_EPOCH))
WAIT_MINUTES=$(dx_complete_wait_minutes "${DEX_SESSION_ID:-$(dx_session_id)}")
WAIT_SECONDS=$((WAIT_MINUTES * 60))
```

If `LAST_EPOCH -eq 0` (very first cycle — setup just ran):
- Proceed directly to Outcome. Do not write the state file or wait merely to
  give requested reviewers time to respond. If CI is already green, there is
  no actionable review feedback, and no reviewer row has `wait: yes`, Phase 6
  can complete without a review or approval. A `wait: yes` reviewer is the
  exception: the Outcome's reviewer gate holds completion until it has
  reviewed the head or timed out.

If `ELAPSED -lt WAIT_SECONDS`, the wait window hasn't elapsed:
- Confirm the watcher loop is still running (one `gh pr view --json` is fine; do NOT run `/dxprreview` directly here — that's the watcher's job).
- Update the state file: `echo "${CYCLE}:${LAST_EPOCH}" > "$COMPLETE_STATE_FILE"`
- Stop. The Stop hook will re-inject this audit on the next iteration; that iteration also will not be authorized to complete until the window has elapsed.

If `ELAPSED -ge WAIT_SECONDS`, the cycle has matured — proceed to Outcome.

---

## Outcome (immediately on the first cycle, then after each wait window)

Check overall PR state:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
REPO_DIR=$(git rev-parse --show-toplevel)
CI_RC=0
CI_STATE=$(dx_complete_ci_state "$SESSION_ID" "$REPO_DIR" "$PR_NUM") || CI_RC=$?
# Line 1: green | pending | stalled | failed | error, then each check that has
# not passed. Honours `readiness_check` from the `## Resources` block.
GATE_RC=0
REVIEWER_WAITS=$(dx_reviewer_gate "$SESSION_ID" "$REPO_DIR" "$PR_NUM") || GATE_RC=$?
# One line per `wait: yes` reviewer: handle, adapter, state, elapsed seconds,
# detail. GATE_RC 0: every waited reviewer is done, timed out or unavailable.
# GATE_RC 1: at least one is still reviewing the head. GATE_RC 3: the PR head
# could not be read; like a CI query error, that cycle is idle, not waiting.
REVIEW_DECISION=$(gh pr view "$PR_NUM" --json reviewDecision --jq '.reviewDecision // ""')
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
REVIEW_STATE=$(dx_maintenance_pr_review_state "$REVIEW_DECISION") || REVIEW_STATE=unknown
gh api repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/pulls/$PR_NUM/reviews
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api graphql --paginate \
  -f owner="${REPO%%/*}" \
  -f name="${REPO#*/}" \
  -F number="$PR_NUM" \
  -f query='
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes { id isResolved }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'
```

Use `REVIEW_STATE` for reporting and feedback routing, not as a completion gate:

- `none`: no aggregate review decision is present.
- `approved`: GitHub reports an approving review. This includes a Copilot
  approval when repository and organization policy allow it to count.
- `review-required`: GitHub still requires an approval for merge. Report it in
  the handoff, but do not hold Phase 6 open for it.
- `changes-requested`: inspect and address the underlying feedback or escalate
  under the normal review rules. Once the feedback is handled and clear review
  threads are resolved, a stale formal decision does not hold Phase 6 open;
  report it for the maintainer.
- `unknown`, a query failure, or any unrecognized value: report that merge review
  state could not be determined. The review/comment/thread queries must still
  succeed before claiming that feedback is resolved.

Copilot submits `COMMENTED` reviews by default. If Copilot auto-approval is
enabled, it may instead submit `APPROVED`; no Copilot-specific completion rule
is needed. Its overview approval assessment is not a native approval.

CI is green only when `CI_STATE` starts with `green`. With `readiness_check`
declared, a missing readiness check is pending, not green. `error` means the
check query failed: report it and treat the cycle as idle, never as green.

### Case A — CI green, waited reviewers finished, and actionable review feedback is resolved

Case A requires `CI_STATE` green, `GATE_RC` 0, and no unresolved actionable
feedback. It applies regardless of whether there is a review, an approval, or
a `REVIEW_REQUIRED` merge decision. Request and mention rows only route
notifications; only `wait: yes` adapter rows hold completion, through the gate.
Substantive comments should already have been addressed via `/dxprreview`,
with clear review threads resolved after Dex replies.

List every waited reviewer from `REVIEWER_WAITS` in the completion summary
with its state on the head commit. A `timeout` or `unavailable` reviewer is
reported as "not reviewed" with its detail, never as a clean review.

Update the ticket (if a tracker is configured — see `dex.md § Integrations`). Print the completion summary (per `skills/dxcomplete/SKILL.md`, the Print Summary step). Cycle is done — proceed to Termination.

### Case B — Pending checks or unresolved feedback, but progress was made

If new commits were pushed during the cycle (`/dxwatchpr` fixed CI or `/dxprreview` addressed comments), re-trigger reviewers:

- For each generic `request` reviewer: run `dx_maintenance_request_reviewer "$PR_NUM" "<handle>"` again — they get a fresh notification when GitHub accepts the reviewer.
- For each generic `mention` reviewer: post a new comment such as `Updated: @<handle>, please re-review.` through `dx_reviewer_comment` after applying `humanizer`.
- For each adapter row: run `dx_reviewer_trigger` again. The new head restarts that reviewer's wait.

Record the cycle with `dx_complete_record_cycle "$SESSION_ID" progress`. It
increments the counter and resets the epoch in the state file. Stop. Next
iteration starts a new wait window.

### Case W — Waiting on CI or a waited reviewer

No commits were pushed, but CI is still `pending` or `GATE_RC` is 1. Something
is still running, so this cycle is not idle:

```bash
dx_complete_record_cycle "$SESSION_ID" waiting
```

It keeps the cycle counter and resets the epoch, so waiting never spends the
idle budget. Reviewer waits are bounded by `dx_complete_reviewer_wait_minutes`
(the gate then reports `timeout`). Pending CI is bounded by
`dx_complete_pending_minutes`, after which `dx_complete_ci_state` reports
`stalled` and the cycle is handled as Case C. Stop. Next iteration starts a new
wait window.

### Case C — No CI/review progress

The cycle was idle: nothing was pushed, nothing is pending, and Case A does
not hold. Stalled CI, a failed CI query and `GATE_RC` 3 (PR head unreadable)
land here too; report them. Record
the cycle:

```bash
dx_complete_record_cycle "$SESSION_ID" idle || IDLE_RC=$?
```

`IDLE_RC` 5 means the idle budget (`dx_complete_max_cycles`) is spent: proceed
to Case D bounded-timeout pause. Otherwise stop. Next iteration starts a new
wait window.

### Case D — Bounded-timeout pause or material escalation

Re-read `CI_FIX_ATTEMPTS=$(dx_complete_ci_fix_attempts "${DEX_SESSION_ID:-$(dx_session_id)}")`.
Stop and escalate to the user immediately if:
- The watcher has completed the current `MAX_CYCLES` idle-cycle budget without
  checks going green or actionable review feedback being resolved
- CI has failed the same check `CI_FIX_ATTEMPTS` times in a row (`/dxwatchpr` should already escalate)
- A reviewer requested a scope change that affects other tickets
- A secrets scan failed
- Architectural disagreement that needs human judgement

For the bounded-timeout pause, print a notice using the current `MAX_CYCLES`
and `WAIT_MINUTES`, then stop without writing a completion receipt:

```
Autonomous PR monitoring paused after <MAX_CYCLES> idle <WAIT_MINUTES>-minute cycles.
Run /dxwatchpr manually for a one-off CI/review check, or /loop 5m /dxwatchpr to resume watching.
Run /dxcomplete manually when the PR is ready and you want Dex to complete the ticket.
The PR was not merged.
```

Then run the exact generation-bound escalation command printed with the current
launch or audit. It pauses and detaches this run, revokes completion
authorization, and creates no completion receipt. Do not touch a pause marker,
write a control file, or discover a generation yourself.

For hard escalations, print the reason with cited `file:line` evidence, run that
same exact escalation command, and stop without writing a completion receipt.

---

## Termination

Cycle ends successfully only when **Case A** is reached: CI is green, every
`wait: yes` reviewer has finished on the head or timed out, and actionable
review feedback is resolved. Completion means the ticket is closed
and the local Dex worktree/branch can be removed; it never means merging the PR.

Cycle pauses with escalation when:
- `CYCLE >= MAX_CYCLES` and checks are not green or actionable feedback remains
- Hard escalation (see Case D)

Only Case A may run the exact generation-bound completion command supplied by
the Stop hook. Timeout and hard escalation paths must use the exact escalation
command instead. The user can run `/dxwatchpr` manually for another one-off pass
or `/dxcomplete` to resume completion.

---

## Completion criteria (must all be true before writing the exact receipt)

- The PR is no longer a draft (`gh pr view --json isDraft -q .isDraft` returns `false`)
- Each configured `request` reviewer was attempted at least once; a
  non-requestable reviewer has a recorded warning instead
- One mention comment has been posted for generic `mention` reviewers (if any),
  and each adapter row was triggered with `dx_reviewer_trigger`
- No PR or issue comment from this phase mentions `@copilot`
- `dx_reviewer_gate` returns 0: every `wait: yes` reviewer is done on the head
  commit, timed out, or unavailable, and the summary reports each one; a
  timeout is reported as not reviewed
- `dx_complete_ci_state` reports green (with `readiness_check`, that check
  passed), no actionable review feedback remains unresolved,
  and the ticket is marked Done if a tracker is configured. A missing review,
  pending request, absent approval, or `REVIEW_REQUIRED` merge decision does not
  block Phase 6. Report merge-review state in the maintainer handoff.
- Material CI and review findings were handled under
  `prompts/issue-hygiene.md`, and the terminal summary contains `Issue/PR work:`.
- No session-owned background process in flight, per `dx ps`, except the PR
  watcher loop, which must itself be session-owned.

Do NOT emit `DEX_TICKET_COMPLETE` until the Stop hook authorizes completion via the audit-iteration threshold. Follow the standard pattern.
