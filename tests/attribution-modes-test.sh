#!/usr/bin/env bash
# dex-test-lane: fast
# The `## Attribution` settings in .dex/dex.md and the trailers each
# attribution mode leaves on a commit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-attribution-modes.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
unset DEX_SESSION_ID DX_ROUTER_SESSION_ID
mkdir -p "$HOME"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

# write_attribution <repo> <yaml line>...
write_attribution() {
  local repo="$1"
  shift
  mkdir -p "$repo/.dex"
  {
    printf '# Project\n\n## Attribution\n\n```yaml\n'
    printf '%s\n' "$@"
    printf '```\n'
  } > "$repo/.dex/dex.md"
}

new_repo() {
  local repo="$TMP_DIR/$1"
  git init -q "$repo"
  git -C "$repo" config user.email "dex@example.test"
  git -C "$repo" config user.name "Dex Test"
  printf '%s\n' "$repo"
}

# commit_with_attribution <repo> — commit a message carrying both Claude's and
# Dex's attribution plus a human co-author, and save the trailers.
commit_with_attribution() {
  local repo="$1"
  printf '%s\n' "$RANDOM" >> "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "feat: change" -m "Generated with [Claude Code](https://claude.com/claude-code)" \
    -m "Co-Authored-By: Alice <alice@example.test>
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  git -C "$repo" log -1 --format=%B > "$repo.message"
}

# Defaults: no file, no section, an empty block.
settings_repo=$(new_repo settings)
[[ "$(dx_attribution_mode "$settings_repo")" == "dex" ]] || assert_at $LINENO
[[ -z "$(dx_attribution_model_trailer "$settings_repo")" ]] || assert_at $LINENO
dx_attribution_hooks_enabled "$settings_repo" || assert_at $LINENO
dx_attribution_pr_template_enabled "$settings_repo" || assert_at $LINENO
! dx_attribution_pr_models_enabled "$settings_repo" || assert_at $LINENO

write_attribution "$settings_repo" "attribution: Both" "model_trailer: AI-Model" \
  "pr_models: yes" "hooks: false" "pr_template: off"
[[ "$(dx_attribution_mode "$settings_repo")" == "both" ]] || assert_at $LINENO
[[ "$(dx_attribution_model_trailer "$settings_repo")" == "AI-Model" ]] || assert_at $LINENO
dx_attribution_pr_models_enabled "$settings_repo" || assert_at $LINENO
! dx_attribution_hooks_enabled "$settings_repo" || assert_at $LINENO
! dx_attribution_pr_template_enabled "$settings_repo" || assert_at $LINENO

# Unknown values warn and fall back to the default for that key only.
write_attribution "$settings_repo" "attribution: everyone" "model_trailer: AI Model" "hooks: maybe" "pr_template: false"
dx_attribution_settings "$settings_repo" > "$TMP_DIR/unknown.out" 2> "$TMP_DIR/unknown.err"
assert_contains "attribution=dex" "$TMP_DIR/unknown.out"
assert_contains "model_trailer=" "$TMP_DIR/unknown.out"
assert_contains "hooks=true" "$TMP_DIR/unknown.out"
assert_contains "pr_template=false" "$TMP_DIR/unknown.out"
assert_contains "unknown attribution mode 'everyone'" "$TMP_DIR/unknown.err"
assert_contains "not a valid Git trailer key" "$TMP_DIR/unknown.err"
assert_contains "'hooks: maybe' is not true or false" "$TMP_DIR/unknown.err"

# A malformed block warns and uses every default.
mkdir -p "$settings_repo/.dex"
cat > "$settings_repo/.dex/dex.md" <<'CONTRACT'
## Attribution

```yaml
attribution:
  nested: none
```
CONTRACT
dx_attribution_settings "$settings_repo" > "$TMP_DIR/malformed.out" 2> "$TMP_DIR/malformed.err"
assert_contains "attribution=dex" "$TMP_DIR/malformed.out"
assert_contains "not a flat mapping" "$TMP_DIR/malformed.err"

# Each mode, through the installed commit-msg hook.
for mode in default dex claude both none; do
  repo=$(new_repo "mode-$mode")
  [[ "$mode" == "default" ]] || write_attribution "$repo" "attribution: $mode"
  dx_install_repo_attribution "$repo" > "$TMP_DIR/install-$mode.out"
  commit_with_attribution "$repo"
  message="$repo.message"
  git -C "$repo" log -1 --format='%(trailers:only,unfold)' > "$repo.trailers"
  # A human co-author is kept in every mode, as a trailer.
  assert_contains "Co-Authored-By: Alice <alice@example.test>" "$repo.trailers"
  case "$mode" in
    default|dex)
      assert_contains "Co-Authored-By: Dex <noreply@dexcode.ai>" "$repo.trailers"
      assert_not_contains "Claude" "$message"
      ;;
    claude)
      assert_not_contains "Co-Authored-By: Dex" "$message"
      assert_contains "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" "$message"
      assert_contains "Generated with [Claude Code]" "$message"
      ;;
    both)
      assert_contains "Co-Authored-By: Dex <noreply@dexcode.ai>" "$repo.trailers"
      assert_contains "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" "$repo.trailers"
      assert_contains "Generated with [Claude Code]" "$message"
      ;;
    none)
      assert_not_contains "Claude" "$message"
      assert_not_contains "Dex" "$message"
      ;;
  esac
done

# `none` also removes a Dex trailer the author typed, and leaves a commit with
# no other trailers with none at all.
none_repo="$TMP_DIR/mode-none"
printf 'x\n' >> "$none_repo/file.txt"
git -C "$none_repo" add file.txt
git -C "$none_repo" commit -q -m "fix: plain" -m "Co-Authored-By: Dex <noreply@dexcode.ai>"
[[ -z "$(git -C "$none_repo" log -1 --format='%(trailers:only)' | tr -d '[:space:]')" ]] || assert_at $LINENO

# The mode is read at commit time, so editing dex.md changes the next commit.
write_attribution "$none_repo" "attribution: dex"
commit_with_attribution "$none_repo"
assert_contains "Co-Authored-By: Dex <noreply@dexcode.ai>" "$none_repo.message"

# Install opt-outs. `dx init` writes them into the dex.md it creates, so the
# install `dx sync` runs later leaves them out too.
optout_repo=$(new_repo optout)
(
  cd "$optout_repo"
  DEX_SKIP_TOOL_BOOTSTRAP=1 DX_RTK_ENABLED=0 DEXCODE_SYNC=0 DEXCODE_CONTEXT_SYNC=0 \
    bash "$ROOT/bin/init.sh" --skip-analysis --skip-config --no-attribution-hooks --no-pr-template
) > "$TMP_DIR/optout-init.out" 2>&1 || { cat "$TMP_DIR/optout-init.out" >&2; assert_at $LINENO; }
[[ -z "$(git -C "$optout_repo" config --get core.hooksPath || true)" ]] || assert_at $LINENO
assert_no_file "$optout_repo/.github/pull_request_template.md"
! dx_attribution_hooks_enabled "$optout_repo" || assert_at $LINENO
! dx_attribution_pr_template_enabled "$optout_repo" || assert_at $LINENO
assert_contains "Dex attribution hooks not installed" "$TMP_DIR/optout-init.out"
dx_install_repo_attribution "$optout_repo" > "$TMP_DIR/optout-sync.out"
[[ -z "$(git -C "$optout_repo" config --get core.hooksPath || true)" ]] || assert_at $LINENO
assert_no_file "$optout_repo/.github/pull_request_template.md"

# A plain `dx init` still installs both, and its dex.md documents the keys.
default_repo=$(new_repo default-init)
(
  cd "$default_repo"
  DEX_SKIP_TOOL_BOOTSTRAP=1 DX_RTK_ENABLED=0 DEXCODE_SYNC=0 DEXCODE_CONTEXT_SYNC=0 \
    bash "$ROOT/bin/init.sh" --skip-analysis --skip-config
) > "$TMP_DIR/default-init.out" 2>&1 || { cat "$TMP_DIR/default-init.out" >&2; assert_at $LINENO; }
[[ -n "$(git -C "$default_repo" config --get core.hooksPath)" ]] || assert_at $LINENO
assert_file "$default_repo/.github/pull_request_template.md"
assert_contains "# model_trailer: AI-Model" "$default_repo/.dex/dex.md"
dx_attribution_hooks_enabled "$default_repo" || assert_at $LINENO

# The per-run switches leave out one part each, without touching dex.md.
switch_repo=$(new_repo switches)
dx_install_repo_attribution "$switch_repo" --no-pr-template > "$TMP_DIR/switch.out"
[[ -n "$(git -C "$switch_repo" config --get core.hooksPath)" ]] || assert_at $LINENO
assert_no_file "$switch_repo/.github/pull_request_template.md"
! dx_install_repo_attribution "$switch_repo" --bogus > /dev/null 2>&1 || assert_at $LINENO

# The installed PR template carries the Dex footer only when the mode adds
# Dex attribution.
for mode in claude none; do
  template_repo=$(new_repo "template-$mode")
  write_attribution "$template_repo" "attribution: $mode"
  dx_install_repo_attribution "$template_repo" --no-hooks > /dev/null
  assert_file "$template_repo/.github/pull_request_template.md"
  assert_not_contains "Generated by Dex" "$template_repo/.github/pull_request_template.md"
done
both_repo=$(new_repo template-both)
write_attribution "$both_repo" "attribution: both"
dx_install_repo_attribution "$both_repo" --no-hooks > /dev/null
assert_contains "Generated by Dex" "$both_repo/.github/pull_request_template.md"

printf 'attribution modes tests passed\n'
