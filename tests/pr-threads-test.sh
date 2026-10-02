#!/usr/bin/env bash
# lib/pr-threads.sh: the review-thread policy reader, the per-outcome reply,
# reaction and resolve, the Phase 6 open-thread listing, and the backup-then-
# delete of a stray pending review, all against a fake `gh`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-pr-threads-test.XXXXXX")"
# The physical path: dx_run_artifact_file resolves symlinks such as /tmp on macOS.
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
export PATH="$TMP_DIR/bin:$PATH"
export GH_FAKE_DIR="$TMP_DIR/gh"
export GH_FAKE_CALLS="$TMP_DIR/gh-calls.log"
unset GH_REPO GITHUB_REPOSITORY DEX_RUN_ID
mkdir -p "$TMP_DIR/bin" "$GH_FAKE_DIR" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$HOME"

# The fake gh logs one compact line per call and answers from fixture files in
# $GH_FAKE_DIR. A missing fixture is a failed call; a `<name>.fail` file makes a
# write fail. Reply bodies are kept in reply-<comment>.txt. A DELETE of a
# pending review logs whether its backup already exists, which is the ordering
# the cleanup promises.
cat > "$TMP_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
[[ "${1:-}" == "api" ]] || { printf 'unexpected gh call: %s\n' "$*" >&2; exit 1; }
shift
method=GET path="" query="" body_file="" content="" thread=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method|-X) method="$2"; shift 2 ;;
    --paginate) shift ;;
    --jq) shift 2 ;;
    -f|-F)
      case "$2" in
        query=*) query="${2#query=}" ;;
        body=@*) body_file="${2#body=@}" ;;
        content=*) content="${2#content=}" ;;
        threadId=*) thread="${2#threadId=}" ;;
      esac
      shift 2
      ;;
    *) path="${1%%\?*}"; shift ;;
  esac
done
log() { printf '%s\n' "$*" >> "$GH_FAKE_CALLS"; }
fixture() {
  [[ -f "$GH_FAKE_DIR/$1" ]] || exit 1
  cat "$GH_FAKE_DIR/$1"
}
if [[ "$path" == "graphql" ]]; then
  case "$query" in
    *resolveReviewThread*)
      log "graphql resolve $thread"
      [[ ! -f "$GH_FAKE_DIR/resolve.fail" ]] || exit 1
      printf '{}\n'
      ;;
    *reviewThreads*) log "graphql threads"; fixture threads.json ;;
    *PENDING*) log "graphql pending"; fixture pending.json ;;
    *) log "graphql unknown"; exit 1 ;;
  esac
  exit 0
fi
case "$method $path" in
  "GET repos/example/repo/pulls/comments/"*)
    log "GET $path"
    fixture "comment-${path##*/}"
    ;;
  "POST repos/example/repo/pulls/7/comments/"*"/replies")
    log "POST $path"
    [[ ! -f "$GH_FAKE_DIR/reply.fail" ]] || exit 1
    id="${path%/replies}"; id="${id##*/}"
    cat "$body_file" > "$GH_FAKE_DIR/reply-$id.txt"
    printf '{}\n'
    ;;
  "POST repos/example/repo/pulls/comments/"*"/reactions")
    log "POST $path content=$content"
    [[ ! -f "$GH_FAKE_DIR/reaction.fail" ]] || exit 1
    printf '{}\n'
    ;;
  "GET repos/example/repo/pulls/7/reviews/"*"/comments")
    log "GET $path"
    id="${path%/comments}"; id="${id##*/}"
    fixture "review-comments-$id.json"
    ;;
  "DELETE repos/example/repo/pulls/7/reviews/"*)
    id="${path##*/}"
    backup=missing
    for f in "$DX_RUN_ROOT"/*/artifacts/pending-review-"$id".json; do
      [[ -f "$f" ]] && backup=present
    done
    log "DELETE $path backup=$backup"
    [[ ! -f "$GH_FAKE_DIR/delete.fail" ]] || exit 1
    printf '{}\n'
    ;;
  *) log "unexpected $method $path"; exit 1 ;;
esac
GH
chmod +x "$TMP_DIR/bin/gh"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

SESSION="repo-pr-threads-test"
REPO="example/repo"
repo="$TMP_DIR/repo"
mkdir -p "$repo/.dex"

reset_gh() {
  rm -rf "$GH_FAKE_DIR"
  mkdir -p "$GH_FAKE_DIR"
  : > "$GH_FAKE_CALLS"
}

calls() { cat "$GH_FAKE_CALLS"; }

# write_dex <thread_policy-or-empty> [reviewers-table-rows]
write_dex() {
  {
    printf '# Test\n\n'
    if [[ -n "$1" ]]; then
      printf '## Resources\n\n```yaml\nthread_policy: %s\n```\n\n' "$1"
    fi
    printf '## Reviewers\n\n| Handle | Type | Wait | Adapter |\n|---|---|---|---|\n'
    [[ -z "${2:-}" ]] || printf '%s\n' "$2"
  } > "$repo/.dex/dex.md"
}

# comment_fixture <id> <login> <type>: what `--jq '[.node_id, .user.login, .user.type] | @tsv'` prints.
comment_fixture() {
  printf 'C_%s\t%s\t%s\n' "$1" "$2" "$3" > "$GH_FAKE_DIR/comment-$1"
}

# thread_fixture <comment_id> <resolved> <can_resolve> <viewer_replied>
thread_fixture() {
  python3 - "$@" > "$GH_FAKE_DIR/threads.json" <<'PY'
import json
import sys

cid, resolved, can, replied = sys.argv[1:5]
comments = [{"id": "C_" + cid, "databaseId": int(cid), "url": "u", "body": "b",
             "viewerDidAuthor": False, "author": {"login": "someone"}}]
if replied == "1":
    comments.append({"id": "C_9" + cid, "databaseId": 9, "url": "u", "body": "earlier",
                     "viewerDidAuthor": True, "author": {"login": "me"}})
other = {"id": "T_other", "isResolved": False, "viewerCanResolve": True,
         "comments": {"nodes": [{"id": "C_other", "databaseId": 1, "url": "u", "body": "x",
                                 "viewerDidAuthor": False, "author": {"login": "x"}}]}}
mine = {"id": "T_" + cid, "isResolved": resolved == "1", "viewerCanResolve": can == "1",
        "comments": {"nodes": comments}}
# Two pages, the thread on the second, so the lookup reads every page.
print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {
    "nodes": [other], "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}}}}}))
print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {
    "nodes": [mine], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}}}))
PY
}

body_file="$TMP_DIR/body.md"
printf 'Keeping current approach: the helper already validates this.\n' > "$body_file"
MARKER='<!-- dex:thread-disagreement -->'

# respond <comment_id> <outcome>: run the helper; sets OUT and RC.
respond() {
  RC=0
  OUT=$(dx_pr_thread_respond "$SESSION" "$repo" "$REPO" 7 "$1" "$2" "$body_file" 2>"$TMP_DIR/err") || RC=$?
}

# --- dx_pr_thread_policy -----------------------------------------------------------

rm -f "$repo/.dex/dex.md"
assert_eq keep-disagreements-open "$(dx_pr_thread_policy "$repo")" "no dex.md"
write_dex ""
assert_eq keep-disagreements-open "$(dx_pr_thread_policy "$repo")" "no Resources section"
write_dex resolve-all
assert_eq resolve-all "$(dx_pr_thread_policy "$repo")" "resolve-all"
write_dex keep-disagreements-open
assert_eq keep-disagreements-open "$(dx_pr_thread_policy "$repo")" "explicit default"
write_dex "Resolve-All  # legacy"
assert_eq resolve-all "$(dx_pr_thread_policy "$repo")" "case and trailing comment"
write_dex bogus
policy=$(dx_pr_thread_policy "$repo" 2>"$TMP_DIR/err")
assert_eq keep-disagreements-open "$policy" "unknown value"
assert_contains 'thread_policy "bogus"' "$TMP_DIR/err"
write_dex "[resolve-all, keep-disagreements-open]"
policy=$(dx_pr_thread_policy "$repo" 2>"$TMP_DIR/err")
assert_eq keep-disagreements-open "$policy" "list value"
assert_contains 'must be one value' "$TMP_DIR/err"
printf '# T\n\n## Resources\n\n```yaml\nthread_policy:\n  nested: resolve-all\n```\n' > "$repo/.dex/dex.md"
assert_eq keep-disagreements-open "$(dx_pr_thread_policy "$repo" 2>/dev/null)" "malformed block"
assert_rejected "policy needs a repo" dx_pr_thread_policy

# --- dx_pr_thread_respond: keep-disagreements-open ------------------------------------

write_dex ""

# fixed, bot author: reply, +1, resolve.
reset_gh
comment_fixture 101 'copilot-pull-request-reviewer[bot]' Bot
thread_fixture 101 0 1 0
respond 101 fixed
assert_eq 0 "$RC" "keep fixed rc"
assert_eq $'101\treply=posted\treaction=+1\tthread=resolved' "$OUT" "keep fixed output"
assert_eq "GET repos/example/repo/pulls/comments/101
graphql threads
POST repos/example/repo/pulls/7/comments/101/replies
POST repos/example/repo/pulls/comments/101/reactions content=+1
graphql resolve T_101" "$(calls)" "keep fixed calls"
cmp -s "$body_file" "$GH_FAKE_DIR/reply-101.txt" || assert_at $LINENO

# answered, human author: reply, no reaction, resolve.
reset_gh
comment_fixture 102 octocat User
thread_fixture 102 0 1 0
respond 102 answered
assert_eq $'102\treply=posted\treaction=none\tthread=resolved' "$OUT" "keep answered human"
text=$(calls)
[[ "$text" != *reactions* ]] || assert_at $LINENO
[[ "$text" == *"graphql resolve T_102"* ]] || assert_at $LINENO

# answered, bot author: +1.
reset_gh
comment_fixture 103 'greptile-apps[bot]' Bot
thread_fixture 103 0 1 0
respond 103 answered
assert_eq $'103\treply=posted\treaction=+1\tthread=resolved' "$OUT" "keep answered bot"

# disagree on Greptile, Dex's first reply: handle prefix from the row, marker,
# -1, left open.
reset_gh
write_dex "" "| @greptile-team | mention | yes | greptile |"
comment_fixture 104 'greptile-apps[bot]' Bot
thread_fixture 104 0 1 0
respond 104 disagree
assert_eq 0 "$RC" "keep disagree rc"
assert_eq $'104\treply=posted\treaction=-1\tthread=open' "$OUT" "keep disagree greptile"
reply=$(cat "$GH_FAKE_DIR/reply-104.txt")
[[ "$reply" == "@greptile-team Keeping current approach:"* ]] || assert_at $LINENO
[[ "$reply" == *"$MARKER" ]] || assert_at $LINENO
text=$(calls)
[[ "$text" == *"reactions content=-1"* ]] || assert_at $LINENO
[[ "$text" != *"graphql resolve"* ]] || assert_at $LINENO

# disagree on Greptile with no Reviewers row: the canonical handle.
reset_gh
write_dex ""
comment_fixture 105 'greptile-apps[bot]' Bot
thread_fixture 105 0 1 0
respond 105 disagree
[[ "$(cat "$GH_FAKE_DIR/reply-105.txt")" == "@greptileai Keeping"* ]] || assert_at $LINENO

# disagree on Greptile when Dex already replied in the thread: no prefix.
reset_gh
comment_fixture 106 'greptile-apps[bot]' Bot
thread_fixture 106 0 1 1
respond 106 disagree
reply=$(cat "$GH_FAKE_DIR/reply-106.txt")
[[ "$reply" == "Keeping current approach:"* ]] || assert_at $LINENO
[[ "$reply" == *"$MARKER" ]] || assert_at $LINENO

# disagree when the body already starts with the handle: no second prefix.
reset_gh
comment_fixture 107 'greptile-apps[bot]' Bot
thread_fixture 107 0 1 0
printf '@greptileai the helper already validates this.\n' > "$TMP_DIR/handle-body.md"
RC=0
OUT=$(dx_pr_thread_respond "$SESSION" "$repo" "$REPO" 7 107 disagree "$TMP_DIR/handle-body.md") || RC=$?
[[ "$(cat "$GH_FAKE_DIR/reply-107.txt")" == "@greptileai the helper"* ]] || assert_at $LINENO

# disagree, human author: marker, no reaction, left open.
reset_gh
comment_fixture 108 octocat User
thread_fixture 108 0 1 0
respond 108 disagree
assert_eq $'108\treply=posted\treaction=none\tthread=open' "$OUT" "keep disagree human"
reply=$(cat "$GH_FAKE_DIR/reply-108.txt")
[[ "$reply" == "Keeping current approach:"* && "$reply" == *"$MARKER" ]] || assert_at $LINENO

# followup, bot author: reply only.
reset_gh
comment_fixture 109 'copilot-pull-request-reviewer[bot]' Bot
thread_fixture 109 0 1 0
respond 109 followup
assert_eq $'109\treply=posted\treaction=none\tthread=open' "$OUT" "keep followup"
assert_eq "GET repos/example/repo/pulls/comments/109
graphql threads
POST repos/example/repo/pulls/7/comments/109/replies" "$(calls)" "keep followup calls"

# --- dx_pr_thread_respond: resolve-all reproduces the old behaviour -------------------

write_dex resolve-all "| @greptileai | mention | yes | greptile |"
for outcome in fixed disagree answered; do
  reset_gh
  comment_fixture 201 'greptile-apps[bot]' Bot
  thread_fixture 201 0 1 0
  respond 201 "$outcome"
  assert_eq 0 "$RC" "resolve-all $outcome rc"
  assert_eq $'201\treply=posted\treaction=none\tthread=resolved' "$OUT" "resolve-all $outcome"
  assert_eq "GET repos/example/repo/pulls/comments/201
graphql threads
POST repos/example/repo/pulls/7/comments/201/replies
graphql resolve T_201" "$(calls)" "resolve-all $outcome calls"
  cmp -s "$body_file" "$GH_FAKE_DIR/reply-201.txt" || assert_at $LINENO
done
reset_gh
comment_fixture 202 'greptile-apps[bot]' Bot
thread_fixture 202 0 1 0
respond 202 followup
assert_eq $'202\treply=posted\treaction=none\tthread=open' "$OUT" "resolve-all followup"
[[ "$(calls)" != *"graphql resolve"* ]] || assert_at $LINENO

# --- dx_pr_thread_respond: failures ------------------------------------------------

write_dex ""

# The comment cannot be read: rc 1, nothing posted.
reset_gh
thread_fixture 301 0 1 0
respond 301 fixed
assert_eq 1 "$RC" "missing comment rc"
[[ "$(calls)" != *POST* ]] || assert_at $LINENO

# The reply fails: rc 1, no reaction, no resolve.
reset_gh
comment_fixture 302 'greptile-apps[bot]' Bot
thread_fixture 302 0 1 0
: > "$GH_FAKE_DIR/reply.fail"
respond 302 fixed
assert_eq 1 "$RC" "reply failure rc"
text=$(calls)
[[ "$text" != *reactions* && "$text" != *"graphql resolve"* ]] || assert_at $LINENO

# The reaction fails: rc 3, the resolve still runs.
reset_gh
comment_fixture 303 'greptile-apps[bot]' Bot
thread_fixture 303 0 1 0
: > "$GH_FAKE_DIR/reaction.fail"
respond 303 fixed
assert_eq 3 "$RC" "reaction failure rc"
assert_eq $'303\treply=posted\treaction=failed\tthread=resolved' "$OUT" "reaction failure output"

# The thread lookup fails: the reply is posted, rc 3, nothing to resolve.
reset_gh
comment_fixture 304 octocat User
respond 304 fixed
assert_eq 3 "$RC" "thread lookup failure rc"
assert_eq $'304\treply=posted\treaction=none\tthread=failed' "$OUT" "thread lookup failure output"
[[ -f "$GH_FAKE_DIR/reply-304.txt" ]] || assert_at $LINENO
# ...and a disagreement whose thread cannot be read gets no Greptile prefix.
reset_gh
comment_fixture 305 'greptile-apps[bot]' Bot
respond 305 disagree
assert_eq 3 "$RC" "disagree lookup failure rc"
assert_eq $'305\treply=posted\treaction=-1\tthread=open' "$OUT" "disagree lookup failure output"
[[ "$(cat "$GH_FAKE_DIR/reply-305.txt")" == "Keeping current approach:"* ]] || assert_at $LINENO

# The resolve fails: rc 3.
reset_gh
comment_fixture 306 octocat User
thread_fixture 306 0 1 0
: > "$GH_FAKE_DIR/resolve.fail"
respond 306 answered
assert_eq 3 "$RC" "resolve failure rc"
assert_eq $'306\treply=posted\treaction=none\tthread=failed' "$OUT" "resolve failure output"

# An already resolved thread gets no mutation.
reset_gh
comment_fixture 307 octocat User
thread_fixture 307 1 1 0
respond 307 fixed
assert_eq 0 "$RC" "already resolved rc"
assert_eq $'307\treply=posted\treaction=none\tthread=resolved' "$OUT" "already resolved output"
[[ "$(calls)" != *"graphql resolve"* ]] || assert_at $LINENO

# A token that cannot resolve the thread: rc 3, no mutation.
reset_gh
comment_fixture 308 octocat User
thread_fixture 308 0 0 0
respond 308 fixed
assert_eq 3 "$RC" "cannot resolve rc"
assert_eq $'308\treply=posted\treaction=none\tthread=failed' "$OUT" "cannot resolve output"
[[ "$(calls)" != *"graphql resolve"* ]] || assert_at $LINENO

# @copilot in the body: rc 4 before any gh call.
reset_gh
printf 'Thanks @copilot, kept as is.\n' > "$TMP_DIR/copilot-body.md"
RC=0
dx_pr_thread_respond "$SESSION" "$repo" "$REPO" 7 309 fixed "$TMP_DIR/copilot-body.md" \
  >/dev/null 2>&1 || RC=$?
assert_eq 4 "$RC" "@copilot rc"
[[ ! -s "$GH_FAKE_CALLS" ]] || assert_at $LINENO

# Usage errors: rc 2 before any gh call.
reset_gh
for bad in "7 310 escalated $body_file" "x 310 fixed $body_file" "7 abc fixed $body_file" \
  "7 310 fixed $TMP_DIR/missing.md"; do
  RC=0
  # shellcheck disable=SC2086 # the cases are space-separated argument lists.
  dx_pr_thread_respond "$SESSION" "$repo" "$REPO" $bad >/dev/null 2>&1 || RC=$?
  assert_eq 2 "$RC" "usage: $bad"
done
RC=0
dx_pr_thread_respond "$SESSION" "$repo" "not a repo" 7 310 fixed "$body_file" >/dev/null 2>&1 || RC=$?
assert_eq 2 "$RC" "usage: repo"
[[ ! -s "$GH_FAKE_CALLS" ]] || assert_at $LINENO

# --- dx_pr_threads_open -------------------------------------------------------------

reset_gh
python3 - "$MARKER" > "$GH_FAKE_DIR/threads.json" <<'PY'
import json
import sys

marker = sys.argv[1]


def c(cid, login, body, mine=False):
    return {"id": "C_%d" % cid, "databaseId": cid, "url": "https://example.test/c%d" % cid,
            "body": body, "viewerDidAuthor": mine, "author": {"login": login}}


def t(tid, resolved, comments):
    return {"id": tid, "isResolved": resolved, "viewerCanResolve": True,
            "comments": {"nodes": comments}}


page1 = [
    t("T_reported", False, [c(1, "greptile-apps[bot]", "nit"), c(2, "me", "Keeping it.\n\n" + marker, True)]),
    t("T_reopened", False, [c(3, "octocat", "why?"), c(4, "me", "Because.\n\n" + marker, True),
                            c(5, "octocat", "I still disagree")]),
    t("T_resolved", True, [c(6, "octocat", "done")]),
    t("T_plain", False, [c(7, "octocat", "please\tfix\nthis")]),
]
page2 = [t("T_page2", False, [c(8, "copilot-pull-request-reviewer[bot]", "bug")])]
print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {
    "nodes": page1, "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}}}}}))
print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {
    "nodes": page2, "pageInfo": {"hasNextPage": False, "endCursor": None}}}}}}))
PY
open_out=$(dx_pr_threads_open "$SESSION" "$REPO" 7)
assert_eq $'T_reported\t1\tgreptile-apps[bot]\thttps://example.test/c1\treported
T_reopened\t3\toctocat\thttps://example.test/c3\topen
T_plain\t7\toctocat\thttps://example.test/c7\topen
T_page2\t8\tcopilot-pull-request-reviewer[bot]\thttps://example.test/c8\topen' "$open_out" "open threads"

# A query failure is rc 1 with no output, never an empty (clean) list.
reset_gh
RC=0
open_out=$(dx_pr_threads_open "$SESSION" "$REPO" 7) || RC=$?
assert_eq 1 "$RC" "open threads query failure"
assert_eq "" "$open_out" "open threads failure output"
# So is a page that is not a review-thread payload.
printf '{"errors":[{"message":"rate limited"}]}\n' > "$GH_FAKE_DIR/threads.json"
RC=0
open_out=$(dx_pr_threads_open "$SESSION" "$REPO" 7) || RC=$?
assert_eq 1 "$RC" "open threads error payload"
assert_eq "" "$open_out" "open threads error payload output"
assert_rejected "open threads usage" dx_pr_threads_open "$SESSION" "$REPO" x

# --- dx_pr_pending_review_clear -----------------------------------------------------

pending_fixture() {
  python3 - "$@" > "$GH_FAKE_DIR/pending.json" <<'PY'
import json
import sys

nodes = []
for spec in sys.argv[1:]:
    rid, mine = spec.split(":")
    nodes.append({"databaseId": int(rid), "viewerDidAuthor": mine == "mine",
                  "body": "Draft summary for %s" % rid})
print(json.dumps({"data": {"repository": {"pullRequest": {"reviews": {"nodes": nodes}}}}}))
PY
}

backup_of() {
  local found=""
  for f in "$DX_RUN_ROOT"/*/artifacts/pending-review-"$1".json; do
    [[ -f "$f" ]] && found="$f"
  done
  printf '%s\n' "$found"
}

# Nothing pending: no deletes.
reset_gh
pending_fixture
RC=0
pend_out=$(dx_pr_pending_review_clear "$SESSION" "$REPO" 7) || RC=$?
assert_eq 0 "$RC" "no pending rc"
assert_eq "" "$pend_out" "no pending output"
assert_eq "graphql pending" "$(calls)" "no pending calls"

# The viewer's pending review is saved, then deleted; another user's is kept.
reset_gh
pending_fixture 501:mine 502:theirs
cat > "$GH_FAKE_DIR/review-comments-501.json" <<'JSON'
[{"path": "lib/a.sh", "line": 12, "body": "first draft"}]
[{"path": "lib/b.sh", "line": null, "body": "outdated draft", "id": 9}]
JSON
RC=0
pend_out=$(dx_pr_pending_review_clear "$SESSION" "$REPO" 7) || RC=$?
assert_eq 0 "$RC" "pending clear rc"
backup=$(backup_of 501)
[[ -n "$backup" ]] || assert_at $LINENO
assert_eq $'deleted\t501\t2\t'"$backup" "$pend_out" "pending clear output"
assert_eq "graphql pending
GET repos/example/repo/pulls/7/reviews/501/comments
DELETE repos/example/repo/pulls/7/reviews/501 backup=present" "$(calls)" "pending clear calls"
python3 - "$backup" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["review_id"] == 501 and data["pr"] == 7 and data["repo"] == "example/repo", data
assert data["body"] == "Draft summary for 501", data
assert data["comments"] == [
    {"path": "lib/a.sh", "line": 12, "body": "first draft"},
    {"path": "lib/b.sh", "line": None, "body": "outdated draft"},
], data
PY
[[ -z "$(backup_of 502)" ]] || assert_at $LINENO
grep -Fq 'pending-review-501.json' "$(dirname "$backup")/manifest.json" || assert_at $LINENO
for leftover in "$(dirname "$backup")"/*.tmp.*; do
  [[ ! -e "$leftover" ]] || assert_at $LINENO
done

# Draft comments that cannot be read: no copy, so no delete; rc 5.
reset_gh
rm -rf "$DX_RUN_ROOT"
pending_fixture 503:mine
RC=0
pend_out=$(dx_pr_pending_review_clear "$SESSION" "$REPO" 7 2>"$TMP_DIR/err") || RC=$?
assert_eq 5 "$RC" "unreadable drafts rc"
assert_eq "" "$pend_out" "unreadable drafts output"
[[ "$(calls)" != *DELETE* ]] || assert_at $LINENO
assert_contains 'keeping it' "$TMP_DIR/err"

# The backup cannot be written: no delete; rc 5.
reset_gh
rm -rf "$DX_RUN_ROOT"
pending_fixture 504:mine
printf '[]\n' > "$GH_FAKE_DIR/review-comments-504.json"
run_id=$(dx_run_resolve "$SESSION")
mkdir -p "$(dx_run_dir "$run_id")"
chmod a-w "$(dx_run_dir "$run_id")"
RC=0
pend_out=$(dx_pr_pending_review_clear "$SESSION" "$REPO" 7 2>"$TMP_DIR/err") || RC=$?
chmod u+w "$(dx_run_dir "$run_id")"
assert_eq 5 "$RC" "unwritable backup rc"
[[ "$(calls)" != *DELETE* ]] || assert_at $LINENO
assert_contains 'could not save pending review 504' "$TMP_DIR/err"

# No session to own a run: no backup, so no delete.
reset_gh
pending_fixture 505:mine
printf '[]\n' > "$GH_FAKE_DIR/review-comments-505.json"
RC=0
dx_pr_pending_review_clear "" "$REPO" 7 >/dev/null 2>&1 || RC=$?
assert_eq 5 "$RC" "no session rc"
[[ "$(calls)" != *DELETE* ]] || assert_at $LINENO

# The delete fails: rc 3, the copy stays.
reset_gh
rm -rf "$DX_RUN_ROOT"
pending_fixture 506:mine
printf '[]\n' > "$GH_FAKE_DIR/review-comments-506.json"
: > "$GH_FAKE_DIR/delete.fail"
RC=0
pend_out=$(dx_pr_pending_review_clear "$SESSION" "$REPO" 7 2>/dev/null) || RC=$?
assert_eq 3 "$RC" "delete failure rc"
[[ -n "$(backup_of 506)" ]] || assert_at $LINENO

# The pending list cannot be read: rc 1.
reset_gh
RC=0
dx_pr_pending_review_clear "$SESSION" "$REPO" 7 >/dev/null 2>&1 || RC=$?
assert_eq 1 "$RC" "pending query failure"
assert_rejected "pending usage" dx_pr_pending_review_clear "$SESSION" "$REPO"

printf 'pr-threads-test: ok\n'
