#!/usr/bin/env bash
# dex-test-lane: fast
# deferred_criteria: a sealed criterion the lifecycle branch cannot satisfy
# (for example a check that only exists on the integration branch) is marked
# at the Phase 1 seal with an owner and a reason. Review waves then report it
# as `deferred` instead of blocking every wave. A reviewer cannot defer
# anything the seal did not, and a later rotation cannot add or widen one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-deferred-criteria-test.XXXXXX")"
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
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

OBJECTIVE="Keep review credit honest."
CRITERION="Every requirement has auditable evidence."
INTEGRATION_ONLY="The no-global-writes harness stays green on integration."
VERIFY="Run the focused deferral test."
REASON="The harness exists only on integration; the lead runs it after merge."

# criteria_json [deferred-json] — a criteria payload with two acceptance
# criteria, the second unsatisfiable on this branch.
criteria_json() {
  OBJECTIVE="$OBJECTIVE" CRITERION="$CRITERION" INTEGRATION_ONLY="$INTEGRATION_ONLY" \
  VERIFY="$VERIFY" DEFERRED="${1:-}" python3 - <<'PY'
import json
import os

payload = {
    "version": 1,
    "source": "approved-plan",
    "objectives": [os.environ["OBJECTIVE"]],
    "acceptance_criteria": [os.environ["CRITERION"], os.environ["INTEGRATION_ONLY"]],
    "verification_requirements": [os.environ["VERIFY"]],
}
if os.environ["DEFERRED"]:
    payload["deferred_criteria"] = json.loads(os.environ["DEFERRED"])
print(json.dumps(payload))
PY
}

deferral() { # <criterion> [owner] [reason] [until]
  CRITERION_TEXT="$1" OWNER="${2:-lead}" REASON_TEXT="${3:-$REASON}" UNTIL="${4:-post-merge}" python3 - <<'PY'
import json
import os

print(json.dumps({
    "criterion": os.environ["CRITERION_TEXT"],
    "until": os.environ["UNTIL"],
    "owner": os.environ["OWNER"],
    "reason": os.environ["REASON_TEXT"],
}))
PY
}

SCHEMA_FILE="$TMP_DIR/schema.json"
accepts() { # <label> <payload>
  printf '%s\n' "$2" > "$SCHEMA_FILE"
  dx_review_criteria_valid "$SCHEMA_FILE" || fail "criteria rejected: $1"
}
rejects() { # <label> <payload>
  printf '%s\n' "$2" > "$SCHEMA_FILE"
  if dx_review_criteria_valid "$SCHEMA_FILE"; then
    fail "criteria accepted: $1"
  fi
}

# ── schema ───────────────────────────────────────────────────────────────
ONE="$(deferral "$INTEGRATION_ONLY")"
accepts "no deferred_criteria" "$(criteria_json)"
accepts "an acceptance criterion deferred" "$(criteria_json "[$ONE]")"
accepts "a verification requirement deferred, owner human" \
  "$(criteria_json "[$(deferral "$VERIFY" human)]")"
rejects "an empty deferred list" "$(criteria_json '[]')"
rejects "a deferral that names no sealed criterion" \
  "$(criteria_json "[$(deferral "Some other requirement entirely.")]")"
rejects "an objective deferred" "$(criteria_json "[$(deferral "$OBJECTIVE")]")"
rejects "a near-miss criterion string" "$(criteria_json "[$(deferral "$INTEGRATION_ONLY ")]")"
rejects "the same criterion deferred twice" "$(criteria_json "[$ONE,$ONE]")"
rejects "an unknown owner" "$(criteria_json "[$(deferral "$INTEGRATION_ONLY" agent)]")"
rejects "an until other than post-merge" \
  "$(criteria_json "[$(deferral "$INTEGRATION_ONLY" lead "$REASON" later)]")"
rejects "a short reason" "$(criteria_json "[$(deferral "$INTEGRATION_ONLY" lead "later")]")"
rejects "a placeholder reason" \
  "$(criteria_json "[$(deferral "$INTEGRATION_ONLY" lead "<reason goes here>")]")"
rejects "a multi-line reason" \
  "$(criteria_json "[$(deferral "$INTEGRATION_ONLY" lead $'Runs on integration\nafter the merge.')]")"
rejects "an extra field in a deferral" \
  "$(criteria_json '[{"criterion":"'"$INTEGRATION_ONLY"'","until":"post-merge","owner":"lead","reason":"'"$REASON"'","note":"x"}]')"
rejects "an unknown top-level key" \
  "$(criteria_json | python3 -c 'import json,sys; d=json.load(sys.stdin); d["extra"]=[]; print(json.dumps(d))')"

# A file without the key hashes exactly as before: existing seals stay valid.
printf '%s\n' "$(criteria_json)" > "$SCHEMA_FILE"
expected_hash=$(python3 -c 'import hashlib,json,sys; p=json.load(open(sys.argv[1])); print(hashlib.sha256(json.dumps(p,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()).hexdigest())' "$SCHEMA_FILE")
assert_eq "$expected_hash" "$(dx_review_criteria_hash "$SCHEMA_FILE")" 'hash without deferred_criteria'

# ── evidence: a listed deferral may stand in for met ─────────────────────
REPO="$TMP_DIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name "Dex Test"
git -C "$REPO" config user.email "dex-test@example.com"
printf 'base\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "test: initialize deferral fixture"

SESSION_ID="$(cd "$REPO" && dx_session_id)"
PASS_ID="deferred-pass-1"
CRITERIA_FILE="$(dx_review_criteria_file "$SESSION_ID")"
printf '%s\n' "$(criteria_json "[$ONE]")" > "$CRITERIA_FILE"
CRITERIA_BINDING="$(dx_review_criteria_hash "$CRITERIA_FILE")"
dx_review_approve_criteria "$SESSION_ID" initial "$CRITERIA_BINDING" > /dev/null
SCOPE_FINGERPRINT="$(dx_review_scope_fingerprint "$REPO")"
POLICY_BINDING="$(dx_review_policy_binding 1 2 3)"

CONTEXT_FILE="$TMP_DIR/review-context"
{
  printf '%s\n\n' '## Scope' 'Review the complete fixture scope for this independent pass.'
  printf '%s\n\n' '## Acceptance Criteria' "Criteria binding: ${CRITERIA_BINDING}"
  printf '%s\n\n' '## Deterministic Checks' 'The focused deferral test covers the evidence contract.'
  printf '%s\n' 'Evidence-Ref: criteria:objectives:1:scope-review | analysis | The candidate scope was checked against the approved objective.'
  printf '%s\n' 'Evidence-Ref: criteria:acceptance_criteria:1:format-contract | file | The evidence manifest has one record for every criteria item.'
  printf '%s\n' 'Evidence-Ref: criteria:acceptance_criteria:2:integration-only | analysis | The harness is absent on this branch; the seal defers it to the lead.'
  printf '%s\n' 'Evidence-Ref: criteria:verification_requirements:1:focused-test | test | tests/review-deferred-criteria-test.sh completed successfully.'
  printf '\n%s\n\n' '## Review Coverage' 'Correctness, contracts, tests, security, and architecture were inspected.'
  printf '%s\n' '## Verification' 'The verifier checked the final evidence against the pass inputs.'
} > "$CONTEXT_FILE"
dx_review_context_valid "$CONTEXT_FILE" "$CRITERIA_BINDING"

EVIDENCE_FILE="$TMP_DIR/review-evidence.json"
# write_evidence <second-criterion-outcome> [first-criterion-outcome] [fixes]
write_evidence() {
  SECOND="$1" FIRST="${2:-met}" FIXES="${3:-0}" CRITERIA_FILE="$CRITERIA_FILE" \
  EVIDENCE_FILE="$EVIDENCE_FILE" SCOPE_FINGERPRINT="$SCOPE_FINGERPRINT" \
  CRITERIA_BINDING="$CRITERIA_BINDING" POLICY_BINDING="$POLICY_BINDING" \
  PASS_BINDING="$(dx_review_pass_binding "$PASS_ID" "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING")" \
  python3 - <<'PY'
import hashlib
import json
import os

criteria = json.load(open(os.environ["CRITERIA_FILE"], encoding="utf-8"))
markers = {
    "objectives": ["scope-review"],
    "acceptance_criteria": ["format-contract", "integration-only"],
    "verification_requirements": ["focused-test"],
}
outcomes = {
    "objectives": ["met"],
    "acceptance_criteria": [os.environ["FIRST"], os.environ["SECOND"]],
    "verification_requirements": ["met"],
}
items = {}
for section in ("objectives", "acceptance_criteria", "verification_requirements"):
    items[section] = []
    for index, value in enumerate(criteria[section]):
        canonical = json.dumps([section, index, value], ensure_ascii=False, separators=(",", ":"))
        items[section].append({
            "item_hash": hashlib.sha256(canonical.encode()).hexdigest(),
            "outcome": outcomes[section][index],
            "evidence_refs": [f"criteria:{section}:{index + 1}:{markers[section][index]}"],
        })
fixes = int(os.environ["FIXES"])
payload = {
    "version": 3,
    "scope_fingerprint": os.environ["SCOPE_FINGERPRINT"],
    "criteria_binding": os.environ["CRITERIA_BINDING"],
    "policy_binding": os.environ["POLICY_BINDING"],
    "pass_binding": os.environ["PASS_BINDING"],
    "criteria_evidence": items,
    "deterministic_checks": "pass",
    "coverage": ["correctness", "security", "contracts", "tests", "architecture"],
    "verifier": "pass",
    "verified_findings": fixes,
    "fixes_applied": fixes,
}
with open(os.environ["EVIDENCE_FILE"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
}
evidence_valid() { # <result>
  dx_review_evidence_valid "$EVIDENCE_FILE" "$1" light "$SCOPE_FINGERPRINT" \
    "$CRITERIA_BINDING" "$CRITERIA_FILE" "$PASS_ID" "$POLICY_BINDING" "$CONTEXT_FILE"
}

write_evidence deferred
evidence_valid CLEAN || fail 'CLEAN with a sealed deferral was rejected'
evidence_valid NOTES:1 || fail 'NOTES with a sealed deferral was rejected'
write_evidence met
evidence_valid CLEAN || fail 'CLEAN with the deferred criterion met was rejected'
write_evidence deferred met 1
evidence_valid FINDINGS_FIXED:1 || fail 'FINDINGS_FIXED with a sealed deferral was rejected'
# A reviewer cannot defer what the seal did not.
write_evidence deferred deferred
if evidence_valid CLEAN; then
  fail 'CLEAN accepted a deferral the seal never made'
fi
write_evidence not_met
if evidence_valid CLEAN; then
  fail 'CLEAN accepted a not_met deferred criterion'
fi

# Without deferred_criteria, `deferred` is never a valid outcome.
PLAIN_SESSION="${SESSION_ID}-plain"
PLAIN_FILE="$(dx_review_criteria_file "$PLAIN_SESSION")"
printf '%s\n' "$(criteria_json)" > "$PLAIN_FILE"
PLAIN_BINDING="$(dx_review_criteria_hash "$PLAIN_FILE")"
CRITERIA_FILE="$PLAIN_FILE" CRITERIA_BINDING="$PLAIN_BINDING"
sed -i.bak "s/^Criteria binding: .*/Criteria binding: ${PLAIN_BINDING}/" "$CONTEXT_FILE"
write_evidence deferred
if evidence_valid CLEAN; then
  fail 'CLEAN accepted deferred without any sealed deferral'
fi

# ── the seal: deferrals are fixed at Phase 1 ─────────────────────────────
# seal_session <name> <deferred-json> — a session sealed with those deferrals.
seal_session() {
  local file
  file="$(dx_review_criteria_file "$1")"
  printf '%s\n' "$(criteria_json "$2")" > "$file"
  dx_review_approve_criteria "$1" initial "$(dx_review_criteria_hash "$file")" > /dev/null
}
# rotate <session> <deferred-json> — replace the criteria and reapprove.
rotate() {
  local file previous
  file="$(dx_review_criteria_file "$1")"
  previous="$(dx_review_read_criteria_approval "$1")"
  printf '%s\n' "$(criteria_json "$2")" > "$file"
  dx_review_approve_criteria "$1" reapproved "$previous" "$(dx_review_criteria_hash "$file")" > /dev/null
}
VERIFY_DEFERRAL="$(deferral "$VERIFY")"

seal_session "${SESSION_ID}-add" ""
if rotate "${SESSION_ID}-add" "[$ONE]"; then
  fail 'a rotation added a deferral after the seal'
fi
seal_session "${SESSION_ID}-more" "[$ONE]"
if rotate "${SESSION_ID}-more" "[$ONE,$VERIFY_DEFERRAL]"; then
  fail 'a rotation added a second deferral after the seal'
fi
seal_session "${SESSION_ID}-widen" "[$ONE]"
if rotate "${SESSION_ID}-widen" "[$(deferral "$INTEGRATION_ONLY" human)]"; then
  fail 'a rotation changed the owner of a sealed deferral'
fi
if rotate "${SESSION_ID}-widen" "[$(deferral "$INTEGRATION_ONLY" lead "Any failure here can be ignored by everyone.")]"; then
  fail 'a rotation changed the reason of a sealed deferral'
fi
# Removing a deferral narrows it, which is allowed; it cannot come back later.
seal_session "${SESSION_ID}-remove" "[$ONE]"
rotate "${SESSION_ID}-remove" "" || fail 'a rotation that removed a deferral was rejected'
if rotate "${SESSION_ID}-remove" "[$ONE]"; then
  fail 'a removed deferral came back in a later rotation'
fi
# An unchanged rotation keeps its deferrals.
seal_session "${SESSION_ID}-same" "[$ONE]"
rotate "${SESSION_ID}-same" "[$ONE]" || fail 'an unchanged rotation was rejected'

printf 'review-deferred-criteria-test: ok\n'
