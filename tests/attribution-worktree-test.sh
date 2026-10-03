#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-attribution-worktree.XXXXXX")"

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
mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

new_repo_with_worktree() {
  local name="$1"
  local repo="$TMP_DIR/$name-main"
  local linked="$TMP_DIR/$name-linked"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email dex@example.test
  git -C "$repo" config user.name "Dex Test"
  printf 'initial\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "chore: initialize fixture"
  git -C "$repo" branch linked
  git -C "$repo" worktree add -q "$linked" linked
  printf '%s\t%s\n' "$repo" "$linked"
}

write_logging_hook() {
  local path="$1" label="$2"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' '$label' >> "\$DEX_TEST_HOOK_LOG"
HOOK
  chmod +x "$path"
}

commit_change() {
  local repo="$1" content="$2" message="$3" log="$4"
  printf '%s\n' "$content" >> "$repo/file.txt"
  git -C "$repo" add file.txt
  DEX_TEST_HOOK_LOG="$log" git -C "$repo" commit -q -m "$message"
}

# An install from the main checkout writes --local config, which every linked
# worktree shares by design: one stable proxy in the common Git directory.
# Relative original hook paths are resolved at hook runtime against whichever
# worktree is committing. (An install started in a linked worktree never writes
# that shared config; see the cases after this block.)
IFS=$'\t' read -r local_main local_linked < <(new_repo_with_worktree local-scope)
write_logging_hook "$local_main/.githooks/commit-msg" main-relative
write_logging_hook "$local_linked/.githooks/commit-msg" linked-relative
git -C "$local_main" config --local core.hooksPath .githooks
dx_install_repo_attribution "$local_main" > "$TMP_DIR/local-install.out"
local_proxy=$(dx_attribution_hook_dir "$local_main")
[[ "$(git -C "$local_main" config --local --get core.hooksPath)" == "$local_proxy" ]] || assert_at $LINENO
[[ "$(git -C "$local_linked" config --local --get core.hooksPath)" == "$local_proxy" ]] || assert_at $LINENO

# The shared proxy set must also discover hooks added only in a linked
# worktree after the main checkout was initialized.
write_logging_hook "$local_linked/.githooks/pre-commit" linked-only-pre-commit
commit_change "$local_linked" linked "feat: linked worktree change" "$TMP_DIR/local-hooks.log"
commit_change "$local_main" main "feat: main worktree change" "$TMP_DIR/local-hooks.log"
[[ "$(grep -c '^linked-only-pre-commit$' "$TMP_DIR/local-hooks.log")" -eq 1 ]] || assert_at $LINENO
[[ "$(grep -c '^linked-relative$' "$TMP_DIR/local-hooks.log")" -eq 1 ]] || assert_at $LINENO
[[ "$(grep -c '^main-relative$' "$TMP_DIR/local-hooks.log")" -eq 1 ]] || assert_at $LINENO

dx_uninstall_repo_attribution "$local_main" > "$TMP_DIR/local-uninstall.out"
[[ "$(git -C "$local_main" config --local --get core.hooksPath)" == ".githooks" ]] || assert_at $LINENO
[[ "$(git -C "$local_linked" config --local --get core.hooksPath)" == ".githooks" ]] || assert_at $LINENO
[[ ! -e "$local_proxy" ]] || assert_at $LINENO

# An install started in a linked worktree without extensions.worktreeConfig
# would have to write the shared config, so it writes nothing and says how to
# enable hooks instead.
IFS=$'\t' read -r shared_main shared_linked < <(new_repo_with_worktree linked-skip)
dx_install_repo_attribution "$shared_linked" > "$TMP_DIR/linked-skip.out" 2>&1
[[ -z "$(git -C "$shared_main" config --local --get core.hooksPath || true)" ]] || assert_at $LINENO
[[ -z "$(git -C "$shared_linked" config --get core.hooksPath || true)" ]] || assert_at $LINENO
shared_common=$(git -C "$shared_linked" rev-parse --path-format=absolute --git-common-dir)
assert_no_file "$shared_common/dex-attribution-state.json"
[[ ! -e "$shared_common/dex-hooks" ]] || assert_at $LINENO
assert_contains "git config extensions.worktreeConfig true && dx sync" "$TMP_DIR/linked-skip.out"
# A user's own shared value is left exactly as it was.
git -C "$shared_main" config --local core.hooksPath .githooks
dx_install_repo_attribution "$shared_linked" > /dev/null 2>&1
[[ "$(git -C "$shared_main" config --local --get core.hooksPath)" == ".githooks" ]] || assert_at $LINENO
assert_no_file "$shared_common/dex-attribution-state.json"

# With extensions.worktreeConfig on and no worktree value yet, the linked
# install uses --worktree and the main checkout is untouched.
IFS=$'\t' read -r wtconf_main wtconf_linked < <(new_repo_with_worktree linked-worktree-config)
git -C "$wtconf_main" config extensions.worktreeConfig true
dx_install_repo_attribution "$wtconf_linked" > "$TMP_DIR/linked-wtconf.out"
wtconf_proxy=$(dx_attribution_hook_dir "$wtconf_linked")
[[ "$(git -C "$wtconf_linked" config --worktree --get core.hooksPath)" == "$wtconf_proxy" ]] || assert_at $LINENO
[[ -z "$(git -C "$wtconf_main" config --get core.hooksPath || true)" ]] || assert_at $LINENO
[[ -z "$(git -C "$wtconf_main" config --local --get core.hooksPath || true)" ]] || assert_at $LINENO
commit_change "$wtconf_linked" linked "feat: linked worktree config" "$TMP_DIR/wtconf-hooks.log"
assert_contains "Co-Authored-By: Dex <noreply@dexcode.ai>" <(git -C "$wtconf_linked" log -1 --format=%B)
dx_uninstall_repo_attribution "$wtconf_linked" > /dev/null
[[ -z "$(git -C "$wtconf_linked" config --get core.hooksPath || true)" ]] || assert_at $LINENO

# `dx init` run inside a linked worktree takes the same path.
IFS=$'\t' read -r init_main init_linked < <(new_repo_with_worktree linked-init)
(
  cd "$init_linked"
  DEX_SKIP_TOOL_BOOTSTRAP=1 DX_RTK_ENABLED=0 DEXCODE_SYNC=0 DEXCODE_CONTEXT_SYNC=0 \
    bash "$ROOT/bin/init.sh" --skip-analysis --skip-config
) > "$TMP_DIR/linked-init.out" 2>&1 || { cat "$TMP_DIR/linked-init.out" >&2; assert_at $LINENO; }
[[ -z "$(git -C "$init_main" config --local --get core.hooksPath || true)" ]] || assert_at $LINENO
assert_contains "Not installing Dex attribution hooks from a linked worktree" "$TMP_DIR/linked-init.out"

# A linked worktree of a repository the main checkout already set up keeps
# using that install and does not rewrite the shared value.
IFS=$'\t' read -r inherit_main inherit_linked < <(new_repo_with_worktree linked-inherit)
dx_install_repo_attribution "$inherit_main" > /dev/null
inherit_proxy=$(dx_attribution_hook_dir "$inherit_main")
inherit_config_before=$(git -C "$inherit_main" config --local --list)
dx_install_repo_attribution "$inherit_linked" > "$TMP_DIR/linked-inherit.out"
assert_contains "installed from the main checkout" "$TMP_DIR/linked-inherit.out"
[[ "$(git -C "$inherit_linked" config --get core.hooksPath)" == "$inherit_proxy" ]] || assert_at $LINENO
[[ "$(git -C "$inherit_main" config --local --list)" == "$inherit_config_before" ]] || assert_at $LINENO

# dx uninit gives core.hooksPath back only while it still points at Dex's
# proxy. A value the user set afterwards is theirs.
IFS=$'\t' read -r changed_main _changed_linked < <(new_repo_with_worktree changed-after)
dx_install_repo_attribution "$changed_main" > /dev/null
git -C "$changed_main" config --local core.hooksPath .user-hooks
dx_uninstall_repo_attribution "$changed_main" > "$TMP_DIR/changed-uninstall.out"
[[ "$(git -C "$changed_main" config --local --get core.hooksPath)" == ".user-hooks" ]] || assert_at $LINENO

# Worktree-scoped config needs independent receipts and restoration values. A
# linked worktree uninit must not remove or restore the main worktree's proxy.
IFS=$'\t' read -r scoped_main scoped_linked < <(new_repo_with_worktree worktree-scope)
git -C "$scoped_main" config extensions.worktreeConfig true
git -C "$scoped_main" config --worktree core.hooksPath .main-hooks
git -C "$scoped_linked" config --worktree core.hooksPath .linked-hooks
write_logging_hook "$scoped_main/.main-hooks/commit-msg" main-scoped
write_logging_hook "$scoped_linked/.linked-hooks/commit-msg" linked-scoped

dx_install_repo_attribution "$scoped_main" > "$TMP_DIR/scoped-main-install.out"
main_state=$(dx_attribution_state_file "$scoped_main")
main_proxy=$(dx_attribution_hook_dir "$scoped_main")
dx_install_repo_attribution "$scoped_linked" > "$TMP_DIR/scoped-linked-install.out"
linked_state=$(dx_attribution_state_file "$scoped_linked")
linked_proxy=$(dx_attribution_hook_dir "$scoped_linked")
[[ "$main_state" != "$linked_state" ]] || assert_at $LINENO
[[ "$main_proxy" != "$linked_proxy" ]] || assert_at $LINENO

commit_change "$scoped_linked" linked "fix: linked scoped hook" "$TMP_DIR/scoped-hooks.log"
commit_change "$scoped_main" main "fix: main scoped hook" "$TMP_DIR/scoped-hooks.log"
[[ "$(grep -c '^linked-scoped$' "$TMP_DIR/scoped-hooks.log")" -eq 1 ]] || assert_at $LINENO
[[ "$(grep -c '^main-scoped$' "$TMP_DIR/scoped-hooks.log")" -eq 1 ]] || assert_at $LINENO

dx_uninstall_repo_attribution "$scoped_linked" > "$TMP_DIR/scoped-linked-uninstall.out"
[[ "$(git -C "$scoped_linked" config --worktree --get core.hooksPath)" == ".linked-hooks" ]] || assert_at $LINENO
[[ "$(git -C "$scoped_main" config --worktree --get core.hooksPath)" == "$main_proxy" ]] || assert_at $LINENO
[[ -f "$main_state" ]] || assert_at $LINENO
[[ -d "$main_proxy" ]] || assert_at $LINENO

dx_uninstall_repo_attribution "$scoped_main" > "$TMP_DIR/scoped-main-uninstall.out"
[[ "$(git -C "$scoped_main" config --worktree --get core.hooksPath)" == ".main-hooks" ]] || assert_at $LINENO
[[ ! -e "$main_state" ]] || assert_at $LINENO
[[ ! -e "$main_proxy" ]] || assert_at $LINENO

# Existing state determines uninstall ownership even if the user later unsets
# the worktree hook override. The linked uninstall must not select local state.
IFS=$'\t' read -r unset_main unset_linked < <(new_repo_with_worktree unset-scope)
mkdir -p "$unset_main/.local-hooks" "$unset_linked/.linked-hooks"
git -C "$unset_main" config --local core.hooksPath .local-hooks
dx_install_attribution_hook "$unset_main" > "$TMP_DIR/unset-local-install.out"
unset_local_state=$(dx_attribution_state_file "$unset_main")
unset_local_proxy=$(dx_attribution_hook_dir "$unset_main")

git -C "$unset_main" config extensions.worktreeConfig true
git -C "$unset_linked" config --worktree core.hooksPath .linked-hooks
dx_install_attribution_hook "$unset_linked" > "$TMP_DIR/unset-linked-install.out"
unset_worktree_state=$(dx_attribution_state_file "$unset_linked")
unset_worktree_proxy=$(dx_attribution_hook_dir "$unset_linked")
git -C "$unset_linked" config --worktree --unset-all core.hooksPath

[[ "$(dx_attribution_state_file "$unset_linked")" == "$unset_worktree_state" ]] || assert_at $LINENO
dx_uninstall_repo_attribution "$unset_linked" > "$TMP_DIR/unset-linked-uninstall.out"
[[ ! -e "$unset_worktree_state" ]] || assert_at $LINENO
[[ ! -e "$unset_worktree_proxy" ]] || assert_at $LINENO
[[ -f "$unset_local_state" ]] || assert_at $LINENO
[[ -d "$unset_local_proxy" ]] || assert_at $LINENO
[[ "$(git -C "$unset_linked" config --get core.hooksPath)" == "$unset_local_proxy" ]] || assert_at $LINENO

dx_uninstall_repo_attribution "$unset_main" > "$TMP_DIR/unset-local-uninstall.out"
[[ "$(git -C "$unset_main" config --local --get core.hooksPath)" == ".local-hooks" ]] || assert_at $LINENO

# A newer manual worktree override must not hide an older local Dex receipt
# from uninit. Removing that override later must not resurrect Dex's proxy.
IFS=$'\t' read -r masked_main masked_linked < <(new_repo_with_worktree masked-scope)
mkdir -p "$masked_main/.local-hooks" "$masked_linked/.manual-hooks"
git -C "$masked_main" config --local core.hooksPath .local-hooks
dx_install_attribution_hook "$masked_main" > "$TMP_DIR/masked-local-install.out"
masked_local_state=$(dx_attribution_state_file "$masked_main")
masked_local_proxy=$(dx_attribution_hook_dir "$masked_main")

git -C "$masked_main" config extensions.worktreeConfig true
git -C "$masked_linked" config --worktree core.hooksPath .manual-hooks
[[ "$(dx_attribution_state_file "$masked_linked")" == "$masked_local_state" ]] || assert_at $LINENO
dx_uninstall_repo_attribution "$masked_linked" > "$TMP_DIR/masked-uninstall.out"
[[ ! -e "$masked_local_state" ]] || assert_at $LINENO
[[ ! -e "$masked_local_proxy" ]] || assert_at $LINENO
[[ "$(git -C "$masked_linked" config --get core.hooksPath)" == ".manual-hooks" ]] || assert_at $LINENO
git -C "$masked_linked" config --worktree --unset-all core.hooksPath
[[ "$(git -C "$masked_linked" config --get core.hooksPath)" == ".local-hooks" ]] || assert_at $LINENO

printf 'attribution worktree tests passed\n'
