# shellcheck shell=bash
# Dex shared library - the review-thread policy for PR review comments.
#
# `/dxprreview` decides what to do with each review comment; these helpers do
# the GitHub side of that decision. One optional `thread_policy` key in the
# `## Resources` block of `.dex/dex.md` chooses how:
#   keep-disagreements-open (default) - fixed and answered comments are resolved
#     with a 👍 on bot comments; a disagreement gets a reply carrying the
#     DX_PR_THREAD_DISAGREE_MARKER, a 👎 on bot comments, and stays open so the
#     person who merges the PR sees it. Phase 6 lists those threads instead of
#     treating them as actionable.
#   resolve-all - the behaviour before the policy existed: reply, then resolve
#     every thread Dex has a clear answer for, with no reactions.
#
# Comment bodies come from reviewers and are untrusted. They are parsed as
# JSON data and reply bodies are passed to gh by file, never through a shell
# string.

DX_PR_THREAD_DISAGREE_MARKER='<!-- dex:thread-disagreement -->'
DX_PR_THREAD_POLICY_DEFAULT='keep-disagreements-open'

# dx_pr_thread_policy <repo_dir>
# Print the effective policy: keep-disagreements-open or resolve-all. Always
# returns 0. An absent key, section or file, or a malformed block, means the
# default; an unknown or list value warns on stderr and means the default.
dx_pr_thread_policy() {
  [[ $# -eq 1 ]] || return 2
  local policy_raw policy_lines
  policy_raw=$(dx_project_contract_values "$1" Resources thread_policy \
    2>/dev/null) || policy_raw=""
  policy_lines=$(printf '%s\n' "$policy_raw" | grep -c . || true)
  if [[ -z "$policy_raw" ]]; then
    printf '%s\n' "$DX_PR_THREAD_POLICY_DEFAULT"
    return 0
  fi
  if [[ "$policy_lines" -ne 1 ]]; then
    printf 'dex: thread_policy must be one value; using %s\n' \
      "$DX_PR_THREAD_POLICY_DEFAULT" >&2
    printf '%s\n' "$DX_PR_THREAD_POLICY_DEFAULT"
    return 0
  fi
  policy_raw=$(printf '%s' "$policy_raw" | tr '[:upper:]' '[:lower:]')
  case "$policy_raw" in
    keep-disagreements-open|resolve-all)
      printf '%s\n' "$policy_raw"
      ;;
    *)
      printf 'dex: thread_policy "%s" is not keep-disagreements-open or resolve-all; using %s\n' \
        "$policy_raw" "$DX_PR_THREAD_POLICY_DEFAULT" >&2
      printf '%s\n' "$DX_PR_THREAD_POLICY_DEFAULT"
      ;;
  esac
}

__dx_pr_threads_repo_ok() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

# The handle Dex prefixes to a disagreement reply on a Greptile comment, so
# Greptile re-reads the thread: the Reviewers row for Greptile, else the
# canonical @greptileai.
__dx_pr_threads_greptile_handle() {
  local handle_repo="$1" row_handle row_rest row_adapter
  while IFS=$'\t' read -r row_handle row_rest; do
    [[ -n "$row_handle" ]] || continue
    row_adapter="${row_rest##*$'\t'}"
    if [[ "$row_adapter" == "greptile" ]] || __dx_reviewers_is_greptile "$row_handle"; then
      printf '@%s\n' "${row_handle#@}"
      return 0
    fi
  done <<ROWS
$(dx_reviewers_rows "$handle_repo" 2>/dev/null || true)
ROWS
  printf '%s\n' '@greptileai'
}

# __dx_pr_threads_fetch <session> <owner/repo> <pr> <out_file>
# Every review thread of the PR, all pages, as gh prints them: one JSON
# document per page, concatenated. Each thread carries its first 100 comments
# and, separately, its last one, so a long thread is still judged by its
# latest reply.
__dx_pr_threads_fetch() {
  local fetch_session="$1" fetch_repo="$2" fetch_pr="$3" fetch_out="$4"
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub, not the shell.
  __dx_reviewers_gh "$fetch_session" api graphql --paginate \
    -f "owner=${fetch_repo%%/*}" \
    -f "name=${fetch_repo#*/}" \
    -F "number=$fetch_pr" \
    -f query='
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes {
          id
          isResolved
          viewerCanResolve
          comments(first: 100) {
            nodes { id databaseId url body viewerDidAuthor author { login } }
          }
          latest: comments(last: 1) {
            nodes { body viewerDidAuthor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}' > "$fetch_out"
}

# dx_pr_threads_open <session> <owner/repo> <pr>
# One TSV line per unresolved review thread:
#   thread_id<TAB>root_comment_id<TAB>root_author<TAB>url<TAB>reported|open
# `reported` means Dex's reply carrying DX_PR_THREAD_DISAGREE_MARKER is the
# thread's last comment: a disagreement left open for the person who merges,
# not feedback for Dex to act on. A reviewer reply after it makes the thread
# `open` again. Returns 1 when the threads cannot be read, which callers treat
# as "feedback state unknown", never as clean.
dx_pr_threads_open() {
  [[ $# -eq 3 ]] || return 2
  local open_session="$1" open_repo="$2" open_pr="$3" open_raw open_rc=0
  __dx_pr_threads_repo_ok "$open_repo" || return 2
  [[ "$open_pr" =~ ^[0-9]+$ ]] || return 2
  open_raw=$(mktemp "${TMPDIR:-/tmp}/dex-pr-threads.XXXXXX") || return 1
  if ! __dx_pr_threads_fetch "$open_session" "$open_repo" "$open_pr" "$open_raw"; then
    rm -f "$open_raw"
    return 1
  fi
  python3 - "$open_raw" "$DX_PR_THREAD_DISAGREE_MARKER" <<'PY' || open_rc=1
import json
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
marker = sys.argv[2]
decoder = json.JSONDecoder()
docs, index = [], 0
try:
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        doc, index = decoder.raw_decode(text, index)
        docs.append(doc)
except ValueError:
    raise SystemExit(1)
if not docs:
    raise SystemExit(1)


def clean(value):
    return " ".join(str(value if value is not None else "").split())


# Print nothing unless every page parsed: a partial list would read as fewer
# open threads than there are.
rows = []
for doc in docs:
    pull = ((doc.get("data") or {}).get("repository") or {}).get("pullRequest") if isinstance(doc, dict) else None
    if not isinstance(pull, dict) or doc.get("errors"):
        raise SystemExit(1)
    for thread in (pull.get("reviewThreads") or {}).get("nodes") or []:
        if not isinstance(thread, dict) or thread.get("isResolved"):
            continue
        comments = (thread.get("comments") or {}).get("nodes") or []
        if not comments:
            continue
        root = comments[0]
        last = ((thread.get("latest") or {}).get("nodes") or [comments[-1]])[-1]
        reported = bool(last.get("viewerDidAuthor")) and marker in str(last.get("body") or "")
        rows.append("\t".join([
            clean(thread.get("id")),
            clean(root.get("databaseId")),
            clean((root.get("author") or {}).get("login")),
            clean(root.get("url")),
            "reported" if reported else "open",
        ]))
for row in rows:
    print(row)
PY
  rm -f "$open_raw"
  return "$open_rc"
}

# __dx_pr_threads_thread_for <raw_threads_file> <comment_node_id>
# Prints "thread_id<TAB>resolved<TAB>can_resolve<TAB>viewer_replied" (0 or 1
# flags) for the thread holding the comment, or nothing when no thread does.
__dx_pr_threads_thread_for() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
target = sys.argv[2]
decoder = json.JSONDecoder()
index = 0
try:
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        doc, index = decoder.raw_decode(text, index)
        pull = ((doc.get("data") or {}).get("repository") or {}).get("pullRequest") if isinstance(doc, dict) else None
        if not isinstance(pull, dict):
            raise SystemExit(1)
        for thread in (pull.get("reviewThreads") or {}).get("nodes") or []:
            comments = (thread.get("comments") or {}).get("nodes") or []
            if not any(c.get("id") == target for c in comments):
                continue
            print("%s\t%d\t%d\t%d" % (
                thread.get("id") or "",
                1 if thread.get("isResolved") else 0,
                0 if thread.get("viewerCanResolve") is False else 1,
                1 if any(c.get("viewerDidAuthor") for c in comments) else 0,
            ))
            raise SystemExit(0)
except ValueError:
    raise SystemExit(1)
PY
}

__dx_pr_threads_resolve() {
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub, not the shell.
  __dx_reviewers_gh "$1" api graphql \
    -f "threadId=$2" \
    -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { id isResolved }
  }
}' >/dev/null
}

# dx_pr_thread_respond <session> <repo_dir> <owner/repo> <pr> <comment_id> <outcome> <body_file>
# Reply to one inline review comment and apply the thread policy for the
# outcome `/dxprreview` decided:
#   fixed     - fixed, or a nitpick fixed
#   disagree  - not fixing with cited reasoning, a false positive, or missing
#               context on the reviewer's side
#   answered  - a question answered, or a valid but non-blocking comment
#   followup  - Dex asks the reviewer a clarifying question
# Escalated comments get no reply and do not come here.
#
#   outcome   keep-disagreements-open          resolve-all
#   fixed     reply, +1 on a bot, resolve      reply, resolve
#   disagree  reply + marker, -1 on a bot,     reply, resolve
#             left open
#   answered  reply, +1 on a bot, resolve      reply, resolve
#   followup  reply, left open                 reply, left open
#
# A disagreement on a Greptile comment starts with the Greptile handle on
# Dex's first reply in the thread, so Greptile re-reads it; later replies
# skip it, so the two never mention each other back and forth.
#
# Prints one TSV line:
#   comment_id<TAB>reply=posted<TAB>reaction=+1|-1|none|failed<TAB>thread=resolved|open|failed
# Returns 0; 2 on a usage error; 4 when the body mentions @copilot (nothing is
# posted); 1 when the comment cannot be read or the reply fails (nothing else
# runs); 3 when the reply was posted but the reaction, the thread lookup or
# the resolve failed.
dx_pr_thread_respond() {
  [[ $# -eq 7 ]] || return 2
  local resp_session="$1" resp_repo_dir="$2" resp_repo="$3" resp_pr="$4"
  local resp_comment="$5" resp_outcome="$6" resp_body_file="$7"
  local resp_policy resp_meta resp_node resp_login resp_type resp_threads
  local resp_thread="" resp_thread_id="" resp_resolved=0 resp_can_resolve=1
  local resp_replied=0 resp_lookup_ok=1 resp_reply resp_reaction=none
  local resp_thread_state=open resp_rc=0 resp_handle resp_wanted_reaction=""
  local resp_resolve=0 resp_login_greptile=0 resp_bot_login

  __dx_pr_threads_repo_ok "$resp_repo" || return 2
  [[ "$resp_pr" =~ ^[0-9]+$ && "$resp_comment" =~ ^[0-9]+$ ]] || return 2
  [[ -f "$resp_body_file" && -s "$resp_body_file" ]] || return 2
  case "$resp_outcome" in
    fixed|disagree|answered|followup) ;;
    *) return 2 ;;
  esac
  if __dx_reviewers_mentions_copilot "$(cat "$resp_body_file")"; then
    printf '%s\n' "dex: refusing to post a reply that mentions @copilot" >&2
    return 4
  fi
  resp_policy=$(dx_pr_thread_policy "$resp_repo_dir")

  resp_meta=$(__dx_reviewers_gh "$resp_session" api \
    "repos/${resp_repo}/pulls/comments/${resp_comment}" \
    --jq '[.node_id, .user.login, .user.type] | @tsv') || {
    printf 'dex: could not read review comment %s\n' "$resp_comment" >&2
    return 1
  }
  IFS=$'\t' read -r resp_node resp_login resp_type <<META
$resp_meta
META
  [[ -n "$resp_node" ]] || return 1

  resp_threads=$(mktemp "${TMPDIR:-/tmp}/dex-pr-threads.XXXXXX") || return 1
  if __dx_pr_threads_fetch "$resp_session" "$resp_repo" "$resp_pr" "$resp_threads" \
    && resp_thread=$(__dx_pr_threads_thread_for "$resp_threads" "$resp_node") \
    && [[ -n "$resp_thread" ]]; then
    IFS=$'\t' read -r resp_thread_id resp_resolved resp_can_resolve resp_replied <<THREAD
$resp_thread
THREAD
  else
    resp_lookup_ok=0
  fi
  rm -f "$resp_threads"

  resp_reply=$(mktemp "${TMPDIR:-/tmp}/dex-pr-reply.XXXXXX") || return 1
  if [[ "$resp_policy" == "keep-disagreements-open" && "$resp_outcome" == "disagree" ]]; then
    while IFS= read -r resp_bot_login; do
      [[ "$resp_login" == "$resp_bot_login" ]] && resp_login_greptile=1
    done <<LOGINS
$(dx_reviewer_adapter_logins greptile)
LOGINS
    resp_handle=""
    # Only when the lookup worked: an unknown thread may already hold a reply.
    if [[ "$resp_login_greptile" -eq 1 && "$resp_lookup_ok" -eq 1 && "$resp_replied" -eq 0 ]]; then
      resp_handle=$(__dx_pr_threads_greptile_handle "$resp_repo_dir")
      if [[ "$(head -c "${#resp_handle}" "$resp_body_file")" == "$resp_handle" ]]; then
        resp_handle=""
      fi
    fi
    {
      [[ -z "$resp_handle" ]] || printf '%s ' "$resp_handle"
      cat "$resp_body_file"
      printf '\n\n%s\n' "$DX_PR_THREAD_DISAGREE_MARKER"
    } > "$resp_reply"
  else
    cat "$resp_body_file" > "$resp_reply"
  fi

  if ! __dx_reviewers_gh "$resp_session" api --method POST \
    "repos/${resp_repo}/pulls/${resp_pr}/comments/${resp_comment}/replies" \
    -F "body=@${resp_reply}" >/dev/null; then
    rm -f "$resp_reply"
    printf 'dex: could not reply to review comment %s\n' "$resp_comment" >&2
    return 1
  fi
  rm -f "$resp_reply"

  if [[ "$resp_policy" == "keep-disagreements-open" && "$resp_type" == "Bot" ]]; then
    case "$resp_outcome" in
      fixed|answered) resp_wanted_reaction="+1" ;;
      disagree) resp_wanted_reaction="-1" ;;
    esac
  fi
  if [[ -n "$resp_wanted_reaction" ]]; then
    # GitHub answers 200 for a reaction that already exists, so a retry is safe.
    if __dx_reviewers_gh "$resp_session" api --method POST \
      "repos/${resp_repo}/pulls/comments/${resp_comment}/reactions" \
      -f "content=${resp_wanted_reaction}" >/dev/null; then
      resp_reaction="$resp_wanted_reaction"
    else
      resp_reaction=failed
      resp_rc=3
    fi
  fi

  case "$resp_outcome" in
    fixed|answered) resp_resolve=1 ;;
    disagree) [[ "$resp_policy" == "resolve-all" ]] && resp_resolve=1 ;;
  esac
  if [[ "$resp_lookup_ok" -eq 0 ]]; then
    # Without the thread there is nothing to resolve; a thread meant to stay
    # open is still open, but the caller still hears the lookup failed.
    [[ "$resp_resolve" -eq 0 ]] || resp_thread_state=failed
    resp_rc=3
  elif [[ "$resp_resolved" -eq 1 ]]; then
    resp_thread_state=resolved
  elif [[ "$resp_resolve" -eq 1 ]]; then
    if [[ "$resp_can_resolve" -eq 0 ]]; then
      printf 'dex: the GitHub token cannot resolve the thread for comment %s\n' "$resp_comment" >&2
      resp_thread_state=failed
      resp_rc=3
    elif __dx_pr_threads_resolve "$resp_session" "$resp_thread_id"; then
      resp_thread_state=resolved
    else
      resp_thread_state=failed
      resp_rc=3
    fi
  fi

  printf '%s\treply=posted\treaction=%s\tthread=%s\n' \
    "$resp_comment" "$resp_reaction" "$resp_thread_state"
  return "$resp_rc"
}

# dx_pr_pending_review_clear <session> <owner/repo> <pr>
# Delete the authenticated user's unsubmitted (PENDING) reviews on the PR. A
# pending review left by other tooling hides the replies Dex posts, so the
# keep-disagreements-open policy clears it before replying.
#
# Dex runs as the user, so a pending review may be the user's own unfinished
# review. Before each delete, the review body and every draft comment (path,
# line, body) are saved to the run's artifacts as pending-review-<id>.json. No
# complete copy, no delete. Reviews by anyone else are never touched.
#
# The drafts come from GraphQL: the REST review-comments endpoint reports
# `line: null` for a pending review's comments.
#
# Prints, per deleted review: deleted<TAB><review_id><TAB><draft_count><TAB><backup_path>
# Returns 0; 2 on a usage error; 1 when the pending reviews cannot be listed;
# 5 when a backup could not be written (that review is kept); otherwise 3
# when a delete failed.
dx_pr_pending_review_clear() {
  [[ $# -eq 3 ]] || return 2
  local pend_session="$1" pend_repo="$2" pend_pr="$3" pend_list pend_dir
  local pend_ids pend_id pend_count pend_run pend_backup pend_tmp pend_rc=0
  local pend_backup_failed=0 pend_delete_failed=0
  __dx_pr_threads_repo_ok "$pend_repo" || return 2
  [[ "$pend_pr" =~ ^[0-9]+$ ]] || return 2

  pend_dir=$(mktemp -d "${TMPDIR:-/tmp}/dex-pr-pending.XXXXXX") || return 1
  pend_list="$pend_dir/reviews.json"
  # shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub, not the shell.
  if ! __dx_reviewers_gh "$pend_session" api graphql \
    -f "owner=${pend_repo%%/*}" \
    -f "name=${pend_repo#*/}" \
    -F "number=$pend_pr" \
    -f query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviews(states: [PENDING], first: 50) {
        nodes {
          databaseId
          viewerDidAuthor
          body
          comments(first: 100) {
            nodes { path line originalLine body }
            pageInfo { hasNextPage }
          }
        }
      }
    }
  }
}' > "$pend_list"; then
    rm -rf "$pend_dir"
    return 1
  fi
  # Writes <id>.json (the backup) or <id>.incomplete (more than 100 drafts)
  # per pending review the viewer wrote, and prints the ids.
  if ! pend_ids=$(python3 - "$pend_list" "$pend_dir" "$pend_repo" "$pend_pr" <<'PY'
import json
import os
import sys

source, out_dir, repo, pr = sys.argv[1:5]
try:
    doc = json.load(open(source, encoding="utf-8", errors="replace"))
    nodes = doc["data"]["repository"]["pullRequest"]["reviews"]["nodes"]
except (ValueError, KeyError, TypeError):
    raise SystemExit(1)
for node in nodes or []:
    if not (isinstance(node, dict) and node.get("viewerDidAuthor") and node.get("databaseId")):
        continue
    review_id = int(node["databaseId"])
    comments = node.get("comments") or {}
    if (comments.get("pageInfo") or {}).get("hasNextPage"):
        open(os.path.join(out_dir, "%d.incomplete" % review_id), "w").close()
    else:
        drafts = []
        for item in comments.get("nodes") or []:
            if isinstance(item, dict):
                line = item.get("line")
                drafts.append({
                    "path": item.get("path"),
                    "line": line if line is not None else item.get("originalLine"),
                    "body": item.get("body"),
                })
        backup = {"review_id": review_id, "repo": repo, "pr": int(pr),
                  "body": node.get("body") or "", "comments": drafts}
        with open(os.path.join(out_dir, "%d.json" % review_id), "w", encoding="utf-8") as handle:
            json.dump(backup, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
    print(review_id)
PY
  ); then
    rm -rf "$pend_dir"
    return 1
  fi

  while IFS= read -r pend_id; do
    [[ "$pend_id" =~ ^[0-9]+$ ]] || continue
    if [[ -f "$pend_dir/$pend_id.incomplete" ]]; then
      printf 'dex: pending review %s has more than 100 draft comments; keeping it\n' "$pend_id" >&2
      pend_backup_failed=1
      continue
    fi
    pend_backup=""
    pend_tmp=""
    if pend_run=$(dx_run_resolve "$pend_session" 2>/dev/null) \
      && pend_backup=$(dx_run_artifact_file "$pend_run" "pending-review-${pend_id}.json") \
      && mkdir -p "$(dirname "$pend_backup")" \
      && pend_tmp="${pend_backup}.tmp.$$" \
      && command cp "$pend_dir/$pend_id.json" "$pend_tmp" \
      && command mv -f "$pend_tmp" "$pend_backup"; then
      dx_run_register_artifact_safe "$pend_run" pending-review \
        "pending-review-${pend_id}.json" "Pending review ${pend_id} saved before delete" \
        "{\"producer\":\"dx_pr_pending_review_clear\",\"pr\":${pend_pr}}"
    else
      [[ -z "$pend_tmp" ]] || rm -f "$pend_tmp"
      printf 'dex: could not save pending review %s before deleting it; keeping it\n' "$pend_id" >&2
      pend_backup_failed=1
      continue
    fi
    pend_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["comments"]))' \
      "$pend_backup" 2>/dev/null) || pend_count="?"
    if __dx_reviewers_gh "$pend_session" api --method DELETE \
      "repos/${pend_repo}/pulls/${pend_pr}/reviews/${pend_id}" >/dev/null; then
      printf 'deleted\t%s\t%s\t%s\n' "$pend_id" "$pend_count" "$pend_backup"
    else
      printf 'dex: could not delete pending review %s (saved at %s)\n' "$pend_id" "$pend_backup" >&2
      pend_delete_failed=1
    fi
  done <<IDS
$pend_ids
IDS
  rm -rf "$pend_dir"

  if [[ "$pend_backup_failed" -eq 1 ]]; then
    pend_rc=5
  elif [[ "$pend_delete_failed" -eq 1 ]]; then
    pend_rc=3
  fi
  return "$pend_rc"
}
