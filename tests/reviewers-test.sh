#!/usr/bin/env bash
# lib/reviewers.sh: the Reviewers table parser, adapter triggers, the Phase 6
# wait gate, CI readiness and cycle accounting, all against a fake `gh`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-reviewers-test.XXXXXX")"

cleanup() {
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
export PATH="$TMP_DIR/bin:$PATH"
export GH_FAKE_DIR="$TMP_DIR/gh"
export GH_FAKE_CALLS="$TMP_DIR/gh-calls.log"
unset GH_REPO GITHUB_REPOSITORY DEX_REVIEWER_WAIT_MINUTES DEX_COMPLETE_PENDING_MINUTES
mkdir -p "$TMP_DIR/bin" "$GH_FAKE_DIR" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$HOME"

# The fake gh answers from fixture files in $GH_FAKE_DIR and logs every call.
# A missing fixture is a failed API call, which is how outages are simulated.
cat > "$TMP_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_FAKE_CALLS"
fixture() {
  [[ -f "$GH_FAKE_DIR/$1" ]] || exit 1
  cat "$GH_FAKE_DIR/$1"
}
case "$1 $2" in
  "repo view") printf '%s\n' "example/repo"; exit 0 ;;
  "pr view") cat "$GH_FAKE_DIR/head"; exit 0 ;;
  "pr edit") exit 0 ;;
  "pr comment")
    shift 2
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body-file" ]]; then
        cat "$2" >> "$GH_FAKE_DIR/comments-posted"
        printf -- '--\n' >> "$GH_FAKE_DIR/comments-posted"
      fi
      shift
    done
    exit 0
    ;;
  "pr checks")
    if [[ ! -f "$GH_FAKE_DIR/checks.json" ]]; then
      printf '%s\n' "no checks reported on the 'feature' branch" >&2
      exit 1
    fi
    cat "$GH_FAKE_DIR/checks.json"
    exit "$(cat "$GH_FAKE_DIR/checks.rc" 2>/dev/null || printf '0')"
    ;;
esac
if [[ "$1" == "api" ]]; then
  path="${2%%\?*}"
  case "$path" in
    */check-runs) fixture check-runs.json ;;
    */pulls/*/reviews) fixture reviews.json ;;
    */pulls/*) fixture pull.json ;;
    */issues/*/comments) fixture issue-comments.json ;;
    */commits/*) fixture commit.json ;;
  esac
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
GH
chmod +x "$TMP_DIR/bin/gh"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

SESSION="repo-reviewers-test"
HEAD_SHA="1111111111111111111111111111111111111111"
NEW_HEAD="2222222222222222222222222222222222222222"
repo="$TMP_DIR/repo"
mkdir -p "$repo/.dex"

reset_gh() {
  rm -rf "$GH_FAKE_DIR"
  mkdir -p "$GH_FAKE_DIR"
  printf '%s\n' "$HEAD_SHA" > "$GH_FAKE_DIR/head"
  : > "$GH_FAKE_CALLS"
  rm -f "$(dx_complete_wait_file "$SESSION")" "$(dx_complete_state_file "$SESSION")"
}

write_reviewers() {
  {
    printf '# Test\n\n## Reviewers\n\nIntro prose.\n\n'
    cat
    printf '\n## Rules\n\n| Handle | Type |\n|---|---|\n| not-a-reviewer | request |\n'
  } > "$repo/.dex/dex.md"
}

# text_has <text> <needle> / text_lacks <text> <needle>: string checks; the
# shared assert_contains reads a file.
text_has() {
  [[ "$1" == *"$2"* ]] && return 0
  printf 'missing expected text: %s\nin:\n%s\n' "$2" "$1" >&2
  exit 1
}
text_lacks() {
  [[ "$1" != *"$2"* ]] && return 0
  printf 'unexpected text: %s\nin:\n%s\n' "$2" "$1" >&2
  exit 1
}

ledger_set() {
  # ledger_set <kind> <key> <head> <started> <triggered> <state>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$(dx_complete_wait_file "$SESSION")"
}

iso_ago() {
  python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[1]))))' "$1"
}

# --- dx_reviewers_rows ----------------------------------------------------------

# A legacy three-column table reads exactly as before.
write_reviewers <<'EOF'
| Handle | Type | Notes |
|--------|------|-------|
| @octocat | request | Authenticated GitHub user |
| Copilot | request | GitHub Copilot review |
| @bot-watcher | mention | Watches mentions |
EOF
rows=$(dx_reviewers_rows "$repo")
assert_eq "$(printf '@octocat\trequest\tno\tgeneric\nCopilot\trequest\tno\tgeneric\n@bot-watcher\tmention\tno\tgeneric')" \
  "$rows" "legacy table defaults to wait=no adapter=generic"

# Columns are found by header name in any order; Notes may sit anywhere.
write_reviewers <<'EOF'
| Handle | Type | Notes | Adapter | Wait |
|:-------|:----:|-------|---------|------|
| @greptileai | mention | AI review | greptile | yes |
| Copilot | request | | | YES |
| @someone | request | | | |
| _none_ | _none_ | placeholder | | |
EOF
rows=$(dx_reviewers_rows "$repo")
assert_eq "$(printf '@greptileai\tmention\tyes\tgreptile\nCopilot\trequest\tyes\tcopilot\n@someone\trequest\tno\tgeneric')" \
  "$rows" "header-driven columns, inference, and _none_"

# A blank adapter is inferred only when the row waits.
write_reviewers <<'EOF'
| Handle | Type | Wait | Adapter | Notes |
|---|---|---|---|---|
| greptile | mention | yes | | |
| greptile | mention | no | | |
EOF
rows=$(dx_reviewers_rows "$repo")
assert_eq "$(printf 'greptile\tmention\tyes\tgreptile\ngreptile\tmention\tno\tgeneric')" \
  "$rows" "adapter inference needs wait: yes"
# `dx config` writes rows through the same default.
assert_eq "copilot" "$(dx_reviewer_default_adapter @GitHub-Copilot yes)" "default adapter: copilot"
assert_eq "greptile" "$(dx_reviewer_default_adapter greptile-apps yes)" "default adapter: greptile"
assert_eq "generic" "$(dx_reviewer_default_adapter greptile-apps no)" "default adapter: no wait"
assert_eq "generic" "$(dx_reviewer_default_adapter octocat yes)" "default adapter: other handle"

# A Copilot row is always a request row, whatever it says: a mention would post
# @copilot in a comment and summon the coding agent.
write_reviewers <<'EOF'
| Handle | Type | Wait | Adapter | Notes |
|---|---|---|---|---|
| @Copilot | mention | no | | |
| copilot-pull-request-reviewer[bot] | mention | | | |
| @helper | mention | no | copilot | |
EOF
rows=$(dx_reviewers_rows "$repo")
assert_eq "$(printf '@Copilot\trequest\tno\tgeneric\ncopilot-pull-request-reviewer[bot]\trequest\tno\tgeneric\n@helper\trequest\tno\tcopilot')" \
  "$rows" "Copilot rows are coerced to request"

# Bad values default with a warning; unknown types are skipped; fenced blocks
# inside the section are not table rows.
write_reviewers <<'EOF'
| Handle | Type | Wait | Adapter |
|---|---|---|---|
| @a | request | maybe | robot |
| @b | approve | yes | generic |

```markdown
| @fenced | request | yes | greptile |
```
EOF
rows=$(dx_reviewers_rows "$repo" 2>"$TMP_DIR/rows.err")
assert_eq "$(printf '@a\trequest\tno\tgeneric')" "$rows" "invalid values default, unknown types skip"
text_has "$(cat "$TMP_DIR/rows.err")" 'wait "maybe" is not yes or no'
text_has "$(cat "$TMP_DIR/rows.err")" 'unknown adapter "robot"'
text_has "$(cat "$TMP_DIR/rows.err")" 'unknown type "approve"'

# Missing file or section is rc 1.
rc=0
dx_reviewers_rows "$TMP_DIR/nowhere" >/dev/null || rc=$?
assert_eq 1 "$rc" "missing dex.md"
printf '# Test\n\n## Rules\n' > "$repo/.dex/dex.md"
rc=0
dx_reviewers_rows "$repo" >/dev/null || rc=$?
assert_eq 1 "$rc" "missing Reviewers section"

assert_eq "$(printf 'greptile-apps[bot]\ngreptile-apps-staging[bot]')" \
  "$(dx_reviewer_adapter_logins greptile)" "greptile logins"
text_has "$(dx_reviewer_adapter_logins copilot)" 'copilot-pull-request-reviewer[bot]'

# --- settings ---------------------------------------------------------------------

assert_eq 20 "$(dx_complete_reviewer_wait_minutes "$SESSION")" "reviewer wait default"
assert_eq 120 "$(dx_complete_pending_minutes "$SESSION")" "pending CI default"
assert_eq 7 "$(DEX_REVIEWER_WAIT_MINUTES=7 dx_complete_reviewer_wait_minutes "$SESSION")" "reviewer wait env"
assert_eq 20 "$(DEX_REVIEWER_WAIT_MINUTES=soon dx_complete_reviewer_wait_minutes "$SESSION")" "reviewer wait rejects junk"
assert_eq 120 "$(DEX_COMPLETE_PENDING_MINUTES=-1 dx_complete_pending_minutes "$SESSION")" "pending rejects junk"
dx_override_gate_supported complete.reviewer-wait-minutes || assert_at $LINENO
dx_override_gate_supported complete.pending-minutes || assert_at $LINENO
dx_override_gate_value_valid complete.pending-minutes 45 || assert_at $LINENO
if dx_override_gate_value_valid complete.reviewer-wait-minutes ten; then assert_at $LINENO; fi

# --- dx_reviewer_comment ----------------------------------------------------------

reset_gh
for body in "@copilot please review" "Thanks @Copilot!" "cc @github-copilot" "(@COPILOT)"; do
  rc=0
  dx_reviewer_comment "$SESSION" 7 "$body" 2>/dev/null || rc=$?
  assert_eq 4 "$rc" "refuses: $body"
done
[[ ! -s "$GH_FAKE_CALLS" ]] || assert_at $LINENO
dx_reviewer_comment "$SESSION" 7 "@greptileai review"
text_has "$(cat "$GH_FAKE_DIR/comments-posted")" "@greptileai review"
# An email-like token is not a mention.
dx_reviewer_comment "$SESSION" 7 "mail me at someone@copilot.example"
rc=0
dx_reviewer_comment "$SESSION" abc "hi" || rc=$?
assert_eq 2 "$rc" "PR number validated"

# --- legacy config: no gh calls, no ledger ------------------------------------------

write_reviewers <<'EOF'
| Handle | Type | Notes |
|--------|------|-------|
| @octocat | request | user |
| Copilot | request | Copilot |
EOF
reset_gh
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq "" "$out" "gate prints nothing without waited rows"
[[ ! -s "$GH_FAKE_CALLS" ]] || assert_at $LINENO
[[ ! -e "$(dx_complete_wait_file "$SESSION")" ]] || assert_at $LINENO

# A generic row that says wait: yes keeps today's behaviour too.
write_reviewers <<'EOF'
| Handle | Type | Wait | Adapter |
|---|---|---|---|
| @octocat | request | yes | generic |
EOF
reset_gh
dx_reviewer_gate "$SESSION" "$repo" 7 >/dev/null
[[ ! -s "$GH_FAKE_CALLS" ]] || assert_at $LINENO

# --- Copilot adapter ------------------------------------------------------------------

write_reviewers <<'EOF'
| Handle | Type | Wait | Adapter | Notes |
|---|---|---|---|---|
| Copilot | request | yes | copilot | |
EOF

copilot_pull() {
  # copilot_pull <requested:yes|no>
  if [[ "$1" == "yes" ]]; then
    printf '%s' '{"user":{"login":"author"},"requested_reviewers":[{"login":"Copilot"}],"requested_teams":[]}' \
      > "$GH_FAKE_DIR/pull.json"
  else
    printf '%s' '{"user":{"login":"author"},"requested_reviewers":[],"requested_teams":[]}' \
      > "$GH_FAKE_DIR/pull.json"
  fi
}

copilot_review() {
  # copilot_review <commit> <submitted_at>
  printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"%s","submitted_at":"%s","state":"COMMENTED"}]' \
    "$1" "$2" > "$GH_FAKE_DIR/reviews.json"
}

# Trigger: exactly a reviewer request, never a comment.
reset_gh
copilot_pull yes
dx_reviewer_trigger "$SESSION" "$repo" 7 Copilot copilot >/dev/null
text_has "$(cat "$GH_FAKE_CALLS")" "pr edit 7 --add-reviewer @copilot"
text_lacks "$(cat "$GH_FAKE_CALLS")" "pr comment"
[[ ! -e "$GH_FAKE_DIR/comments-posted" ]] || assert_at $LINENO
text_has "$(cat "$(dx_complete_wait_file "$SESSION")")" "$(printf 'reviewer\tcopilot\t%s' "$HEAD_SHA")"

# Still requested: in progress, rc 1.
printf '[]' > "$GH_FAKE_DIR/reviews.json"
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 1 "$rc" "copilot still requested waits"
assert_eq in-progress "$(printf '%s\n' "$out" | cut -f3)" "copilot in progress"

# Review on an older commit does not count.
copilot_pull no
copilot_review "$NEW_HEAD" "$(iso_ago 0)"
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 1 "$rc" "review of another commit is not done"
assert_eq not-started "$(printf '%s\n' "$out" | cut -f3)" "copilot not started"

# Review on the head but submitted before the recorded trigger does not count.
reset_gh
copilot_pull no
ledger_set reviewer copilot "$HEAD_SHA" "$(date +%s)" "$(date +%s)" waiting
copilot_review "$HEAD_SHA" "$(iso_ago 3600)"
rc=0
dx_reviewer_gate "$SESSION" "$repo" 7 >/dev/null || rc=$?
assert_eq 1 "$rc" "review older than the trigger is not done"

# Review on the head after the trigger: done, rc 0.
copilot_review "$HEAD_SHA" "$(iso_ago -60)"
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq "done" "$(printf '%s\n' "$out" | cut -f3)" "copilot done on head"
assert_eq Copilot "$(printf '%s\n' "$out" | cut -f1)" "gate reports the configured handle"
# Done is recorded and sticks for this head.
rm -f "$GH_FAKE_DIR/reviews.json"
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq "done" "$(printf '%s\n' "$out" | cut -f3)" "done sticks for the head"

# A new head resets the clock and the result.
printf '%s\n' "$NEW_HEAD" > "$GH_FAKE_DIR/head"
copilot_pull yes
printf '[]' > "$GH_FAKE_DIR/reviews.json"
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 1 "$rc" "new head waits again"
text_lacks "$(cat "$(dx_complete_wait_file "$SESSION")")" "$HEAD_SHA"

# Timeout: reported, rc 0, recorded, never done.
reset_gh
copilot_pull yes
printf '[]' > "$GH_FAKE_DIR/reviews.json"
ledger_set reviewer copilot "$HEAD_SHA" "$(( $(date +%s) - 3600 ))" "$(( $(date +%s) - 3600 ))" waiting
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq timeout "$(printf '%s\n' "$out" | cut -f3)" "copilot times out"
text_has "$out" "no review after 20m"
text_has "$(cat "$(dx_complete_wait_file "$SESSION")")" "$(printf '\ttimeout')"
# Even a late review does not turn a recorded timeout into a clean review.
copilot_pull no
copilot_review "$HEAD_SHA" "$(iso_ago -60)"
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq timeout "$(printf '%s\n' "$out" | cut -f3)" "timeout is final for the head"

# A zero wait times out at once.
reset_gh
copilot_pull yes
printf '[]' > "$GH_FAKE_DIR/reviews.json"
out=$(DEX_REVIEWER_WAIT_MINUTES=0 dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq timeout "$(printf '%s\n' "$out" | cut -f3)" "wait 0 times out immediately"

# GitHub failures are unknown and keep waiting until the timeout.
reset_gh
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 1 "$rc" "unknown keeps waiting"
assert_eq unknown "$(printf '%s\n' "$out" | cut -f3)" "query failure is unknown"

# An unreadable PR head is rc 3, not waiting: nothing can time out without it,
# so Phase 6 counts that cycle as idle instead of waiting on it forever.
reset_gh
rm -f "$GH_FAKE_DIR/head"
rc=0
out=$(DEX_REVIEWER_WAIT_MINUTES=0 dx_reviewer_gate "$SESSION" "$repo" 7 2>/dev/null) || rc=$?
assert_eq 3 "$rc" "unreadable head is a query error"
text_has "$out" "head unavailable"

# A Copilot request GitHub does not keep is unavailable and does not hold Phase 6.
reset_gh
copilot_pull no
dx_reviewer_trigger "$SESSION" "$repo" 7 Copilot copilot >/dev/null
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq unavailable "$(printf '%s\n' "$out" | cut -f3)" "copilot not requestable"

# --- Greptile adapter -----------------------------------------------------------------

write_reviewers <<'EOF'
| Handle | Type | Wait | Adapter | Notes |
|---|---|---|---|---|
| @greptileai | mention | yes | greptile | |
EOF

greptile_run() {
  # greptile_run <status> <conclusion>
  printf '{"check_runs":[{"id":2,"name":"Greptile Review","status":"%s","conclusion":%s,"started_at":"2026-10-01T10:00:00Z"},{"id":1,"name":"build","status":"completed","conclusion":"success","started_at":"2026-10-01T09:00:00Z"}]}' \
    "$1" "$2" > "$GH_FAKE_DIR/check-runs.json"
}

no_greptile_run() {
  printf '%s' '{"check_runs":[{"id":1,"name":"build","status":"completed","conclusion":"success"}]}' \
    > "$GH_FAKE_DIR/check-runs.json"
}

# Trigger posts the review comment when Greptile is idle on the head.
reset_gh
no_greptile_run
dx_reviewer_trigger "$SESSION" "$repo" 7 @greptileai greptile
assert_eq "$(printf '@greptileai review\n--')" "$(cat "$GH_FAKE_DIR/comments-posted")" "greptile trigger comment"

# No duplicate trigger while its check run is already going.
reset_gh
greptile_run in_progress null
dx_reviewer_trigger "$SESSION" "$repo" 7 @greptileai greptile
[[ ! -e "$GH_FAKE_DIR/comments-posted" ]] || assert_at $LINENO

# A targeted request always posts, with the focus text.
dx_reviewer_trigger "$SESSION" "$repo" 7 @greptileai greptile "the retry loop and how it interacts with the lock"
text_has "$(cat "$GH_FAKE_DIR/comments-posted")" \
  "@greptileai review. Please focus on the retry loop and how it interacts with the lock."

# Check run in progress, then completed.
reset_gh
greptile_run in_progress null
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 1 "$rc" "greptile running waits"
assert_eq in-progress "$(printf '%s\n' "$out" | cut -f3)" "greptile in progress"
greptile_run completed '"success"'
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq "done" "$(printf '%s\n' "$out" | cut -f3)" "greptile check run completed"
assert_eq success "$(printf '%s\n' "$out" | cut -f5)" "conclusion in detail"

# A check run that finished without reviewing is a failure, not a review.
reset_gh
greptile_run completed '"skipped"'
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 1 "$rc" "skipped greptile run keeps waiting"
assert_eq failed "$(printf '%s\n' "$out" | cut -f3)" "skipped greptile run is failed"

# No check run: a scored summary updated after the head commit counts.
reset_gh
no_greptile_run
printf '{"commit":{"committer":{"date":"%s"}}}' "$(iso_ago 600)" > "$GH_FAKE_DIR/commit.json"
printf '[{"user":{"login":"greptile-apps[bot]"},"body":"Confidence Score: 4/5","updated_at":"%s"}]' \
  "$(iso_ago 60)" > "$GH_FAKE_DIR/issue-comments.json"
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq "done" "$(printf '%s\n' "$out" | cut -f3)" "greptile summary fallback"
assert_eq 4/5 "$(printf '%s\n' "$out" | cut -f5)" "confidence in detail"

# A summary older than the head commit is stale.
reset_gh
no_greptile_run
printf '{"commit":{"committer":{"date":"%s"}}}' "$(iso_ago 60)" > "$GH_FAKE_DIR/commit.json"
printf '[{"user":{"login":"greptile-apps[bot]"},"body":"Confidence Score: 5/5","updated_at":"%s"}]' \
  "$(iso_ago 600)" > "$GH_FAKE_DIR/issue-comments.json"
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 1 "$rc" "stale summary waits"
assert_eq not-started "$(printf '%s\n' "$out" | cut -f3)" "stale summary, no trigger"
# Comments by anyone else never count.
printf '[{"user":{"login":"someone"},"body":"Confidence Score: 5/5","updated_at":"%s"}]' \
  "$(iso_ago 0)" > "$GH_FAKE_DIR/issue-comments.json"
rc=0
dx_reviewer_gate "$SESSION" "$repo" 7 >/dev/null || rc=$?
assert_eq 1 "$rc" "non-Greptile comment ignored"

# Greptile timeout.
reset_gh
greptile_run queued null
ledger_set reviewer greptileai "$HEAD_SHA" "$(( $(date +%s) - 1500 ))" "$(( $(date +%s) - 1500 ))" waiting
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq timeout "$(printf '%s\n' "$out" | cut -f3)" "greptile times out"
# Asking again on the same head reaches Greptile but does not reopen the wait.
no_greptile_run
dx_reviewer_trigger "$SESSION" "$repo" 7 @greptileai greptile "the lock"
text_has "$(cat "$(dx_complete_wait_file "$SESSION")")" "$(printf '\ttimeout')"
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 0 "$rc" "re-trigger keeps the timeout"
assert_eq timeout "$(printf '%s\n' "$out" | cut -f3)" "timeout sticks through a re-trigger"

# A re-trigger before the timeout does not restart the head's clock either.
reset_gh
greptile_run queued null
ledger_set reviewer greptileai "$HEAD_SHA" "$(( $(date +%s) - 1500 ))" "$(( $(date +%s) - 1500 ))" waiting
no_greptile_run
dx_reviewer_trigger "$SESSION" "$repo" 7 @greptileai greptile "the lock"
greptile_run queued null
out=$(dx_reviewer_gate "$SESSION" "$repo" 7)
assert_eq timeout "$(printf '%s\n' "$out" | cut -f3)" "the clock runs from the first trigger"

# Both adapters: the gate waits for the slower one.
write_reviewers <<'EOF'
| Handle | Type | Wait | Adapter | Notes |
|---|---|---|---|---|
| @greptileai | mention | yes | greptile | |
| Copilot | request | yes | copilot | |
EOF
reset_gh
greptile_run completed '"success"'
copilot_pull yes
printf '[]' > "$GH_FAKE_DIR/reviews.json"
rc=0
out=$(dx_reviewer_gate "$SESSION" "$repo" 7) || rc=$?
assert_eq 1 "$rc" "gate waits for every waited reviewer"
assert_eq 2 "$(printf '%s\n' "$out" | grep -c .)" "one line per waited reviewer"
copilot_pull no
copilot_review "$HEAD_SHA" "$(iso_ago 0)"
dx_reviewer_gate "$SESSION" "$repo" 7 >/dev/null

# --- dx_complete_ci_state ---------------------------------------------------------------

write_reviewers <<'EOF'
| Handle | Type | Notes |
|---|---|---|
| @octocat | request | |
EOF

ci() {
  local ci_rc=0
  ci_out=$(dx_complete_ci_state "$SESSION" "$repo" 7) || ci_rc=$?
  printf '%s' "$ci_rc"
}

reset_gh
printf '%s' '[{"name":"test","bucket":"pass","link":"l1"},{"name":"lint","bucket":"skipping","link":"l2"}]' \
  > "$GH_FAKE_DIR/checks.json"
assert_eq 0 "$(ci)" "all pass is green"
ci >/dev/null; assert_eq green "$ci_out" "green output"

printf '%s' '[{"name":"test","bucket":"pass"},{"name":"e2e","bucket":"pending","link":"l3"}]' \
  > "$GH_FAKE_DIR/checks.json"
printf '8' > "$GH_FAKE_DIR/checks.rc"
assert_eq 1 "$(ci)" "pending"
ci >/dev/null || true
assert_eq "$(printf 'pending\ne2e\tpending\tl3')" "$ci_out" "pending lists the check"
text_has "$(cat "$(dx_complete_wait_file "$SESSION")")" "$(printf 'ci\t-\t%s' "$HEAD_SHA")"

printf '%s' '[{"name":"test","bucket":"fail","link":"l4"},{"name":"e2e","bucket":"pending"}]' \
  > "$GH_FAKE_DIR/checks.json"
printf '1' > "$GH_FAKE_DIR/checks.rc"
assert_eq 3 "$(ci)" "any failure fails"

# No checks at all reads as green, as today.
reset_gh
assert_eq 0 "$(ci)" "no checks reported"

# A gh failure is an error, not green.
reset_gh
printf 'not json' > "$GH_FAKE_DIR/checks.json"
assert_eq 2 "$(ci)" "unparseable checks are an error"

# Pending too long on one head is stalled.
reset_gh
printf '%s' '[{"name":"e2e","bucket":"pending"}]' > "$GH_FAKE_DIR/checks.json"
ledger_set ci - "$HEAD_SHA" "$(( $(date +%s) - 7300 ))" - pending
assert_eq 4 "$(ci)" "stalled after the pending cap"
ci >/dev/null || true
assert_eq stalled "$(printf '%s\n' "$ci_out" | head -n 1)" "stalled output"
# ...but a new head starts the pending clock again.
printf '%s\n' "$NEW_HEAD" > "$GH_FAKE_DIR/head"
assert_eq 1 "$(ci)" "new head resets the pending clock"

# readiness_check: only the named check counts, and missing is pending.
cat > "$repo/.dex/dex.md" <<'EOF'
# Test

## Resources

```yaml
readiness_check: gate-all-checks
```

## Reviewers

| Handle | Type | Wait | Adapter |
|---|---|---|---|
| @greptileai | mention | yes | greptile |
EOF
reset_gh
printf '%s' '[{"name":"test","bucket":"pass"}]' > "$GH_FAKE_DIR/checks.json"
assert_eq 1 "$(ci)" "readiness check absent is pending"
ci >/dev/null || true
text_has "$ci_out" "$(printf 'gate-all-checks\tmissing')"
printf '%s' '[{"name":"test","bucket":"fail"},{"name":"gate-all-checks","bucket":"pending"}]' \
  > "$GH_FAKE_DIR/checks.json"
assert_eq 1 "$(ci)" "readiness pending is pending even when another check failed"
printf '%s' '[{"name":"test","bucket":"pending"},{"name":"gate-all-checks","bucket":"pass"}]' \
  > "$GH_FAKE_DIR/checks.json"
assert_eq 0 "$(ci)" "readiness pass is green"
printf '%s' '[{"name":"gate-all-checks","bucket":"fail"}]' > "$GH_FAKE_DIR/checks.json"
assert_eq 3 "$(ci)" "readiness fail fails"

# Greptile's own check run is the gate's business, not CI's.
sed -i.bak '/readiness_check/d' "$repo/.dex/dex.md"
printf '%s' '[{"name":"test","bucket":"pass"},{"name":"Greptile Review","bucket":"pending"}]' \
  > "$GH_FAKE_DIR/checks.json"
assert_eq 0 "$(ci)" "greptile check excluded with a greptile row"

# --- dx_complete_record_cycle -------------------------------------------------------------

reset_gh
state_file=$(dx_complete_state_file "$SESSION")
for _ in 1 2 3 4 5; do
  dx_complete_record_cycle "$SESSION" waiting >/dev/null
done
assert_eq 0 "$(cut -d: -f1 "$state_file")" "waiting never spends the idle budget"
dx_complete_record_cycle "$SESSION" progress >/dev/null
assert_eq 1 "$(cut -d: -f1 "$state_file")" "progress advances"
dx_complete_record_cycle "$SESSION" idle >/dev/null
rc=0
dx_complete_record_cycle "$SESSION" idle >/dev/null || rc=$?
assert_eq 5 "$rc" "idle reaching max cycles"
[[ "$(cat "$state_file")" =~ ^3:[0-9]+$ ]] || assert_at $LINENO
rc=0
dx_complete_record_cycle "$SESSION" bored >/dev/null || rc=$?
assert_eq 2 "$rc" "unknown outcome rejected"

printf 'reviewers tests passed\n'
