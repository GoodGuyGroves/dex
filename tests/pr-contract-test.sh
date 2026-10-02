#!/usr/bin/env bash
set -euo pipefail

# The `## Pull Requests` project contract: the declared PR template and the
# path-based label rules Phase 5 applies. Templates fall back rather than block,
# a malformed rule set applies nothing, and a project that declares nothing gets
# no gh call at all.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-pr-contract-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export DEX_HOME="$TMP_DIR/dex-home"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CODEX_HOME="$HOME/.codex"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
mkdir -p "$HOME"
git config --file "$GIT_CONFIG_GLOBAL" user.name "Dex Test"
git config --file "$GIT_CONFIG_GLOBAL" user.email "dex-test@example.com"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
export DEX_DIR="$ROOT"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

# A stub gh: records each call, answers `pr view --json baseRefName` from
# GH_STUB_BASE, and fails `pr edit --add-label` for the label in GH_STUB_FAIL.
STUB_BIN="$TMP_DIR/bin"
GH_LOG="$TMP_DIR/gh.log"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [[ "$1 $2" == "pr view" ]]; then
  [[ -n "${GH_STUB_BASE:-}" ]] || exit 1
  printf '%s\n' "$GH_STUB_BASE"
  exit 0
fi
if [[ "$1 $2" == "pr edit" ]]; then
  [[ -n "${GH_STUB_FAIL:-}" && "$*" == *"--add-label ${GH_STUB_FAIL}"* ]] && exit 1
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH" GH_LOG

# write_contract <repo> <block body>
write_contract() {
  mkdir -p "$1/.dex"
  {
    printf '# Project\n\n## Pull Requests\n\n```yaml\n'
    printf '%s\n' "$2"
    printf '```\n\n## Project Structure\n\nNothing here.\n'
  } > "$1/.dex/dex.md"
}

new_repo() {
  local repo="$TMP_DIR/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" commit -q --allow-empty -m "chore: root"
  printf '%s\n' "$repo"
}

# ── Declared template ─────────────────────────────────────────────────────
REPO=$(new_repo template)
mkdir -p "$REPO/docs"
printf '## Summary\n\n## Risk\n' > "$REPO/docs/pr-template.md"

RC=0
dx_project_pr_template "$REPO" >/dev/null 2>&1 || RC=$?
[[ "$RC" == 1 ]] || assert_at $LINENO   # no dex.md at all

write_contract "$REPO" 'labels_when: [".github/** => skip-ci"]'
RC=0
dx_project_pr_template "$REPO" >/dev/null 2>&1 || RC=$?
[[ "$RC" == 1 ]] || assert_at $LINENO   # section without the key

write_contract "$REPO" 'template: docs/pr-template.md'
OUT=$(dx_project_pr_template "$REPO")
REAL_REPO=$(cd "$REPO" && pwd -P)
[[ "$OUT" == "$REAL_REPO/docs/pr-template.md" ]] || assert_at $LINENO

# expect_template_rejected <value> <stderr needle>
expect_template_rejected() {
  local rc=0
  write_contract "$REPO" "template: $1"
  dx_project_pr_template "$REPO" >"$TMP_DIR/t.out" 2>"$TMP_DIR/t.err" || rc=$?
  [[ "$rc" == 2 ]] || { printf 'template %s: rc %s\n' "$1" "$rc" >&2; return 1; }
  [[ ! -s "$TMP_DIR/t.out" ]] || return 1
  assert_contains "$2" "$TMP_DIR/t.err"
}

expect_template_rejected "/etc/hosts" "relative"
mkdir -p "$TMP_DIR/outside"
printf '## Elsewhere\n' > "$TMP_DIR/outside/template.md"
expect_template_rejected "../outside/template.md" "outside the repository"
ln -s "$TMP_DIR/outside/template.md" "$REPO/docs/escape.md"
expect_template_rejected "docs/escape.md" "outside the repository"
expect_template_rejected "docs" "not a regular"
: > "$REPO/docs/empty.md"
expect_template_rejected "docs/empty.md" "empty"
expect_template_rejected "docs/missing.md" "not a regular"

# A symlink that stays inside the repository is fine.
ln -s pr-template.md "$REPO/docs/alias.md"
write_contract "$REPO" 'template: docs/alias.md'
OUT=$(dx_project_pr_template "$REPO")
[[ "$OUT" == "$REAL_REPO/docs/pr-template.md" ]] || assert_at $LINENO

# A malformed block is reported as such.
mkdir -p "$REPO/.dex"
printf '## Pull Requests\n\n```yaml\ntemplate:\n  nested: x\n```\n' > "$REPO/.dex/dex.md"
RC=0
dx_project_pr_template "$REPO" >/dev/null 2>"$TMP_DIR/t.err" || RC=$?
[[ "$RC" == 2 ]] || assert_at $LINENO
assert_contains "not a flat mapping" "$TMP_DIR/t.err"

# ── Label rules ───────────────────────────────────────────────────────────
RULES=$(new_repo rules)

RC=0
dx_project_pr_label_rules "$RULES" >/dev/null 2>&1 || RC=$?
[[ "$RC" == 1 ]] || assert_at $LINENO   # nothing declared

write_contract "$RULES" 'labels_when:
  - ".github/** => skip-ci"
  - "  docs/**   =>   documentation  "'
assert_eq ".github/**	skip-ci
docs/**	documentation" "$(dx_project_pr_label_rules "$RULES")" "block list, trimmed sides"

write_contract "$RULES" 'labels_when: [".github/** => skip-ci", "**/*.md => docs => extra"]'
assert_eq ".github/**	skip-ci
**/*.md	docs => extra" "$(dx_project_pr_label_rules "$RULES")" "inline list, split on the first arrow"

# expect_rules_rejected <block body> <stderr needle>
expect_rules_rejected() {
  local rc=0
  write_contract "$RULES" "$1"
  dx_project_pr_label_rules "$RULES" >"$TMP_DIR/r.out" 2>"$TMP_DIR/r.err" || rc=$?
  [[ "$rc" == 2 ]] || { printf 'rules %s: rc %s\n' "$1" "$rc" >&2; return 1; }
  [[ ! -s "$TMP_DIR/r.out" ]] || return 1
  assert_contains "$2" "$TMP_DIR/r.err"
}

expect_rules_rejected 'labels_when: [".github/** => skip-ci", "docs/** documentation"]' "docs/** documentation"
expect_rules_rejected 'labels_when: ["docs/** => "]' "empty"
expect_rules_rejected 'labels_when: [" => docs"]' "empty"
# A block item keeps its comma (an inline list would already have split it).
expect_rules_rejected 'labels_when:
  - "docs/** => bug,help wanted"' "comma"
printf '## Pull Requests\n\n```yaml\nlabels_when:\n  rules: x\n```\n' > "$RULES/.dex/dex.md"
RC=0
dx_project_pr_label_rules "$RULES" >/dev/null 2>"$TMP_DIR/r.err" || RC=$?
[[ "$RC" == 2 ]] || assert_at $LINENO
assert_contains "not a flat mapping" "$TMP_DIR/r.err"

# ── Matching paths ────────────────────────────────────────────────────────
write_contract "$RULES" 'labels_when:
  - ".github/** => skip-ci"
  - "**/*.md => documentation"
  - ".github/workflows/* => skip-ci"
  - "Docs/** => case-sensitive"'

labels_for() {
  printf '%s\0' "$@" | dx_pr_labels_for_paths "$RULES"
}
assert_eq "skip-ci" "$(labels_for .github/workflows/ci.yml)" "nested path, duplicate removed"
assert_eq "documentation" "$(labels_for README.md)" "leading **/ matches at the top level"
assert_eq "skip-ci
documentation" "$(labels_for docs/guide.md .github/x.yml)" "rule order, not path order"
assert_eq "" "$(labels_for lib/git.sh docs/guide.txt)" "no match prints nothing"
assert_eq "" "$(labels_for docs/a.txt)" "matching is case-sensitive"
assert_eq "case-sensitive" "$(labels_for Docs/a.txt)" "exact case matches"
assert_eq "" "$(printf '' | dx_pr_labels_for_paths "$RULES")" "no paths, no labels"
SPACED=$(printf 'dir with space/x.md\0' | dx_pr_labels_for_paths "$RULES")
assert_eq "documentation" "$SPACED" "NUL-separated paths may contain spaces"

RC=0
printf 'README.md\0' | dx_pr_labels_for_paths "$(new_repo bare-rules)" >/dev/null 2>&1 || RC=$?
[[ "$RC" == 1 ]] || assert_at $LINENO   # no rules declared

# ── Changed files and applying labels ─────────────────────────────────────
ORIGIN="$TMP_DIR/origin.git"
git init -q --bare "$ORIGIN"
WORK=$(new_repo work)
git -C "$WORK" remote add origin "$ORIGIN"
printf 'base\n' > "$WORK/README.md"
mkdir -p "$WORK/.github"
printf 'name: ci\n' > "$WORK/.github/ci.yml"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "chore: base"
git -C "$WORK" push -q origin main
git -C "$WORK" checkout -q -b parent
printf 'parent\n' > "$WORK/parent.txt"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "feat: parent"
git -C "$WORK" push -q origin parent
git -C "$WORK" checkout -q -b child
git -C "$WORK" mv .github/ci.yml moved-ci.yml
printf 'child\n' > "$WORK/child.md"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "feat: child"
git -C "$WORK" fetch -q origin

changed_list() {
  dx_pr_changed_files "$WORK" "$@" | tr '\0' '\n' | sort | tr '\n' ' '
}
# A stacked PR diffs against its own base, and a rename keeps its old path.
: > "$GH_LOG"
assert_eq ".github/ci.yml child.md moved-ci.yml " \
  "$(GH_STUB_BASE=parent changed_list 7)" "stacked PR uses the PR's base"
assert_contains "pr view 7 --json baseRefName" "$GH_LOG"
# Without a PR the default branch is the base.
assert_eq ".github/ci.yml child.md moved-ci.yml parent.txt " \
  "$(changed_list)" "default-branch fallback"
# gh that cannot answer falls back too.
assert_eq ".github/ci.yml child.md moved-ci.yml parent.txt " \
  "$(GH_STUB_BASE='' changed_list 7)" "gh failure falls back to the default branch"
# A base name that looks like an option is not handed to git.
assert_eq ".github/ci.yml child.md moved-ci.yml parent.txt " \
  "$(GH_STUB_BASE='--upload-pack=x' changed_list 7)" "option-like base is ignored"

# No .dex/dex.md, then a dex.md without `## Pull Requests`: nothing is
# computed and gh is never called.
: > "$GH_LOG"
dx_pr_apply_label_rules 7 "$WORK" >/dev/null 2>&1 || assert_at $LINENO
[[ ! -s "$GH_LOG" ]] || assert_at $LINENO
mkdir -p "$WORK/.dex"
printf '# Project\n\n## Resources\n\n```yaml\nfull_gate: local\n```\n' > "$WORK/.dex/dex.md"
dx_pr_apply_label_rules 7 "$WORK" >/dev/null 2>&1 || assert_at $LINENO
[[ ! -s "$GH_LOG" ]] || assert_at $LINENO
RC=0
dx_project_pr_template "$WORK" >/dev/null 2>&1 || RC=$?
[[ "$RC" == 1 ]] || assert_at $LINENO

write_contract "$WORK" 'labels_when:
  - ".github/** => skip-ci"
  - "**/*.md => documentation"
  - "lib/** => core"'
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "chore: contract"

: > "$GH_LOG"
GH_STUB_BASE=parent dx_pr_apply_label_rules 7 "$WORK" >"$TMP_DIR/apply.out" 2>&1 \
  || assert_at $LINENO
assert_contains "pr edit 7 --add-label skip-ci" "$GH_LOG"
assert_contains "pr edit 7 --add-label documentation" "$GH_LOG"
assert_not_contains "--add-label core" "$GH_LOG"
assert_contains "skip-ci" "$TMP_DIR/apply.out"

# One label the repository lacks warns; the others are still applied.
: > "$GH_LOG"
RC=0
GH_STUB_BASE=parent GH_STUB_FAIL=skip-ci dx_pr_apply_label_rules 7 "$WORK" \
  >"$TMP_DIR/apply.out" 2>&1 || RC=$?
[[ "$RC" == 1 ]] || assert_at $LINENO
assert_contains "pr edit 7 --add-label documentation" "$GH_LOG"
assert_contains "skip-ci" "$TMP_DIR/apply.out"
assert_contains "[warn]" "$TMP_DIR/apply.out"

# A malformed rule set applies nothing.
write_contract "$WORK" 'labels_when: [".github/** => skip-ci", "oops"]'
: > "$GH_LOG"
RC=0
GH_STUB_BASE=parent dx_pr_apply_label_rules 7 "$WORK" >"$TMP_DIR/apply.out" 2>&1 || RC=$?
[[ "$RC" == 2 ]] || assert_at $LINENO
assert_not_contains "--add-label" "$GH_LOG"
assert_contains "[warn]" "$TMP_DIR/apply.out"

# A missing PR number is a usage error.
RC=0
dx_pr_apply_label_rules "" "$WORK" >/dev/null 2>&1 || RC=$?
[[ "$RC" == 2 ]] || assert_at $LINENO

# ── The generated dex.md example parses ───────────────────────────────────
TEMPLATE_REPO="$TMP_DIR/init-template"
mkdir -p "$TEMPLATE_REPO/.dex"
awk '/^```markdown$/ { inside = 1; next } inside && /^### `\.dex\/rules/ { exit } inside { print }' \
  "$ROOT/prompts/init-analysis.md" > "$TEMPLATE_REPO/.dex/dex.md"
assert_contains "## Pull Requests" "$TEMPLATE_REPO/.dex/dex.md"
RC=0
dx_project_contract_values "$TEMPLATE_REPO" "Pull Requests" labels_when >/dev/null 2>&1 || RC=$?
[[ "$RC" == 0 ]] || assert_at $LINENO
dx_project_pr_label_rules "$TEMPLATE_REPO" >/dev/null || assert_at $LINENO

printf 'PASS: pr-contract-test\n'
