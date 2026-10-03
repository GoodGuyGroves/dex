#!/usr/bin/env bash
set -euo pipefail

# `dx review status` and the dx_review_status line the Phase 3 wait shows.
#
# It summarises one session's current review loop from that run's journal and
# the Phase 3 busy record. A person reads it mid-wave, and the Stop hook puts
# its --line form in front of them, so it has to name the right wave, budget,
# clean streak and stage, and stay quiet rather than wrong when the journal is
# missing or damaged.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-status.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck disable=SC1091
source "$ROOT/tests/helpers.sh"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

SID="repo-review-status-test-main"
OTHER="repo-review-status-test-other"
export DEX_SESSION_ID="$SID"
unset DEX_RUN_ID

event() {
  printf '{"run_id":"%s","type":"%s","data":%s}\n' "$1" "$2" "$3"
}

status() {
  bash "$ROOT/bin/review.sh" status "$@" > "$TMP_DIR/out" 2> "$TMP_DIR/err"
}

# No run mapped for the session: a plain answer, exit 0, nothing on stderr.
status
assert_contains "No review pass recorded." "$TMP_DIR/out"
[[ ! -s "$TMP_DIR/err" ]] || assert_at $LINENO
status --line
[[ ! -s "$TMP_DIR/out" ]] || assert_at $LINENO
status --json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["current"] is None and d["waves"] == [] and d["tier"] == "", d' "$TMP_DIR/out"

# A loop two waves in: one fix wave and one clean wave, with a malformed line
# and a non-dict line the reader must skip.
RUN="run_20261003T000000Z_1_aaaaaaaa"
dx_run_write_for_session "$SID" "$RUN"
mkdir -p "$DX_RUN_ROOT/$RUN"
{
  event "$RUN" run.started '{}'
  event "$RUN" review.tier.selected '{"tier":"complex","profile":"thorough","required_clean":3,"max_waves":9}'
  event "$RUN" review.pass.started '{"iteration":1,"max_waves":9,"clean_before":0,"required_clean":3,"tier":"complex","profile":"thorough"}'
  event "$RUN" review.pass.finished '{"iteration":1,"result_kind":"findings_fixed","findings":2,"clean_after":0,"duration_seconds":605}'
  printf '%s\n' '{not json' '[1,2]'
  event "$RUN" review.wave_budget.changed '{"max_waves":6,"iteration":2}'
  event "$RUN" review.pass.started '{"iteration":2,"max_waves":6,"clean_before":0,"required_clean":3,"tier":"complex","profile":"thorough"}'
  event "$RUN" review.pass.finished '{"iteration":2,"result_kind":"notes","findings":1,"clean_after":1,"duration_seconds":842}'
} > "$DX_RUN_ROOT/$RUN/events.jsonl"

# Between waves: the last finished wave, with the budget the override set.
status --line
assert_eq "Wave 2/6 · CLEAN (notes) · 1/3 clean · 14m 2s" "$(cat "$TMP_DIR/out")" "finished line"
status
assert_contains "Review tier: complex (thorough) · 3 consecutive clean waves required · budget 6 waves" "$TMP_DIR/out"
assert_contains "Wave 1/6 · FIXED 2 · 0/3 clean · 10m 5s" "$TMP_DIR/out"
assert_contains "Wave 2/6 · CLEAN (notes) · 1/3 clean · 14m 2s" "$TMP_DIR/out"
assert_contains "No wave is running." "$TMP_DIR/out"

# Wave 3 running: the busy record's label carries the live stage.
event "$RUN" review.pass.started '{"iteration":3,"max_waves":6,"clean_before":1,"required_clean":3,"tier":"complex","profile":"thorough"}' \
  >> "$DX_RUN_ROOT/$RUN/events.jsonl"
BUSY_TOKEN="$(dx_phase_busy_begin "$SID" 3 "Wave 3 · scouting · 1/3 clean" 900)"
[[ -n "$BUSY_TOKEN" ]] || assert_at $LINENO
status --line
LINE="$(cat "$TMP_DIR/out")"
[[ "$LINE" == "Wave 3/6 · complex · scouting · 1/3 clean · "*"s/15m 0s" ]] || {
  printf 'running line was: %s\n' "$LINE" >&2
  assert_at $LINENO
}
status
assert_contains "Running: Wave 3/6 · complex · scouting · 1/3 clean · " "$TMP_DIR/out"
assert_not_contains "No wave is running." "$TMP_DIR/out"
status --json
python3 - "$TMP_DIR/out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["tier"] == "complex" and d["max_waves"] == 6 and d["required_clean"] == 3, d
cur = d["current"]
assert cur["wave"] == 3 and cur["stage"] == "scouting" and cur["clean"] == 1, cur
assert cur["timeout_seconds"] == 900 and cur["elapsed_seconds"] >= 0, cur
assert [w["verdict"] for w in d["waves"]] == ["FIXED 2", "CLEAN (notes)"], d["waves"]
PY

# A label without the usual shape still reports the stage as written.
dx_phase_busy_update "$SID" 3 "$BUSY_TOKEN" "preparing context" || assert_at $LINENO
status --line
LINE="$(cat "$TMP_DIR/out")"
[[ "$LINE" == "Wave 3/6 · complex · preparing context · 1/3 clean · "* ]] || {
  printf 'free-form label line was: %s\n' "$LINE" >&2
  assert_at $LINENO
}

# --finished-wave holds a between-waves line back until that wave's result is
# journalled; the review loop clears the busy record first.
rm -f "$(dx_phase_busy_file "$SID" 3)"
assert_eq "" "$(dx_review_status "$SID" line 3)" "wave 3 result not journalled yet"
assert_eq "Wave 2/6 · CLEAN (notes) · 1/3 clean · 14m 2s" "$(dx_review_status "$SID" line 2)" "wave 2 result"
BUSY_TOKEN="$(dx_phase_busy_begin "$SID" 3 "Wave 3 · verifying · 1/3 clean" 900)"

# Journal text reaches the pane through the hook's systemMessage, so control
# characters, terminal escapes included, never pass through.
python3 "$ROOT/scripts/review_status.py" --format line --busy-epoch 1 --now 61 \
  --busy-label "$(printf 'Wave 4 · \033]0;owned\007red\033[0m · 0/1 clean')" > "$TMP_DIR/out"
python3 -c 'import sys; t=open(sys.argv[1],"rb").read(); assert t.startswith(b"Wave 4 ") and b"red" in t, t; assert not any(b < 0x20 and b != 0x0a for b in t) and b"\x7f" not in t, t' "$TMP_DIR/out" \
  || assert_at $LINENO

# A damaged busy record is ignored, never trusted.
printf 'garbage\n' > "$(dx_phase_busy_file "$SID" 3)"
status --line
assert_eq "Wave 2/6 · CLEAN (notes) · 1/3 clean · 14m 2s" "$(cat "$TMP_DIR/out")" "damaged busy record"
rm -f "$(dx_phase_busy_file "$SID" 3)"

# The loop reaches its gate; the line says so.
{
  event "$RUN" review.pass.finished '{"iteration":3,"result_kind":"clean","findings":0,"clean_after":2,"duration_seconds":59}'
  event "$RUN" review.completed '{"reason":"clean_gate_reached","tier":"complex","max_waves":6,"required_clean":3}'
} >> "$DX_RUN_ROOT/$RUN/events.jsonl"
status --line
assert_eq "Wave 3/6 · CLEAN · 2/3 clean · 59s · clean gate reached" "$(cat "$TMP_DIR/out")" "completed line"
status
assert_contains "Outcome: completed (clean_gate_reached)" "$TMP_DIR/out"

# A later selection after the completed loop opens a new loop, which owns the
# summary; the finished loop's waves are not carried into it.
event "$RUN" review.tier.selected '{"tier":"normal","profile":"standard","required_clean":2,"max_waves":6}' \
  >> "$DX_RUN_ROOT/$RUN/events.jsonl"
status
assert_contains "Review tier: normal (standard)" "$TMP_DIR/out"
assert_not_contains "Wave 1/6" "$TMP_DIR/out"

# --session reads that session's own run, even when DEX_RUN_ID names ours.
OTHER_RUN="run_20261003T000000Z_2_bbbbbbbb"
dx_run_write_for_session "$OTHER" "$OTHER_RUN"
mkdir -p "$DX_RUN_ROOT/$OTHER_RUN"
event "$OTHER_RUN" review.tier.selected '{"tier":"small","profile":"light","required_clean":1,"max_waves":3}' \
  > "$DX_RUN_ROOT/$OTHER_RUN/events.jsonl"
DEX_RUN_ID="$RUN" status --session "$OTHER"
assert_contains "Review tier: small (light)" "$TMP_DIR/out"

# Bad arguments fail with a usage error and exit 2.
if status --session 'not a session'; then assert_at $LINENO; fi
assert_contains "Not a valid Dex session id" "$TMP_DIR/err"
if status --bogus; then assert_at $LINENO; fi
assert_contains "Unknown review status option" "$TMP_DIR/err"
if status --session; then assert_at $LINENO; fi
assert_contains "--session needs a session id" "$TMP_DIR/err"

# An unreadable journal path degrades to no summary, not an error.
rm -rf "${DX_RUN_ROOT:?}/$RUN"
status --line
[[ ! -s "$TMP_DIR/out" && ! -s "$TMP_DIR/err" ]] || assert_at $LINENO

echo "review-status-test: ok"
