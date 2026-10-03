#!/usr/bin/env bash
# Dex without a shell rc (issue #6):
#   - every shim in shims/ runs with DEX_DIR unset, and the list matches the
#     public functions in dx.sh; dxcd prints its target
#   - a Dex launch puts the shims (and the managed RTK directory) on the
#     session PATH, so in-session `dx run-gate` and `dx control` resolve with
#     no rc, and the caller's PATH is left alone
#   - install checks the rc before writing anything; --no-shell-integration
#     leaves it alone; uninstall leaves a symlinked rc alone
#   - every worktree teardown removes the ~/.claude/projects link older
#     versions made
#   - dx status recognises dx on PATH
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-without-rc-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export CODEX_HOME="$HOME/.codex"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_RTK_ENABLED=0 DEXCODE_SYNC=0
unset DX_RTK_INSTALL_DIR  # tests/run-all.sh sets one; this file wants the default
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"
unset DEX_DIR
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
TOOLS="$TMP_DIR/tools-bin"  # git, python3, zsh and nothing Dex could launch
mkdir -p "$TOOLS"
for tool in git python3 zsh; do
  ln -s "$(command -v "$tool")" "$TOOLS/$tool"
done

# --- shims -------------------------------------------------------------------

public=$(grep -oE '^(dx|dex)[a-z]*\(\)' "$ROOT/dx.sh" | tr -d '()' | sort -u)
shims=$(cd "$ROOT/shims" && ls | sort)
assert_eq "$public" "$shims" "shims/ matches dx.sh's public functions"
[[ $(printf '%s\n' "$shims" | wc -l | tr -d ' ') -eq 12 ]] || assert_at $LINENO
for name in $shims; do
  [[ "$(readlink "$ROOT/shims/$name")" == ../bin/dx-multicall ]] || assert_at $LINENO
  out="$TMP_DIR/shim-$name.out"
  env -u DEX_DIR PATH="$TOOLS:$BASE_PATH" "$ROOT/shims/$name" -h > "$out" 2>&1 \
    || { cat "$out" >&2; assert_at $LINENO; }
  grep -Eq "Usage|Dex — workflow automation" "$out" || { cat "$out" >&2; assert_at $LINENO; }
done

# Found through PATH and through a link elsewhere, DEX_DIR still comes out as
# this checkout.
mkdir -p "$TMP_DIR/linked"
ln -s "$ROOT/shims/dx" "$TMP_DIR/linked/dx"
env -u DEX_DIR PATH="$ROOT/shims:$TOOLS:$BASE_PATH" dx help > "$TMP_DIR/path-dx.out" 2>&1
assert_contains "Dex — workflow automation" "$TMP_DIR/path-dx.out"
env -u DEX_DIR PATH="$TOOLS:$BASE_PATH" "$TMP_DIR/linked/dx" help > "$TMP_DIR/linked-dx.out" 2>&1
assert_contains "Dex — workflow automation" "$TMP_DIR/linked-dx.out"
# shims/ itself linked from a directory that has a bin/ of its own: a logical
# `..` would land there, not in the checkout.
mkdir -p "$TMP_DIR/elsewhere/bin"
ln -s "$ROOT/shims" "$TMP_DIR/elsewhere/shims"
env -u DEX_DIR PATH="$TOOLS:$BASE_PATH" "$TMP_DIR/elsewhere/shims/dx" help > "$TMP_DIR/linked-dir.out" 2>&1 \
  || { cat "$TMP_DIR/linked-dir.out" >&2; assert_at $LINENO; }
assert_contains "Dex — workflow automation" "$TMP_DIR/linked-dir.out"
rc=0
DEX_DIR="$TMP_DIR/no-dex" PATH="$TOOLS:$BASE_PATH" "$ROOT/shims/dx" help 2> "$TMP_DIR/missing.err" || rc=$?
[[ $rc -eq 127 ]] || assert_at $LINENO
assert_contains "has no dx.sh" "$TMP_DIR/missing.err"

repo="$TMP_DIR/repo"
git init -q "$repo"
git -C "$repo" config user.email dex@example.test
git -C "$repo" config user.name "Dex Test"
printf '# repo\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m init
mkdir -p "$repo/.dex/worktrees"
git -C "$repo" worktree add -q "$repo/.dex/worktrees/task-alpha" -b worktree-task-alpha HEAD
dxcd_out=$(cd "$repo" && env -u DEX_DIR PATH="$TOOLS:$BASE_PATH" "$ROOT/shims/dxcd" alpha)
assert_eq "$repo/.dex/worktrees/task-alpha" "$dxcd_out" "dxcd prints the worktree"
dxcd_out=$(cd "$repo/.dex/worktrees/task-alpha" && env -u DEX_DIR PATH="$TOOLS:$BASE_PATH" "$ROOT/shims/dxcd")
assert_eq "$repo" "$dxcd_out" "dxcd with no argument prints the repository root"
rc=0
(cd "$repo" && env -u DEX_DIR PATH="$TOOLS:$BASE_PATH" "$ROOT/shims/dxcd" nothing-like-it) \
  > "$TMP_DIR/dxcd-miss.out" 2> "$TMP_DIR/dxcd-miss.err" || rc=$?
[[ $rc -ne 0 ]] || assert_at $LINENO
# Nothing on stdout, so `d=$(dxcd x) && cd "$d"` never cds anywhere.
[[ ! -s "$TMP_DIR/dxcd-miss.out" ]] || assert_at $LINENO
assert_contains "No worktree matching" "$TMP_DIR/dxcd-miss.err"

# --- the session PATH ----------------------------------------------------------

export DEX_DIR="$ROOT"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

STUB_BIN="$TMP_DIR/stub-bin"
mkdir -p "$STUB_BIN" "$DX_TOOL_DIR/rtk/bin"
# A session asking Dex for things the way skills and hooks do: by name, with no
# rc and no DEX_DIR-sourced functions in its shell.
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PATH" > "$DX_TEST_OUT.path"
dx run-gate -- true > "$DX_TEST_OUT.gate" 2>&1 || echo "gate failed: $?" >> "$DX_TEST_OUT.gate"
dx control --help > "$DX_TEST_OUT.control" 2>&1
STUB
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$PATH" > "$DX_TEST_OUT.path"' > "$STUB_BIN/codex"
chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"

launch_env() {
  export PATH="$STUB_BIN:$TOOLS:$BASE_PATH"
  export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=claude DX_PROVIDER_PROFILE_RESOLVED=claude
  unset DEX_SESSION_ID DEX_LOOP_ACTIVE DEX_LOOP_PHASE
}

(
  launch_env
  export DX_TEST_OUT="$TMP_DIR/claude"
  dx_provider_claude -p "hello"
  # The caller's own PATH is untouched.
  [[ "$PATH" == "$STUB_BIN:$TOOLS:$BASE_PATH" ]] || assert_at $LINENO
)
session_path=$(cat "$TMP_DIR/claude.path")
[[ "$session_path" == "$ROOT/shims:$DX_TOOL_DIR/rtk/bin:$STUB_BIN:"* ]] \
  || { printf 'session PATH: %s\n' "$session_path" >&2; assert_at $LINENO; }
if grep -q 'gate failed' "$TMP_DIR/claude.gate"; then
  cat "$TMP_DIR/claude.gate" >&2
  assert_at $LINENO
fi
assert_contains "Usage: dx control" "$TMP_DIR/claude.control"

# Shims already on PATH are not added twice.
(
  launch_env
  export PATH="$ROOT/shims:$PATH" DX_TEST_OUT="$TMP_DIR/again"
  dx_provider_claude -p "hello"
)
[[ $(tr ':' '\n' < "$TMP_DIR/again.path" | grep -Fxc "$ROOT/shims") -eq 1 ]] || assert_at $LINENO

# zsh exports `declare -x` globally (GLOBAL_EXPORT); the session PATH must
# stay inside the launch there too.
(
  launch_env
  export DX_TEST_OUT="$TMP_DIR/zsh"
  zsh -fc 'source "$DEX_DIR/lib/common.sh"
    before=$PATH
    dx_provider_claude -p hello
    [[ "$PATH" == "$before" ]] || { print -u2 "zsh caller PATH changed: $PATH"; exit 1; }'
)
[[ "$(cat "$TMP_DIR/zsh.path")" == "$ROOT/shims:"* ]] || assert_at $LINENO

# The host budget, host snapshot and prompt-cache lifetime are exported to the
# launched session only. In a zsh that sourced Dex they must not outlive the
# call, or the user's later builds inherit MAKEFLAGS=-j2 and the next launch
# mistakes the stale budget for an operator's choice.
ENV_STUB_BIN="$TMP_DIR/env-stub-bin"
mkdir -p "$ENV_STUB_BIN"
cat > "$ENV_STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
env > "$DX_TEST_OUT.env"
STUB
chmod +x "$ENV_STUB_BIN/claude"
(
  launch_env
  # A test run started from inside a Dex session inherits that launch's values.
  unset DX_TEST_JOBS VITEST_MAX_THREADS VITEST_MAX_FORKS PYTEST_XDIST_AUTO_NUM_WORKERS
  unset CARGO_BUILD_JOBS RUST_TEST_THREADS GOFLAGS MAKEFLAGS
  unset CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH
  unset CLAUDE_CODE_PROMPT_CACHE_TTL DEX_PROMPT_CACHE_TTL
  unset DX_HOST_CPUS DX_HOST_MEM_GB DX_HOST_LOAD1 DX_HOST_ACTIVE_SESSIONS
  unset DX_HOST_ACTIVE_HEAVY DX_HOST_FALLBACKS
  export PATH="$ENV_STUB_BIN:$PATH" DX_TEST_OUT="$TMP_DIR/zsh-env"
  zsh -fc 'source "$DEX_DIR/lib/common.sh"
    DEX_LOOP_ACTIVE=1 dx_provider_claude -p hello
    leaked=()
    for name in CARGO_BUILD_JOBS MAKEFLAGS DX_TEST_JOBS VITEST_MAX_THREADS \
      VITEST_MAX_FORKS CLAUDE_CODE_PROMPT_CACHE_TTL DEX_PROMPT_CACHE_TTL \
      DX_HOST_CPUS DX_HOST_LOAD1 DX_HOST_ACTIVE_SESSIONS; do
      [[ -n "${(P)name+set}" ]] && leaked+=("$name")
    done
    (( ${#leaked} == 0 )) || { print -u2 "zsh caller kept: ${leaked[*]}"; exit 1; }'
) || assert_at $LINENO
for name in CARGO_BUILD_JOBS MAKEFLAGS DX_TEST_JOBS CLAUDE_CODE_PROMPT_CACHE_TTL \
  DEX_PROMPT_CACHE_TTL DX_HOST_CPUS DX_HOST_LOAD1; do
  grep -q "^${name}=" "$TMP_DIR/zsh-env.env" \
    || { printf 'launched session lacks %s\n' "$name" >&2; assert_at $LINENO; }
done

# Codex launches get the same PATH.
(
  launch_env
  export DX_TEST_OUT="$TMP_DIR/codex"
  dx_provider_codex --help
)
[[ "$(cat "$TMP_DIR/codex.path")" == "$ROOT/shims:$DX_TOOL_DIR/rtk/bin:"* ]] || assert_at $LINENO

# --- install and uninstall -----------------------------------------------------

# home_listing <home> — every path and the rc's contents, to prove nothing moved.
home_listing() {
  (cd "$1" && find . -print | sort)
  cat "$1/.zshrc" 2>/dev/null || true
}

run_install() { # <home> [install args...]
  local home="$1"
  shift
  env -u DEX_DIR -u CLAUDE_CONFIG_DIR HOME="$home" CODEX_HOME="$home/.codex" PATH="$TOOLS:$BASE_PATH" \
    DX_TOOL_DIR="$home/tools" DX_RTK_ENABLED=0 SHELL=/bin/zsh \
    bash "$ROOT/bin/install.sh" "$@"
}

# A read-only rc, and an rc linked into a read-only directory (a home-manager
# rc in the Nix store), stop install before it writes anything.
ro_home="$TMP_DIR/ro-home"
mkdir -p "$ro_home"
printf '# user rc\n' > "$ro_home/.zshrc"
chmod 444 "$ro_home/.zshrc"
link_home="$TMP_DIR/link-home"
store="$TMP_DIR/store"
mkdir -p "$link_home" "$store"
printf '# managed rc\n' > "$store/zshrc"
chmod 444 "$store/zshrc"
chmod 555 "$store"
ln -s "$store/zshrc" "$link_home/.zshrc"
# A settings.json that is a directory would pass a bare -w and fail mid-way.
# Install writes settings only for --global-hooks, so that run asks for them.
dir_home="$TMP_DIR/dir-home"
mkdir -p "$dir_home/.claude/settings.json"
printf '# user rc\n' > "$dir_home/.zshrc"
for home in "$ro_home" "$link_home" "$dir_home"; do
  before=$(home_listing "$home")
  rc=0
  install_args=()
  [[ "$home" != "$dir_home" ]] || install_args=(--global-hooks)
  run_install "$home" ${install_args[@]+"${install_args[@]}"} > "$home.out" 2>&1 || rc=$?
  [[ $rc -eq 1 ]] || { cat "$home.out" >&2; assert_at $LINENO; }
  assert_contains "Nothing was installed" "$home.out"
  assert_contains 'export PATH="$DEX_DIR/shims:$PATH"' "$home.out"
  assert_eq "$before" "$(home_listing "$home")" "install wrote nothing into $home"
done
assert_contains ".zshrc is not writable" "$ro_home.out"
assert_contains ".zshrc is not writable" "$link_home.out"
assert_contains "settings.json is not a writable file" "$dir_home.out"

# run_install_past_preflight <home> <out> [args...] — an install that gets past
# the preflight. TOOLS has no node, so the UI-capture bootstrap fails and
# install exits 1 with "Install incomplete"; that, not the preflight's
# "Nothing was installed", is the expected end here.
run_install_past_preflight() {
  local home="$1" out="$2" rc=0
  shift 2
  run_install "$home" "$@" > "$out" 2>&1 || rc=$?
  [[ $rc -eq 1 ]] || { cat "$out" >&2; assert_at $LINENO; }
  assert_contains "Install incomplete" "$out"
  assert_not_contains "Nothing was installed" "$out"
}

# --no-shell-integration gets past the same rc and leaves it as it was.
before_rc=$(cat "$link_home/.zshrc")
run_install_past_preflight "$link_home" "$TMP_DIR/no-shell.out" --no-shell-integration
assert_contains "--no-shell-integration" "$TMP_DIR/no-shell.out"
[[ -L "$link_home/.zshrc" && "$(cat "$link_home/.zshrc")" == "$before_rc" ]] || assert_at $LINENO
[[ -d "$link_home/.claude" ]] || assert_at $LINENO
chmod 755 "$store"

# The default still appends to a writable rc.
rc_home="$TMP_DIR/rc-home"
mkdir -p "$rc_home"
printf '# user rc\n' > "$rc_home/.zshrc"
run_install_past_preflight "$rc_home" "$TMP_DIR/rc-install.out"
grep -Fxq "export DEX_DIR=\"$ROOT\"" "$rc_home/.zshrc" || assert_at $LINENO
grep -Fxq 'source "$DEX_DIR/dx.sh"' "$rc_home/.zshrc" || assert_at $LINENO

# run_uninstall <home> <out> — expected to succeed.
run_uninstall() {
  env HOME="$1" CODEX_HOME="$1/.codex" PATH="$TOOLS:$BASE_PATH" DEX_DIR="$ROOT" \
    DX_RTK_ENABLED=0 bash "$ROOT/bin/uninstall.sh" > "$2" 2>&1 \
    || { cat "$2" >&2; assert_at $LINENO; }
}
rc_lines() {
  printf '%s\n' '# user rc' '# Dex' "export DEX_DIR=\"$ROOT\"" 'source "$DEX_DIR/dx.sh"'
}

# Uninstall leaves a symlinked rc alone, even a writable one.
un_home="$TMP_DIR/un-home"
mkdir -p "$un_home/.claude"
rc_lines > "$TMP_DIR/dotfiles-zshrc"
ln -s "$TMP_DIR/dotfiles-zshrc" "$un_home/.zshrc"
before_rc=$(cat "$TMP_DIR/dotfiles-zshrc")
run_uninstall "$un_home" "$TMP_DIR/uninstall.out"
[[ -L "$un_home/.zshrc" ]] || assert_at $LINENO
assert_eq "$before_rc" "$(cat "$TMP_DIR/dotfiles-zshrc")" "uninstall left the linked rc alone"
assert_contains "is a symlink to $TMP_DIR/dotfiles-zshrc" "$TMP_DIR/uninstall.out"

# And a hardlinked one: mv would sever the link.
hard_home="$TMP_DIR/hard-home"
mkdir -p "$hard_home/.claude"
rc_lines > "$TMP_DIR/hard-zshrc"
ln "$TMP_DIR/hard-zshrc" "$hard_home/.zshrc"
run_uninstall "$hard_home" "$TMP_DIR/uninstall-hard.out"
assert_contains "has 2 hard links" "$TMP_DIR/uninstall-hard.out"
[[ "$TMP_DIR/hard-zshrc" -ef "$hard_home/.zshrc" ]] || assert_at $LINENO
grep -Fxq 'source "$DEX_DIR/dx.sh"' "$TMP_DIR/hard-zshrc" || assert_at $LINENO

# Uninstall removes the worktree links older versions left in the projects
# directory, and nothing else there.
legacy_home="$TMP_DIR/legacy-home"
projects="$legacy_home/.claude/projects"
mkdir -p "$projects/-src-repo" "$projects/-src-other"
ln -s "$projects/-src-repo" "$projects/-src-repo--dex-worktrees-task-a"
ln -s "$projects/-src-repo" "$projects/-src-repo--claude-worktrees-b"
ln -s "$TMP_DIR" "$projects/-src-repo--dex-worktrees-foreign"
ln -s "$projects/-src-repo" "$projects/-src-user-link"
run_uninstall "$legacy_home" "$TMP_DIR/uninstall-legacy.out"
[[ ! -L "$projects/-src-repo--dex-worktrees-task-a" ]] || assert_at $LINENO
# Claude Code's own `claude --worktree` entries are not Dex's.
[[ -L "$projects/-src-repo--claude-worktrees-b" ]] || assert_at $LINENO
[[ -L "$projects/-src-repo--dex-worktrees-foreign" && -L "$projects/-src-user-link" ]] || assert_at $LINENO
[[ -d "$projects/-src-repo" && -d "$projects/-src-other" ]] || assert_at $LINENO
assert_contains "Removed 1 legacy worktree link(s)" "$TMP_DIR/uninstall-legacy.out"

# --- legacy ~/.claude/projects links ------------------------------------------

# plant_link <worktree> — the link an older Dex made for a worktree.
plant_link() {
  local link
  link=$(dx_claude_project_dir "$1")
  mkdir -p "$HOME/.claude/projects/main"
  ln -s "$HOME/.claude/projects/main" "$link"
  printf '%s\n' "$link"
}
add_wt() {
  git -C "$repo" worktree add -q "$repo/.dex/worktrees/$1" -b "worktree-$1" HEAD
}
export PATH="$TOOLS:$BASE_PATH"

# dx_wt_remove, which dxrm, dxrm --all and dxclean all reach.
add_wt task-beta
link=$(plant_link "$repo/.dex/worktrees/task-beta")
(cd "$repo" && dx_wt_remove "$repo/.dex/worktrees/task-beta" "$repo")
[[ ! -L "$link" ]] || assert_at $LINENO
[[ -d "$HOME/.claude/projects/main" ]] || assert_at $LINENO

# dxrm, with the directory present and with it already gone.
add_wt task-gamma
link=$(plant_link "$repo/.dex/worktrees/task-gamma")
(cd "$repo" && zsh -fc 'source "$DEX_DIR/dx.sh"; dxrm task-gamma' > "$TMP_DIR/dxrm.out" 2>&1) \
  || { cat "$TMP_DIR/dxrm.out" >&2; assert_at $LINENO; }
[[ ! -L "$link" ]] || assert_at $LINENO
add_wt task-delta
link=$(plant_link "$repo/.dex/worktrees/task-delta")
rm -rf "$repo/.dex/worktrees/task-delta"
(cd "$repo" && zsh -fc 'source "$DEX_DIR/dx.sh"; dxrm task-delta' > "$TMP_DIR/dxrm-gone.out" 2>&1) \
  || { cat "$TMP_DIR/dxrm-gone.out" >&2; assert_at $LINENO; }
[[ ! -L "$link" ]] || assert_at $LINENO

# dx worktree audit --apply: a stale registration and an unregistered directory.
add_wt task-stale
link=$(plant_link "$repo/.dex/worktrees/task-stale")
rm -rf "$repo/.dex/worktrees/task-stale"
mkdir -p "$repo/.dex/worktrees/task-loose"
loose_link=$(plant_link "$repo/.dex/worktrees/task-loose")
(cd "$repo" && bash "$ROOT/bin/worktree.sh" audit --apply > "$TMP_DIR/audit.out" 2>&1) \
  || { cat "$TMP_DIR/audit.out" >&2; assert_at $LINENO; }
[[ ! -L "$link" && ! -L "$loose_link" ]] || { cat "$TMP_DIR/audit.out" >&2; assert_at $LINENO; }

# dxclean and dxrm --all, for a registration whose directory is already gone:
# they reach it only through `git worktree prune`.
add_wt task-zeta
link=$(plant_link "$repo/.dex/worktrees/task-zeta")
rm -rf "$repo/.dex/worktrees/task-zeta"
(cd "$repo" && zsh -fc 'source "$DEX_DIR/dx.sh"; dxclean' > "$TMP_DIR/dxclean.out" 2>&1) \
  || { cat "$TMP_DIR/dxclean.out" >&2; assert_at $LINENO; }
[[ ! -L "$link" ]] || { cat "$TMP_DIR/dxclean.out" >&2; assert_at $LINENO; }
add_wt task-eta
link=$(plant_link "$repo/.dex/worktrees/task-eta")
rm -rf "$repo/.dex/worktrees/task-eta"
(cd "$repo" && zsh -fc 'source "$DEX_DIR/dx.sh"; dxrm --all' > "$TMP_DIR/dxrm-all.out" 2>&1) \
  || { cat "$TMP_DIR/dxrm-all.out" >&2; assert_at $LINENO; }
[[ ! -L "$link" ]] || { cat "$TMP_DIR/dxrm-all.out" >&2; assert_at $LINENO; }

# A new worktree gets no link at all, even with the repository's own project
# directory in place (the old code linked to it).
mkdir -p "$(dx_claude_project_dir "$repo")" "$repo/.claude"
add_wt task-epsilon
dx_link_claude_to_worktree "$repo" "$repo/.dex/worktrees/task-epsilon"
# The repo's .claude/ is still shared.
[[ -L "$repo/.dex/worktrees/task-epsilon/.claude" ]] || assert_at $LINENO
[[ ! -e "$(dx_claude_project_dir "$repo/.dex/worktrees/task-epsilon")" ]] || assert_at $LINENO

# --- dx status -------------------------------------------------------------------

status_home="$TMP_DIR/status-home"
mkdir -p "$status_home"
env HOME="$status_home" PATH="$ROOT/shims:$TOOLS:$BASE_PATH" DEX_DIR="$ROOT" \
  bash "$ROOT/bin/status.sh" > "$TMP_DIR/status-shims.out" 2>&1 || true
assert_contains "Shell:      dx on PATH ($ROOT/shims/dx)" "$TMP_DIR/status-shims.out"
env HOME="$status_home" PATH="$TOOLS:$BASE_PATH" DEX_DIR="$ROOT" \
  bash "$ROOT/bin/status.sh" > "$TMP_DIR/status-none.out" 2>&1 || true
assert_contains "Shell:      NOT INSTALLED" "$TMP_DIR/status-none.out"

printf 'dx without rc tests passed\n'
