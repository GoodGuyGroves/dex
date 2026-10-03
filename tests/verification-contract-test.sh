#!/usr/bin/env bash
# dex-test-lane: fast
# `## Verification` in .dex/dex.md: the Phase 4 lanes a project declares and
# the known baseline failures Phase 4 reports instead of fixing in the unit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-verification-contract-test.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

# block_has <text> <needle> / block_lacks <text> <needle>: string checks.
block_has() {
  [[ "$1" == *"$2"* ]] && return 0
  printf 'missing expected text: %s\nin:\n%s\n' "$2" "$1" >&2
  exit 1
}
block_lacks() {
  [[ "$1" != *"$2"* ]] && return 0
  printf 'unexpected text: %s\nin:\n%s\n' "$2" "$1" >&2
  exit 1
}

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.dex"
repo_git() { git -C "$REPO" -c user.email=dex@example.test -c user.name="Dex Test" "$@"; }
repo_git init -q -b main
printf 'base\n' > "$REPO/app.txt"
repo_git add app.txt
repo_git commit -q -m base
BASE_SHA=$(repo_git rev-parse HEAD)
repo_git switch -q -c other
printf 'other\n' > "$REPO/other.txt"
repo_git add other.txt
repo_git commit -q -m other
OTHER_SHA=$(repo_git rev-parse HEAD)
repo_git switch -q main
repo_git switch -q -c unit
printf 'unit\n' > "$REPO/app.txt"
repo_git commit -q -am unit

# write_contract <block-body> — .dex/dex.md with a ## Verification block.
write_contract() {
  {
    printf '# Project\n\n## Verification\n\n```yaml\n%s\n```\n\n## Rules\n\nNone.\n' "$1"
  } > "$REPO/.dex/dex.md"
}

# ── absent ───────────────────────────────────────────────────────────────
printf '# Project\n\n## Rules\n\nNone.\n' > "$REPO/.dex/dex.md"
rc=0
dx_project_verification_value "$REPO" lanes > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "no section: lanes absent"
rc=0
dx_verification_known_failures "$REPO" > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "no section: known failures absent"
assert_eq "" "$(dx_verification_phase_block "$REPO")" "no section: no Phase 4 block"
assert_eq "" "$(dx_verification_phase_block "")" "no repository: no Phase 4 block"
rc=0
dx_project_verification_value "$REPO" lane > /dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "a misspelled key is a Dex bug"

# ── lanes ────────────────────────────────────────────────────────────────
write_contract $'lanes:\n  - bash tests/check.sh\n  - DX_TEST_LANES=fast bash tests/run-all.sh'
assert_eq $'bash tests/check.sh\nDX_TEST_LANES=fast bash tests/run-all.sh' \
  "$(dx_project_verification_value "$REPO" lanes)" "declared lanes"
block=$(dx_verification_phase_block "$REPO")
block_has "$block" "Phase 4 verification policy (.dex/dex.md § Verification):"
block_has "$block" "required Phase 4 gate (receipt name full-gate)"
block_has "$block" "    bash tests/check.sh"
block_has "$block" "    DX_TEST_LANES=fast bash tests/run-all.sh"
block_lacks "$block" "baseline"

# ── malformed block ──────────────────────────────────────────────────────
write_contract $'lanes:\n  nested: mapping'
rc=0
dx_project_verification_value "$REPO" lanes > /dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "malformed block"
block_has "$(dx_verification_phase_block "$REPO")" "could not be read; use the default Phase 4 gate"

# ── known failures: path checks ──────────────────────────────────────────
for declared in "/etc/hosts" "../outside.tsv" "missing.tsv" ".dex"; do
  write_contract "known_failures: $declared"
  rc=0
  dx_verification_known_failures "$REPO" > /dev/null 2> "$TMP_DIR/path.err" || rc=$?
  assert_eq 2 "$rc" "known_failures path rejected: $declared"
  [[ -s "$TMP_DIR/path.err" ]] || fail "no reason given for $declared"
  # The Phase 4 block carries the reason too, so a typo is visible there.
  block=$(dx_verification_phase_block "$REPO")
  block_has "$block" "could not be read"
  block_has "$block" "$(head -n 1 "$TMP_DIR/path.err")"
done
printf 'x\tmain\t#1\n' > "$TMP_DIR/outside.tsv"
ln -s "$TMP_DIR/outside.tsv" "$REPO/.dex/linked-failures.tsv"
write_contract "known_failures: .dex/linked-failures.tsv"
rc=0
dx_verification_known_failures "$REPO" > /dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "a symlink out of the repository is rejected"

# ── known failures: base filtering ───────────────────────────────────────
{
  printf '# test-id\tbase-ref\tissue-ref\n\n'
  printf 'review-loop\t%s\tdex#1\n' "$BASE_SHA"
  printf 'ccr-routing\tmain\tdex#1\n'
  printf 'other-branch-only\t%s\tdex#9\n' "$OTHER_SHA"
  printf 'unknown-base\tno-such-ref\tdex#9\n'
  printf 'too-few-fields\tmain\n'
  # An empty field is malformed, not a reason to shift the others left.
  printf 'empty-base\t\tmain\tdex#2\n'
  printf 'crlf-line\tmain\tdex#3\r\n'
} > "$REPO/.dex/known-failures.tsv"
write_contract $'lanes:\n  - bash tests/check.sh\nknown_failures: .dex/known-failures.tsv'
failures=$(dx_verification_known_failures "$REPO" 2> "$TMP_DIR/failures.err")
assert_eq "$(printf 'review-loop\t%s\tdex#1\nccr-routing\tmain\tdex#1\ncrlf-line\tmain\tdex#3' "$BASE_SHA")" \
  "$failures" "entries whose base HEAD contains"
block_has "$(cat "$TMP_DIR/failures.err")" "skipping malformed known_failures line for too-few-fields"
block_has "$(cat "$TMP_DIR/failures.err")" "skipping malformed known_failures line for empty-base"
block=$(dx_verification_phase_block "$REPO")
block_has "$block" "Report each one you hit as baseline (<issue-ref>) and do not fix it in this unit:"
block_has "$block" "    review-loop (base $BASE_SHA, dex#1)"
block_has "$block" "    ccr-routing (base main, dex#1)"
block_lacks "$block" "other-branch-only"
block_lacks "$block" "    unknown-base (base"
# A base ref that does not resolve is likely a typo, so the block says so.
block_has "$(cat "$TMP_DIR/failures.err")" "known_failures line for unknown-base: base ref no-such-ref does not resolve"
block_has "$block" "known_failures line for unknown-base: base ref no-such-ref does not resolve"
block_has "$block" "skipping malformed known_failures line for too-few-fields"

# A file whose every entry is filtered out leaves nothing to say: no block,
# not a bare header.
printf 'other-branch-only\t%s\tdex#9\n' "$OTHER_SHA" > "$REPO/.dex/no-applicable.tsv"
write_contract "known_failures: .dex/no-applicable.tsv"
assert_eq "" "$(dx_verification_phase_block "$REPO")" "no applicable entry: no Phase 4 block"

# Known failures alone still make a block; lanes stay the default gate.
write_contract "known_failures: .dex/known-failures.tsv"
block=$(dx_verification_phase_block "$REPO" 2>/dev/null)
block_has "$block" "ccr-routing (base main, dex#1)"
block_lacks "$block" "receipt name full-gate"

# ── the hook hands the block to Phase 4 ─────────────────────────────────
[[ "$(grep -c 'dx_verification_phase_block' "$ROOT/hooks/phase-loop.sh")" -ge 3 ]] \
  || fail 'phase-loop.sh does not add the verification block to both handoffs and the audit'

printf 'verification-contract-test: ok\n'
