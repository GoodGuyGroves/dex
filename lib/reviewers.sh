# shellcheck shell=bash
# Dex shared library - reviewer adapters and Phase 6 waits.
#
# The `## Reviewers` table in `.dex/dex.md` routes PR review notifications.
# Two optional columns opt a row into more: `Wait` (yes/no) holds Phase 6 open
# until that reviewer has reviewed the PR's current head, and `Adapter`
# (greptile | copilot | generic) says how to trigger the bot and how to tell
# it has finished. Rows without the columns behave as they always have.
#
# Everything here reads GitHub state through `gh` and decides deterministically,
# so the Phase 6 prompts call these helpers instead of judging bot output.

# Copilot aliases, matching dx_maintenance_normalize_reviewer.
__dx_reviewers_is_copilot() {
  local handle lower
  handle="${1#@}"
  lower=$(printf '%s' "$handle" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    copilot|github-copilot|github-copilot-review|copilot-pull-request-reviewer|copilot-pull-request-reviewer\[bot\]|github-copilot\[bot\])
      return 0
      ;;
  esac
  return 1
}

__dx_reviewers_is_greptile() {
  local lower
  lower=$(printf '%s' "${1#@}" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    greptile|greptileai|greptile-apps|greptile-apps\[bot\]) return 0 ;;
  esac
  return 1
}

# dx_reviewer_default_adapter <handle> <wait>
# The adapter for a row that names none: `copilot` or `greptile` when a
# `wait: yes` row's handle is that bot, else `generic`. dx_reviewers_rows and
# `dx config` share it, so a written row and a blank cell resolve the same way.
dx_reviewer_default_adapter() {
  [[ $# -eq 2 ]] || return 2
  if [[ "$2" == "yes" ]]; then
    if __dx_reviewers_is_copilot "$1"; then
      printf '%s\n' copilot
      return 0
    fi
    if __dx_reviewers_is_greptile "$1"; then
      printf '%s\n' greptile
      return 0
    fi
  fi
  printf '%s\n' generic
}

# dx_reviewers_rows <repo_dir>
# Print one TSV line per usable `## Reviewers` row:
#   handle<TAB>type<TAB>wait<TAB>adapter
# Handle and Type are the first two columns, as they always were. Wait and
# Adapter are found by header name, so their position and the Notes column do
# not matter. Defaults are wait=no and adapter=generic. A blank Adapter on a
# `wait: yes` row is inferred from the handle. A Copilot row is always a
# `request` row: mentioning @copilot in a comment summons the Copilot coding
# agent, which can push commits.
# Returns 1 when the file or the section is missing; problems with single rows
# are reported on stderr and the row is skipped or defaulted.
dx_reviewers_rows() {
  [[ $# -eq 1 ]] || return 2
  local dex_md="$1/.dex/dex.md" raw handle row_type wait_value adapter
  [[ -f "$dex_md" ]] || return 1
  raw=$(awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^## Reviewers[[:space:]]*$/ { in_section = 1; found = 1; next }
    in_section && /^## / { exit }
    !in_section { next }
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
    in_fence { next }
    !/^[[:space:]]*\|/ { next }
    {
      first = tolower(trim($2))
      if (first == "handle") {
        wait_col = 0; adapter_col = 0
        for (i = 2; i <= NF; i++) {
          name = tolower(trim($i))
          if (name == "wait") wait_col = i
          if (name == "adapter") adapter_col = i
        }
        next
      }
      if (first ~ /^:?-+:?$/ || first == "" || first == "_none_") next
      w = wait_col ? trim($wait_col) : ""
      a = adapter_col ? trim($adapter_col) : ""
      printf "%s\037%s\037%s\037%s\n", trim($2), trim($3), w, a
    }
    END { if (!found) exit 3 }
  ' "$dex_md") || return 1

  # \037 rather than a tab: tabs are IFS whitespace, so `read` would collapse
  # an empty Wait cell and shift the columns after it.
  while IFS=$'\037' read -r handle row_type wait_value adapter; do
    [[ -n "$handle" ]] || continue
    row_type=$(printf '%s' "$row_type" | tr '[:upper:]' '[:lower:]')
    wait_value=$(printf '%s' "$wait_value" | tr '[:upper:]' '[:lower:]')
    adapter=$(printf '%s' "$adapter" | tr '[:upper:]' '[:lower:]')
    case "$row_type" in
      request|mention) ;;
      *)
        printf 'dex: skipping reviewer %s: unknown type "%s"\n' \
          "$handle" "$row_type" >&2
        continue
        ;;
    esac
    case "$wait_value" in
      yes|true|y) wait_value=yes ;;
      no|false|n|"") wait_value=no ;;
      *)
        printf 'dex: reviewer %s: wait "%s" is not yes or no; using no\n' \
          "$handle" "$wait_value" >&2
        wait_value=no
        ;;
    esac
    case "$adapter" in
      greptile|copilot|generic) ;;
      "") adapter=$(dx_reviewer_default_adapter "$handle" "$wait_value") ;;
      *)
        printf 'dex: reviewer %s: unknown adapter "%s"; using generic\n' \
          "$handle" "$adapter" >&2
        adapter=generic
        ;;
    esac
    if [[ "$adapter" == "copilot" ]] || __dx_reviewers_is_copilot "$handle"; then
      row_type=request
    fi
    printf '%s\t%s\t%s\t%s\n' "$handle" "$row_type" "$wait_value" "$adapter"
  done <<EOF
$raw
EOF
}

# dx_reviewer_adapter_logins <adapter>
# The GitHub logins a bot posts its reviews and comments as. Comments from
# these logins are review feedback even though the authors are bots.
dx_reviewer_adapter_logins() {
  case "${1:-}" in
    greptile) printf '%s\n' 'greptile-apps[bot]' 'greptile-apps-staging[bot]' ;;
    copilot) printf '%s\n' 'copilot-pull-request-reviewer[bot]' 'Copilot' ;;
    generic) ;;
    *) return 2 ;;
  esac
}

# --- GitHub access -------------------------------------------------------------

# Every gh call goes through the watcher's live command timeout when a session
# is known, so a hung API call cannot stall a Phase 6 cycle.
__dx_reviewers_gh() {
  local gh_session="$1"
  shift
  if dx_session_id_valid "$gh_session"; then
    dx_watch_run_command "$gh_session" gh "$@"
  else
    gh "$@"
  fi
}

__dx_reviewers_head() {
  local head_session="$1" head_pr="$2" head_sha
  head_sha=$(__dx_reviewers_gh "$head_session" pr view "$head_pr" \
    --json headRefOid --jq '.headRefOid') || return 1
  [[ "$head_sha" =~ ^[0-9a-f]{7,64}$ ]] || return 1
  printf '%s\n' "$head_sha"
}

__dx_reviewers_now() { date +%s; }

__dx_reviewers_key() {
  printf '%s' "${1#@}" | tr '[:upper:]' '[:lower:]'
}

# --- Wait ledger -----------------------------------------------------------------
# One row per waited item on the current head, in dx_complete_wait_file:
#   kind<TAB>key<TAB>head<TAB>started<TAB>triggered<TAB>state
# kind is `reviewer` or `ci`; key is the lower-cased handle without `@`, or `-`
# for CI. Unset times are `-`, so no field is ever empty. Writing drops the rows
# of every other head: a new push restarts every clock.

__dx_reviewers_ledger_get() {
  local get_session="$1" get_kind="$2" get_key="$3" get_head="$4" ledger
  ledger=$(dx_complete_wait_file "$get_session")
  [[ -f "$ledger" ]] || return 1
  awk -F'\t' -v k="$get_kind" -v key="$get_key" -v h="$get_head" '
    $1 == k && $2 == key && $3 == h { print $4 "\t" $5 "\t" $6; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$ledger"
}

__dx_reviewers_ledger_put() {
  local put_session="$1" put_kind="$2" put_key="$3" put_head="$4"
  local put_started="$5" put_triggered="$6" put_state="$7" ledger tmp
  ledger=$(dx_complete_wait_file "$put_session")
  mkdir -p "$(dirname "$ledger")" || return 1
  tmp=$(mktemp "${ledger}.XXXXXX") || return 1
  if [[ -f "$ledger" ]]; then
    awk -F'\t' -v k="$put_kind" -v key="$put_key" -v h="$put_head" '
      $3 == h && !($1 == k && $2 == key) { print }
    ' "$ledger" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$put_kind" "$put_key" "$put_head" \
    "$put_started" "$put_triggered" "$put_state" >> "$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$ledger"
}

# Record a settled CI state (green, failed, error) on the CI rows, so CI that
# goes pending again on the same head starts a new pending clock. It needs no
# head lookup: the ledger only keeps rows for the head it last wrote.
__dx_reviewers_ledger_settle_ci() {
  local settle_session="$1" settle_state="$2" ledger tmp
  ledger=$(dx_complete_wait_file "$settle_session")
  [[ -f "$ledger" ]] || return 0
  grep -q $'^ci\t' "$ledger" || return 0
  tmp=$(mktemp "${ledger}.XXXXXX") || return 1
  awk -F'\t' -v OFS='\t' -v s="$settle_state" '$1 == "ci" { $6 = s } { print }' \
    "$ledger" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$ledger"
}

# --- Comments and triggers ---------------------------------------------------------

# __dx_reviewers_mentions_copilot <text>
# True when the text mentions @copilot or @github-copilot, which summons the
# Copilot coding agent. Every Dex-authored PR comment and reply checks this.
__dx_reviewers_mentions_copilot() {
  printf '%s\n' "$1" | grep -Eiq '(^|[^A-Za-z0-9_.-])@(github-)?copilot'
}

# dx_reviewer_comment <session_id> <pr> <body>
# The one way Dex posts a reviewer-directed PR comment. A body that mentions
# @copilot or @github-copilot is refused with rc 4 before gh runs: that mention
# summons the Copilot coding agent, which can push commits. Copilot reviews are
# requested with `gh pr edit --add-reviewer @copilot` instead.
dx_reviewer_comment() {
  [[ $# -eq 3 ]] || return 2
  local comment_session="$1" comment_pr="$2" comment_body="$3" body_file rc=0
  [[ "$comment_pr" =~ ^[0-9]+$ && -n "$comment_body" ]] || return 2
  if __dx_reviewers_mentions_copilot "$comment_body"; then
    printf '%s\n' "dex: refusing to post a PR comment that mentions @copilot; request Copilot with gh pr edit --add-reviewer @copilot" >&2
    return 4
  fi
  # A file, not stdin: the timeout wrapper runs gh as a background job, and a
  # background job does not get the caller's stdin.
  body_file=$(mktemp "${TMPDIR:-/tmp}/dex-reviewer-comment.XXXXXX") || return 1
  printf '%s\n' "$comment_body" > "$body_file" || { rm -f "$body_file"; return 1; }
  __dx_reviewers_gh "$comment_session" pr comment "$comment_pr" \
    --body-file "$body_file" || rc=$?
  rm -f "$body_file"
  return "$rc"
}

# Prints "status<TAB>conclusion" for the newest Greptile check run on a commit,
# or nothing when Greptile has not registered one there.
__dx_reviewers_greptile_check() {
  local check_session="$1" check_head="$2" check_json
  check_json=$(__dx_reviewers_gh "$check_session" api \
    "repos/{owner}/{repo}/commits/${check_head}/check-runs?per_page=100") \
    || return 1
  DX_REVIEWERS_JSON="$check_json" python3 - <<'PY'
import json
import os
import re

try:
    runs = json.loads(os.environ["DX_REVIEWERS_JSON"]).get("check_runs") or []
except (ValueError, AttributeError):
    raise SystemExit(1)
runs = [r for r in runs if isinstance(r, dict) and re.search("greptile", str(r.get("name", "")), re.I)]
if runs:
    run = max(runs, key=lambda r: (str(r.get("started_at") or ""), r.get("id") or 0))
    print("%s\t%s" % (run.get("status") or "-", run.get("conclusion") or "-"))
PY
}

# dx_reviewer_trigger <session_id> <repo_dir> <pr> <handle> <adapter> [focus]
# Ask an adapter reviewer to review the PR's current head, and record when.
#   copilot  - `gh pr edit --add-reviewer @copilot` through the maintenance
#              helper; never a comment. A request GitHub does not keep (Copilot
#              review not enabled, or Copilot is the author) is recorded as
#              `unavailable`, so the wait gate does not hold Phase 6 for a
#              reviewer that cannot come.
#   greptile - a `@<handle> review` comment, skipped while Greptile's check run
#              on the head is already queued or running. With a focus it always
#              posts `@<handle> review. Please focus on <focus>.`, which is how
#              the agent points Greptile at the area that needs scrutiny.
#   generic  - returns 3; the caller keeps the plain request and mention steps.
dx_reviewer_trigger() {
  [[ $# -ge 5 && $# -le 6 ]] || return 2
  local trig_session="$1" trig_repo="$2" trig_pr="$3" trig_handle="$4"
  local trig_adapter="$5" trig_focus="${6:-}" trig_head trig_key now existing=""
  local trig_started="-" trig_previous="-" trig_state=waiting check body
  local persisted_rc=0 previous_state=""
  [[ "$trig_pr" =~ ^[0-9]+$ ]] || return 2
  dx_session_id_valid "$trig_session" || return 2
  case "$trig_adapter" in
    copilot|greptile) ;;
    generic) return 3 ;;
    *) return 2 ;;
  esac
  trig_head=$(cd "$trig_repo" && __dx_reviewers_head "$trig_session" "$trig_pr") || return 1
  trig_key=$(__dx_reviewers_key "$trig_handle")
  [[ "$trig_adapter" != "copilot" ]] || trig_key=copilot
  now=$(__dx_reviewers_now)
  if existing=$(__dx_reviewers_ledger_get "$trig_session" reviewer "$trig_key" "$trig_head"); then
    trig_started=$(printf '%s\n' "$existing" | cut -f1)
    trig_previous=$(printf '%s\n' "$existing" | cut -f2)
    previous_state=$(printf '%s\n' "$existing" | cut -f3)
  fi
  [[ "$trig_started" != "-" ]] || trig_started="$now"
  # A timeout is final for this head: asking again still reaches the reviewer,
  # but it does not reopen the wait.
  [[ "$previous_state" != "timeout" ]] || trig_state=timeout

  if [[ "$trig_adapter" == "copilot" ]]; then
    (cd "$trig_repo" && dx_maintenance_request_reviewer "$trig_pr" "@copilot") || return 1
    (cd "$trig_repo" && dx_maintenance_review_request_persisted "$trig_pr" "@copilot") \
      >/dev/null 2>&1 || persisted_rc=$?
    case "$persisted_rc" in
      10|11) [[ "$trig_state" == "timeout" ]] || trig_state=unavailable ;;
    esac
  else
    if [[ -z "$trig_focus" ]]; then
      check=$(cd "$trig_repo" && __dx_reviewers_greptile_check "$trig_session" "$trig_head") \
        || check=""
      case "${check%%	*}" in
        queued|in_progress|pending|requested|waiting)
          __dx_reviewers_ledger_put "$trig_session" reviewer "$trig_key" \
            "$trig_head" "$trig_started" "$trig_previous" "$trig_state"
          return
          ;;
      esac
      body="@${trig_handle#@} review"
    else
      body="@${trig_handle#@} review. Please focus on ${trig_focus}."
    fi
    (cd "$trig_repo" && dx_reviewer_comment "$trig_session" "$trig_pr" "$body") || return
  fi
  __dx_reviewers_ledger_put "$trig_session" reviewer "$trig_key" "$trig_head" \
    "$trig_started" "$now" "$trig_state"
}

# --- Done on the current head ----------------------------------------------------

# Prints "state<TAB>detail" for Copilot on this head: done when Copilot is no
# longer a requested reviewer and has a review of exactly this commit, submitted
# at or after the recorded trigger; in-progress while it is still requested.
__dx_reviewers_copilot_state() {
  local cs_session="$1" cs_pr="$2" cs_head="$3" cs_triggered="$4" pull reviews
  pull=$(__dx_reviewers_gh "$cs_session" api "repos/{owner}/{repo}/pulls/${cs_pr}") || return 1
  reviews=$(__dx_reviewers_gh "$cs_session" api \
    "repos/{owner}/{repo}/pulls/${cs_pr}/reviews?per_page=100") || return 1
  DX_REVIEWERS_PULL="$pull" DX_REVIEWERS_REVIEWS="$reviews" \
  DX_REVIEWERS_HEAD="$cs_head" DX_REVIEWERS_TRIGGERED="$cs_triggered" python3 - <<'PY'
import calendar
import json
import os
import time

ALIASES = {
    "copilot",
    "github-copilot",
    "github-copilot[bot]",
    "copilot-pull-request-reviewer",
    "copilot-pull-request-reviewer[bot]",
}


def epoch(value):
    try:
        return calendar.timegm(time.strptime(str(value), "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None


try:
    pull = json.loads(os.environ["DX_REVIEWERS_PULL"])
    reviews = json.loads(os.environ["DX_REVIEWERS_REVIEWS"])
except ValueError:
    raise SystemExit(1)
if not isinstance(pull, dict) or not isinstance(reviews, list):
    raise SystemExit(1)
head = os.environ["DX_REVIEWERS_HEAD"]
triggered = os.environ.get("DX_REVIEWERS_TRIGGERED", "-")
requested = any(
    str((item or {}).get("login", "")).lower() in ALIASES
    for item in pull.get("requested_reviewers") or []
    if isinstance(item, dict)
)
if requested:
    print("in-progress\trequested")
    raise SystemExit(0)
for review in reviews:
    if not isinstance(review, dict):
        continue
    login = str((review.get("user") or {}).get("login", "")).lower()
    if login not in ALIASES or review.get("commit_id") != head:
        continue
    if triggered not in ("", "-"):
        submitted = epoch(review.get("submitted_at"))
        if submitted is None or submitted < int(triggered):
            continue
    print("done\t%s" % (review.get("state") or "COMMENTED"))
    raise SystemExit(0)
print("not-started\t-")
PY
}

# Prints "state<TAB>detail" for Greptile on this head. Greptile's check run on
# the head commit is the signal; without one, its summary comment counts once it
# carries a score and was updated after the head commit. A check run that
# completed without reviewing (skipped, cancelled, timed out, stale) is
# `failed`: the gate keeps waiting so the agent can re-trigger, and the wait
# timeout still bounds it.
__dx_reviewers_greptile_state() {
  local gs_session="$1" gs_pr="$2" gs_head="$3" gs_triggered="$4" check comments commit
  check=$(__dx_reviewers_greptile_check "$gs_session" "$gs_head") || return 1
  case "${check%%	*}" in
    completed)
      case "${check#*	}" in
        skipped|cancelled|timed_out|stale) printf 'failed\t%s\n' "${check#*	}" ;;
        *) printf 'done\t%s\n' "${check#*	}" ;;
      esac
      return 0
      ;;
    "") ;;
    *)
      printf 'in-progress\t%s\n' "${check%%	*}"
      return 0
      ;;
  esac
  comments=$(__dx_reviewers_gh "$gs_session" api \
    "repos/{owner}/{repo}/issues/${gs_pr}/comments?per_page=100") || return 1
  commit=$(__dx_reviewers_gh "$gs_session" api "repos/{owner}/{repo}/commits/${gs_head}") \
    || return 1
  DX_REVIEWERS_COMMENTS="$comments" DX_REVIEWERS_COMMIT="$commit" \
  DX_REVIEWERS_TRIGGERED="$gs_triggered" python3 - <<'PY'
import json
import os
import re

LOGINS = {"greptile-apps[bot]", "greptile-apps-staging[bot]"}
try:
    comments = json.loads(os.environ["DX_REVIEWERS_COMMENTS"])
    commit = json.loads(os.environ["DX_REVIEWERS_COMMIT"])
except ValueError:
    raise SystemExit(1)
if not isinstance(comments, list) or not isinstance(commit, dict):
    raise SystemExit(1)
committed = str(((commit.get("commit") or {}).get("committer") or {}).get("date") or "")
best = None
for comment in comments:
    if not isinstance(comment, dict):
        continue
    if str((comment.get("user") or {}).get("login", "")).lower() not in LOGINS:
        continue
    body = str(comment.get("body") or "")
    if not re.search(r"\b[0-5]/5\b|Reviews \(\d+\)", body):
        continue
    updated = str(comment.get("updated_at") or comment.get("created_at") or "")
    # ISO-8601 UTC strings from the same API compare correctly as text.
    if committed and updated >= committed and (best is None or updated > best[0]):
        best = (updated, body)
if best:
    score = re.search(r"\b([0-5]/5)\b", best[1])
    print("done\t%s" % (score.group(1) if score else "reviewed"))
elif os.environ.get("DX_REVIEWERS_TRIGGERED", "-") not in ("", "-"):
    print("in-progress\ttriggered")
else:
    print("not-started\t-")
PY
}

# dx_reviewer_gate <session_id> <repo_dir> <pr> [head_sha]
# Whether every `wait: yes` adapter reviewer has finished on the PR's head.
# Prints one line per waited reviewer:
#   handle<TAB>adapter<TAB>state<TAB>elapsed_seconds<TAB>detail
# state: done | in-progress | not-started | failed | timeout | unavailable |
# unknown. Only done, timeout and unavailable stop the wait.
# Each reviewer's clock starts at its first trigger on this head, else at the
# first time the gate saw it there, and runs for
# dx_complete_reviewer_wait_minutes; a later trigger on the same head does not
# restart it. A timeout is final for that head and is a reported gap, never a
# clean review.
# rc 0: every waited reviewer is done, timed out or unavailable, or none waits.
# rc 1: at least one is still waiting. rc 2: bad arguments. rc 3: the PR head
# could not be read, so nothing could be measured; treat it like a CI query
# error (an idle cycle), not as waiting.
# With no waited rows it calls nothing, so existing configs see no change.
dx_reviewer_gate() {
  [[ $# -ge 3 && $# -le 4 ]] || return 2
  local gate_session="$1" gate_repo="$2" gate_pr="$3" gate_head="${4:-}"
  local rows handle row_type wait_value adapter key existing now limit
  local started triggered state result detail elapsed waiting=0
  [[ "$gate_pr" =~ ^[0-9]+$ ]] || return 2
  dx_session_id_valid "$gate_session" || return 2
  rows=$(dx_reviewers_rows "$gate_repo" 2>/dev/null \
    | awk -F'\t' '$3 == "yes" && $4 != "generic"') || rows=""
  [[ -n "$rows" ]] || return 0
  if [[ -z "$gate_head" ]]; then
    gate_head=$(cd "$gate_repo" && __dx_reviewers_head "$gate_session" "$gate_pr") || gate_head=""
  fi
  limit=$(dx_complete_reviewer_wait_minutes "$gate_session") || limit=20
  limit=$((10#$limit * 60))
  now=$(__dx_reviewers_now)
  while IFS=$'\t' read -r handle row_type wait_value adapter; do
    [[ -n "$handle" ]] || continue
    if [[ -z "$gate_head" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$handle" "$adapter" unknown 0 "head unavailable"
      waiting=3
      continue
    fi
    key=$(__dx_reviewers_key "$handle")
    [[ "$adapter" != "copilot" ]] || key=copilot
    started="-"
    triggered="-"
    state=""
    if existing=$(__dx_reviewers_ledger_get "$gate_session" reviewer "$key" "$gate_head"); then
      IFS=$'\t' read -r started triggered state <<EOF
$existing
EOF
    fi
    [[ "$started" != "-" ]] || started="$now"
    elapsed=$((now - started))
    case "$state" in
      done|timeout|unavailable)
        printf '%s\t%s\t%s\t%s\t%s\n' "$handle" "$adapter" "$state" "$elapsed" "recorded"
        continue
        ;;
    esac
    if [[ "$adapter" == "copilot" ]]; then
      result=$(cd "$gate_repo" && __dx_reviewers_copilot_state "$gate_session" \
        "$gate_pr" "$gate_head" "$triggered") || result=""
    else
      result=$(cd "$gate_repo" && __dx_reviewers_greptile_state "$gate_session" \
        "$gate_pr" "$gate_head" "$triggered") || result=""
    fi
    state="${result%%	*}"
    detail="${result#*	}"
    if [[ -z "$result" ]]; then
      state=unknown
      detail="GitHub query failed"
    fi
    if [[ "$state" != "done" && "$elapsed" -ge "$limit" ]]; then
      detail="no review after $((limit / 60))m (last state: ${state})"
      state=timeout
    fi
    case "$state" in
      done|timeout) ;;
      *) waiting=1 ;;
    esac
    __dx_reviewers_ledger_put "$gate_session" reviewer "$key" "$gate_head" \
      "$started" "$triggered" "$state" || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$handle" "$adapter" "$state" "$elapsed" "$detail"
  done <<EOF
$rows
EOF
  return "$waiting"
}

# --- CI readiness and cycle accounting ---------------------------------------------

# dx_complete_ci_state <session_id> <repo_dir> <pr>
# Line 1: green | pending | stalled | failed | error. Then one
# `name<TAB>bucket<TAB>link` line per check that has not passed.
# With `readiness_check` declared in the `## Resources` block of .dex/dex.md,
# only that check counts, and a missing check is pending: this covers
# repositories without required status checks, where a half-registered check
# list can otherwise look green. Without it, CI is green when every check
# passed or was skipped. Greptile's check runs are left out when a Greptile
# reviewer row exists, because dx_reviewer_gate owns them.
# CI that stays pending on one head longer than dx_complete_pending_minutes is
# `stalled`, which Phase 6 treats as an idle cycle instead of a waiting one.
# rc: 0 green, 1 pending, 3 failed, 4 stalled, 2 error.
dx_complete_ci_state() {
  [[ $# -eq 3 ]] || return 2
  local ci_session="$1" ci_repo="$2" ci_pr="$3" checks_json checks_err ci_rc=0
  local readiness="" greptile_row=0 parsed ci_state ci_head existing started now limit
  [[ "$ci_pr" =~ ^[0-9]+$ ]] || return 2
  checks_err=$(mktemp "${TMPDIR:-/tmp}/dex-ci-state.XXXXXX") || return 2
  checks_json=$(cd "$ci_repo" && __dx_reviewers_gh "$ci_session" pr checks "$ci_pr" \
    --json name,bucket,link 2>"$checks_err") || ci_rc=$?
  # gh exits 8 while checks are pending and 1 when one failed, printing the
  # JSON either way; only a non-JSON failure is an error.
  if [[ "$ci_rc" -ne 0 && "$ci_rc" -ne 8 && "$checks_json" != \[* ]]; then
    if grep -qi 'no checks reported' "$checks_err" 2>/dev/null; then
      checks_json='[]'
    else
      rm -f "$checks_err"
      printf '%s\n' error
      return 2
    fi
  fi
  rm -f "$checks_err"
  readiness=$(dx_project_contract_values "$ci_repo" Resources readiness_check 2>/dev/null \
    | head -n 1) || readiness=""
  if dx_reviewers_rows "$ci_repo" 2>/dev/null | awk -F'\t' '$4 == "greptile"' | grep -q .; then
    greptile_row=1
  fi
  parsed=$(DX_REVIEWERS_CHECKS="${checks_json:-[]}" DX_REVIEWERS_READINESS="$readiness" \
    DX_REVIEWERS_SKIP_GREPTILE="$greptile_row" python3 - <<'PY'
import json
import os
import re

try:
    checks = json.loads(os.environ["DX_REVIEWERS_CHECKS"] or "[]")
except ValueError:
    raise SystemExit(1)
if not isinstance(checks, list):
    raise SystemExit(1)
checks = [c for c in checks if isinstance(c, dict)]
if os.environ.get("DX_REVIEWERS_SKIP_GREPTILE") == "1":
    checks = [c for c in checks if not re.search("greptile", str(c.get("name", "")), re.I)]
readiness = os.environ.get("DX_REVIEWERS_READINESS", "").strip()
if readiness:
    named = [c for c in checks if str(c.get("name", "")) == readiness]
    if not named:
        state = "pending"
        checks = [{"name": readiness, "bucket": "missing", "link": ""}]
    else:
        checks = named
        buckets = {str(c.get("bucket", "")) for c in named}
        if buckets & {"fail", "cancel"}:
            state = "failed"
        elif buckets <= {"pass"}:
            state = "green"
        else:
            state = "pending"
else:
    buckets = {str(c.get("bucket", "")) for c in checks}
    if buckets & {"fail", "cancel"}:
        state = "failed"
    elif buckets <= {"pass", "skipping"}:
        state = "green"
    else:
        state = "pending"
print(state)
for c in checks:
    if str(c.get("bucket", "")) not in ("pass", "skipping"):
        print("%s\t%s\t%s" % (c.get("name", ""), c.get("bucket", ""), c.get("link", "") or "-"))
PY
  ) || { printf '%s\n' error; return 2; }
  ci_state=$(printf '%s\n' "$parsed" | head -n 1)
  if [[ "$ci_state" != "pending" ]] && dx_session_id_valid "$ci_session"; then
    __dx_reviewers_ledger_settle_ci "$ci_session" "$ci_state" || true
  fi
  if [[ "$ci_state" == "pending" ]] && dx_session_id_valid "$ci_session" \
    && ci_head=$(cd "$ci_repo" && __dx_reviewers_head "$ci_session" "$ci_pr"); then
    now=$(__dx_reviewers_now)
    started="$now"
    # The clock runs while CI stays pending. A rerun after CI settled on this
    # head (a failed job re-run, say) starts it again.
    if existing=$(__dx_reviewers_ledger_get "$ci_session" ci - "$ci_head"); then
      case "$(printf '%s\n' "$existing" | cut -f3)" in
        pending|stalled) started=$(printf '%s\n' "$existing" | cut -f1) ;;
      esac
    fi
    limit=$(dx_complete_pending_minutes "$ci_session") || limit=120
    if (( now - started >= 10#$limit * 60 )); then
      ci_state=stalled
    fi
    __dx_reviewers_ledger_put "$ci_session" ci - "$ci_head" "$started" - "$ci_state" || true
    parsed="${ci_state}${parsed#pending}"
  fi
  printf '%s\n' "$parsed"
  case "$ci_state" in
    green) return 0 ;;
    pending) return 1 ;;
    failed) return 3 ;;
    stalled) return 4 ;;
  esac
  return 2
}

# dx_complete_record_cycle <session_id> <progress|waiting|idle>
# Record a Phase 6 cycle outcome in dx_complete_state_file (`cycle:epoch`, the
# format hooks/phase-loop.sh reads) and print the new value.
#   progress - commits were pushed; the cycle counter advances.
#   waiting  - CI is pending or a waited reviewer is still working; the counter
#              stays put, so waiting never spends the idle budget.
#   idle     - nothing moved; the counter advances, and rc 5 says the idle
#              budget (dx_complete_max_cycles) is spent.
dx_complete_record_cycle() {
  [[ $# -eq 2 ]] || return 2
  local rc_session="$1" rc_outcome="$2" state_file current cycle=0 now max tmp
  dx_session_id_valid "$rc_session" || return 2
  case "$rc_outcome" in
    progress|waiting|idle) ;;
    *) return 2 ;;
  esac
  state_file=$(dx_complete_state_file "$rc_session")
  current=$(cat "$state_file" 2>/dev/null) || current=""
  if [[ "$current" =~ ^([0-9]+):[0-9]+$ ]]; then
    cycle="${current%%:*}"
  fi
  [[ "$rc_outcome" == "waiting" ]] || cycle=$((10#$cycle + 1))
  now=$(__dx_reviewers_now)
  mkdir -p "$(dirname "$state_file")" || return 1
  tmp=$(mktemp "${state_file}.XXXXXX") || return 1
  printf '%s:%s\n' "$cycle" "$now" > "$tmp" && mv -f "$tmp" "$state_file" \
    || { rm -f "$tmp"; return 1; }
  printf '%s:%s\n' "$cycle" "$now"
  if [[ "$rc_outcome" == "idle" ]]; then
    max=$(dx_complete_max_cycles "$rc_session") || max=3
    [[ "$cycle" -lt "$max" ]] || return 5
  fi
  return 0
}
