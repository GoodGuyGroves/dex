#!/usr/bin/env bash
# A launch title names the Claude session "<ticket> <title>"; without one the
# name is the workspace name, and a lifecycle keeps its first name on resume.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-title.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export ZDOTDIR="$HOME"
export DEX_DIR="$ROOT"
export DEX_HOME="$TMP_DIR/dex-home"
export CLAUDE_CONFIG_DIR="$TMP_DIR/claude"
export CODEX_HOME="$TMP_DIR/codex"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_SYNC=0
export DEX_FACTORY_SYNC=false
unset DEX_SESSION_TITLE
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT" "$TMP_DIR/bin"

# The launcher checks for Claude before calling the stubbed provider.
printf '#!/usr/bin/env bash\nexit 97\n' > "$TMP_DIR/bin/claude"
chmod +x "$TMP_DIR/bin/claude"
export PATH="$TMP_DIR/bin:$PATH"

# --- Resolver and sanitiser, under both shells that source lib/ -------------

cat > "$TMP_DIR/resolver.sh" <<'SH'
set -eu
source "$DEX_DIR/lib/common.sh"
expect() {
  if [[ "$2" != "$3" ]]; then
    printf '%s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
    exit 1
  fi
}
resolve() { dx_claude_session_name_resolve "$@"; }

# Without a title, names are exactly today's.
expect worktree-untitled "ticket-17" "$(resolve s-wt worktree ticket-17 0)"
expect inplace-untitled "inplace-ticket-17" "$(resolve s-ip in-place ticket-17 0)"
expect blank-title "ticket-17" "$(resolve s-wt worktree ticket-17 0 $' \t\n ')"

# A title is prefixed with the recorded ticket ID, verbatim apart from
# control characters.
dx_meta_write s-gh "ticket_id=17"
expect bare-ticket "17 Fix login" "$(resolve s-gh worktree ticket-17 0 "Fix login")"
dx_meta_write s-eng "ticket_id=ENG-1234"
expect prefixed-ticket "ENG-1234 Fix login" \
  "$(resolve s-eng in-place ticket-eng-1234 0 "Fix login")"
expect verbatim "17 [15] Café \"quotes\" #3 a/b" \
  "$(resolve s-gh worktree ticket-17 0 "[15] Café \"quotes\" #3 a/b")"
expect control-chars "17 Line one Line two tab bell" \
  "$(resolve s-gh worktree ticket-17 0 $'  Line one\nLine two\ttab\a\033bell  ')"

# A free-form task has no ticket ID, so the workspace name stands in.
expect freeform "task-fix-login Fix login" \
  "$(resolve s-task worktree task-fix-login 0 "Fix login")"

# A resumed lifecycle with no stored name was created under the legacy name.
expect resume-legacy "ticket-17" "$(resolve s-gh worktree ticket-17 1 "Fix login")"

# A stored name wins over any later title, fresh or resumed.
dx_meta_write s-gh "claude_session_name=17 First title"
expect stored-fresh "17 First title" "$(resolve s-gh worktree ticket-17 0 "Other")"
expect stored-resume "17 First title" "$(resolve s-gh worktree ticket-17 1 "")"
SH
for test_shell in bash zsh; do
  "$test_shell" "$TMP_DIR/resolver.sh" \
    || fail "session name resolver cases failed under $test_shell"
  rm -f "$DX_STATE_DIR"/*.meta
done

# --- Lifecycle launch: -n, metadata, and the legacy --resume fallback --------

TEST_REPO="$TMP_DIR/repo"
git init -q -b main "$TEST_REPO"
git -C "$TEST_REPO" config user.email test@example.com
git -C "$TEST_REPO" config user.name Test
git -C "$TEST_REPO" commit --allow-empty -qm init
cd "$TEST_REPO"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

# run_lifecycle <session-id> <record-prefix> — launch once, record the provider
# argv and the system context, then pause so the launcher returns.
run_lifecycle() {
  local session_id="$1" record="$2"
  set +e
  TEST_SESSION_ID="$session_id" TEST_RECORD="$record" TEST_REPO="$TEST_REPO" \
    DX_AGENT_OVERRIDE=claude zsh -fc '
      source "$DEX_DIR/dx.sh"
      __dx_refresh_provider
      unalias __dx_claude 2>/dev/null
      unfunction __dx_claude 2>/dev/null
      __dx_claude() {
        local arg prev=""
        printf "%s\n" "$@" > "$TEST_RECORD.args"
        for arg in "$@"; do
          [[ "$prev" == --append-system-prompt-file ]] && cp "$arg" "$TEST_RECORD.context"
          prev="$arg"
        done
        dx_lifecycle_atomic_write "$(dx_paused_file "$TEST_SESSION_ID")" paused
      }
      __dx_run_phases_inline ticket-17 "$TEST_REPO" main 0 \
        "$(dx_state_file "$TEST_SESSION_ID")" "$(dx_times_file "$TEST_SESSION_ID")" \
        "dx 17" worktree "$TEST_SESSION_ID" "17"
    ' > "$record.out" 2>&1
  set -e
  [[ -s "$record.args" ]] || { cat "$record.out" >&2; fail "provider was not launched ($record)"; }
}

# A titled fresh launch names the session and records the name.
SID=session-title-titled
dx_meta_write "$SID" "ticket_id=17"
DEX_SESSION_TITLE=$'Fix the\tlogin bug' run_lifecycle "$SID" "$TMP_DIR/titled-fresh"
assert_contains "Fix the login bug" "$TMP_DIR/titled-fresh.args"
grep -Fxq -- "-n" "$TMP_DIR/titled-fresh.args" || assert_at $LINENO
grep -Fxq "17 Fix the login bug" "$TMP_DIR/titled-fresh.args" || assert_at $LINENO
[[ "$(dx_meta_read "$SID" claude_session_name)" == "17 Fix the login bug" ]] || assert_at $LINENO
# The messaging prompt names the same session.
assert_contains 'This session is named "17 Fix the login bug"' "$TMP_DIR/titled-fresh.context"

# After a crash with no captured conversation ID, resume uses the stored name,
# even when the next launch passes a different title or none.
rm -f "$(dx_paused_file "$SID")"
: > "$(dx_times_file "$SID")"
DEX_SESSION_TITLE="Something else" run_lifecycle "$SID" "$TMP_DIR/titled-resume"
grep -Fxq -- "--resume" "$TMP_DIR/titled-resume.args" || assert_at $LINENO
grep -Fxq "17 Fix the login bug" "$TMP_DIR/titled-resume.args" || assert_at $LINENO
assert_not_contains "Something else" "$TMP_DIR/titled-resume.args"

# Without a title, the launch name is exactly the workspace name.
SID=session-title-untitled
dx_meta_write "$SID" "ticket_id=17"
run_lifecycle "$SID" "$TMP_DIR/untitled"
grep -Fxq "ticket-17" "$TMP_DIR/untitled.args" || assert_at $LINENO
[[ "$(dx_meta_read "$SID" claude_session_name)" == "ticket-17" ]] || assert_at $LINENO

# --- Title inputs: dx --title and the run spec's source.title ---------------

# dx_title_probe <dx-args...> — run dx up to workspace setup, which reports the
# title the lifecycle would launch with and stops.
dx_title_probe() {
  DX_AGENT_OVERRIDE=claude zsh -fc '
    source "$DEX_DIR/dx.sh"
    unfunction __dx_setup_worktree 2>/dev/null
    __dx_setup_worktree() { printf "title=[%s]\n" "${DEX_SESSION_TITLE:-}"; return 1; }
    dx "$@"
  ' _ "$@" 2>&1 || true
}
dx_title_probe --title "Flag title" 17 > "$TMP_DIR/flag.out"
assert_contains "title=[Flag title]" "$TMP_DIR/flag.out"
dx_title_probe --title=Joined 17 > "$TMP_DIR/flag-joined.out"
assert_contains "title=[Joined]" "$TMP_DIR/flag-joined.out"
# The flag beats an inherited value.
DEX_SESSION_TITLE=Inherited dx_title_probe --title "Flag title" 17 > "$TMP_DIR/flag-env.out"
assert_contains "title=[Flag title]" "$TMP_DIR/flag-env.out"
DEX_SESSION_TITLE=Inherited dx_title_probe 17 > "$TMP_DIR/env.out"
assert_contains "title=[Inherited]" "$TMP_DIR/env.out"
# A missing or empty value is a usage error and starts nothing.
for bad in "--title" "--title=" "--title --model"; do
  # shellcheck disable=SC2086  # split the flag forms on purpose
  dx_title_probe $bad 17 > "$TMP_DIR/flag-bad.out"
  assert_contains "Usage: dx --title" "$TMP_DIR/flag-bad.out"
  assert_not_contains "title=[" "$TMP_DIR/flag-bad.out"
done

# Run spec: source.title becomes DEX_SESSION_TITLE and beats an inherited value.
cat > "$TMP_DIR/spec.json" <<'JSON'
{"source": {"title": "Spec title"}, "harness": {"name": "claude"}}
JSON
cat > "$TMP_DIR/spec-untitled.json" <<'JSON'
{"source": {"id": "42"}, "harness": {"name": "claude"}}
JSON
spec_title() {
  DEX_SESSION_TITLE="$2" zsh -fc '
    source "$DEX_DIR/dx.sh"
    __dx_run_spec_apply_env "$1" >/dev/null || exit 1
    printf "%s" "${DEX_SESSION_TITLE:-}"
  ' _ "$1"
}
[[ "$(spec_title "$TMP_DIR/spec.json" "Inherited")" == "Spec title" ]] || assert_at $LINENO
[[ "$(spec_title "$TMP_DIR/spec-untitled.json" "Inherited")" == "Inherited" ]] || assert_at $LINENO
[[ -z "$(spec_title "$TMP_DIR/spec-untitled.json" "")" ]] || assert_at $LINENO

echo "session-title-test: ok"
