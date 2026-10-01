#!/usr/bin/env bash
# No-global-writes harness (issue #2) and installed-vs-isolated parity.
#
# Runs Dex's entry points inside a sandbox HOME and snapshots it around each
# step, so every write outside DEX_HOME and the target repository is caught and
# attributed to the step that made it. Each step's after-snapshot is the next
# step's before, so nothing written between steps can vanish. Stub claude,
# codex, gh, npm, npx, node, curl and afplay (tests/fixtures/global-writes/
# bin/stub) sit first on PATH, reproduce the side effects of the real commands,
# and never touch the network. The Dex checkout itself is watched too: its
# `git status` must not change.
#
# The isolated run unsets every DX_* state override and CLAUDE_CONFIG_DIR, so
# the ~/.claude/.dex-* and ~/.dex defaults fire. Those are what unit 05 exists
# to remove; setting the overrides here would hide them. Entry points that
# would only repeat writes an earlier step already made (session, tools,
# status, phase, reload) also run alone in a fresh sandbox, so their own
# writes show.
#
# Expected failures: tests/fixtures/global-writes/expected.tsv lists today's
# known writes, each keyed to the unit (01-05) that removes it. A write missing
# from the list fails, and so does a row nothing matches any more: each unit
# deletes its own rows, and after unit 05 the file is empty.
#
# Parity: the same scenario runs once after a sandboxed `dx install` and once
# isolated, at the same path so path-derived session keys agree, and the
# configuration every stub `claude` launch received is compared: hooks,
# skills, plugins, MCP servers, settings and DEX_/DX_/CLAUDE_ environment
# values. Intended differences live in parity-allow.tsv.
#
# Scope: this detects accidental global writes by Dex. It is not a sandbox
# against deliberately evasive code: hard-link tricks beyond the nlink check,
# setuid or executable-bit payloads, and daemons that hide their argv and cwd
# are out of scope.
#
# Not covered, and why:
# - On Darwin the leftover scan sees only argv (there is no /proc to read a
#   process's environment); a detached process whose argv does not name the
#   sandbox is invisible to it.
# - The real HOME is not watched. Sandboxing works by overriding HOME and
#   friends; a writer that resolves the home directory some other way would
#   escape the snapshot. The guard below only checks where the sandbox is.
# - `dx login` (~/.config/dex) needs the network to reach DexCode.
# - The router-native sync (scripts/ccr/native.cjs) runs only once the user
#   has opted into CCR routing (~/.dex/router/config.json).
# - Without a node on PATH, the node stub cannot run Dex's own Node scripts,
#   and their writes go unseen.
# - The real /tmp and TMPDIR are not watched either (each step gets its own
#   TMPDIR inside the sandbox, outside the snapshot).
# - The stubs do not reproduce Claude Code's own bookkeeping (startup
#   counters, backups, session files): that is the CLI's state, not Dex's.
# - Background writers. A step runs in its own process group and must leave
#   nothing behind, and a process still naming the sandbox (command line, or
#   HOME on Linux) after the grace fails the step. The last step of each
#   sandbox is followed by a settle and one more snapshot (`after:<step>`).
#   A detached process that names neither can still write during a later
#   step and be attributed to it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
FIXTURES="$ROOT/tests/fixtures/global-writes"
HELPER="$ROOT/tests/global_writes.py"
TIMEOUT="$ROOT/tests/test-timeout.py"

# The account's home, from the password database rather than $HOME, which
# run-all.sh has already replaced. Nothing below may run against it.
REAL_HOME=$(python3 -c 'import os, pwd; print(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))')
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-no-global-writes-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
cleanup() {
  # GW_KEEP=1 leaves the sandboxes (step output, stub logs) for inspection.
  if [[ "${GW_KEEP:-0}" == 1 ]]; then
    printf 'kept %s\n' "$TMP_DIR" >&2
    return 0
  fi
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
case "$TMP_DIR/" in
  "$REAL_HOME"/.claude/*|"$REAL_HOME"/.codex/*|"$REAL_HOME"/.config/*) fail "sandbox $TMP_DIR is inside real config" ;;
esac

# Shim-based toolchain managers find their real binaries through a home under
# $HOME; hand each its directory explicitly, as tests/run-all.sh does.
TOOLCHAIN_ENV=()
for pair in VOLTA_HOME:.volta ASDF_DIR:.asdf ASDF_DATA_DIR:.asdf \
    RBENV_ROOT:.rbenv PYENV_ROOT:.pyenv FNM_DIR:.fnm NVM_DIR:.nvm; do
  name="${pair%%:*}"
  value="${!name:-}"
  [[ -n "$value" || ! -d "$HOME/${pair#*:}" ]] || value="$HOME/${pair#*:}"
  [[ -z "$value" ]] || TOOLCHAIN_ENV+=("$name=$value")
done
REAL_NODE=$(command -v node || true)

# Setup runs git too; keep it off the caller's configuration.
export HOME="$TMP_DIR/setup-home" GIT_CONFIG_GLOBAL="$TMP_DIR/setup-home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
: > "$GIT_CONFIG_GLOBAL"

# Tools the scenario needs, linked from the caller's PATH so a real claude,
# codex or rtk elsewhere on it can never be reached.
TOOLS_BIN="$TMP_DIR/tools-bin"
STUB_BIN="$TMP_DIR/stub-bin"
mkdir -p "$TOOLS_BIN" "$STUB_BIN"
for tool in bash zsh python3 git jq tar gzip perl; do
  tool_path=$(command -v "$tool") || { [[ "$tool" == jq ]] && continue; fail "missing tool: $tool"; }
  ln -s "$tool_path" "$TOOLS_BIN/$tool"
done
for tool in claude codex gh npm npx node curl afplay; do
  ln -s "$FIXTURES/bin/stub" "$STUB_BIN/$tool"
done
python3 "$HELPER" selftest "$ROOT" || fail "tests/global_writes.py selftest failed"
# check.sh py_compiles tests/*.py only; the stub has no extension.
python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$FIXTURES/bin/stub"

# The RTK release the curl stub serves, built the way tests/rtk-install-test.sh does.
RTK_FIXTURES="$TMP_DIR/rtk-release"
mkdir -p "$RTK_FIXTURES/archive"
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ "${1:-}" == rewrite && "${2:-}" == "git status" ]] && { printf "rtk git status\n"; exit 0; }' \
  'exit 1' > "$RTK_FIXTURES/archive/rtk"
chmod +x "$RTK_FIXTURES/archive/rtk"
for triple in x86_64-unknown-linux-musl aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin; do
  tar -czf "$RTK_FIXTURES/rtk-$triple.tar.gz" -C "$RTK_FIXTURES/archive" rtk
done
(cd "$RTK_FIXTURES" && python3 -c '
import glob, hashlib
with open("checksums.txt", "w") as out:
    for name in sorted(glob.glob("*.tar.gz")):
        out.write("%s  %s\n" % (hashlib.sha256(open(name, "rb").read()).hexdigest(), name))')

ALL_OBSERVED="$TMP_DIR/observed.tsv"
: > "$ALL_OBSERVED"

# Tracked, untracked and ignored files (node_modules/, skills/synced/, ...),
# except bytecode: parallel tests write hooks/__pycache__ at any time.
dex_dir_status() {
  git -C "$ROOT" status --porcelain --untracked-files=all --ignored=matching \
    | { grep -vE '(^|/)__pycache__/|\.pyc$' || true; }
}

# new_sandbox <dir> [--no-skills] — a HOME seeded with representative user
# files (tests/global_writes.py seed), a workspace holding DEX_HOME and the
# target repository, and a bare origin. The usual per-user directories exist
# already, so a row can name the exact path a writer adds inside them.
new_sandbox() {
  local box="$1"
  SB_SEED_FLAGS=("${@:2}")
  SB_HOME="$box/home"
  SB_DEX_HOME="$SB_HOME/workspace/dex-home"
  SB_REPO="$SB_HOME/workspace/repo"
  SB_STUB="$box/stub"
  SB_OBSERVED="$box/observed.tsv"
  SB_DEX_HOME_ENV=(DEX_HOME="$SB_DEX_HOME")
  [[ "$SB_HOME" != "$REAL_HOME" && "$SB_HOME" == "$TMP_DIR"/* ]] || fail "sandbox HOME escaped: $SB_HOME"
  mkdir -p "$SB_HOME"/.local/{bin,share,state} "$SB_HOME/Library/Caches" "$SB_HOME/.cache" \
    "$SB_HOME/.npm" "$SB_HOME/.config" "$SB_DEX_HOME" "$SB_REPO" "$SB_STUB" "$box/tmp"
  : > "$SB_OBSERVED"
  python3 "$HELPER" seed "$SB_HOME" ${SB_SEED_FLAGS[@]+"${SB_SEED_FLAGS[@]}"}
  # Claude Code's own project data for the repository. Dex used to link it
  # into each worktree; it stays seeded so a link coming back shows here.
  mkdir -p "$SB_HOME/.claude/projects/$(printf '%s' "$SB_REPO" | tr '/.' '--')"
  printf 'user memory\n' > "$SB_HOME/.claude/projects/$(printf '%s' "$SB_REPO" | tr '/.' '--')/memory.md"

  git init -q --bare "$box/origin.git"
  git -C "$SB_REPO" init -q
  git -C "$SB_REPO" config user.email dex@example.test
  git -C "$SB_REPO" config user.name "Dex Test"
  printf '# repo\n' > "$SB_REPO/README.md"
  printf 'print("hi")\n' > "$SB_REPO/main.py"
  printf '%s\n' '{"mcpServers":{"repoServer":{"command":"repo-mcp"}}}' > "$SB_REPO/.mcp.json"
  # A project session-end hook: the plain session firing it is a global hook
  # running a repository's command in a session Dex did not launch.
  mkdir -p "$SB_REPO/.dex"
  printf '%s\n' '# Dex' '' '## Worktree Hooks' '' '```yaml' \
    'on_session_end: touch "$HOME/.gw-on-session-end"' '```' > "$SB_REPO/.dex/dex.md"
  git -C "$SB_REPO" add -A
  git -C "$SB_REPO" commit -q -m "chore: init"
  git -C "$SB_REPO" branch -M main
  git -C "$SB_REPO" remote add origin "$box/origin.git"
  git -C "$SB_REPO" push -q -u origin main

  python3 "$HELPER" snapshot "$SB_HOME" "$SB_STUB/last.json" \
    --exclude "$SB_DEX_HOME" --exclude "$SB_REPO"
  dex_dir_status > "$SB_STUB/dex-dir.before"
}

# finish_sandbox — the user's own files survived and every hook the stub
# fired answered. On a loss, the removals and rewrites point at the step.
finish_sandbox() {
  # A late writer from the last step would otherwise land nowhere.
  sleep "$SETTLE_SECONDS"
  record "after:$SB_LAST_STEP"
  if ! python3 "$HELPER" seeded "$SB_HOME" ${SB_SEED_FLAGS[@]+"${SB_SEED_FLAGS[@]}"} >&2; then
    printf 'removed or rewritten entries, by step:\n' >&2
    grep -E '	(removed|modified)	' "$SB_OBSERVED" >&2 || true
    fail "user data did not survive in $SB_HOME (above)"
  fi
  python3 "$HELPER" hooks-ok "$SB_STUB/hooks.jsonl" >&2 \
    || fail "a hook fired by the stub failed or timed out (above)"
}

# record <label> — snapshot HOME, attribute the difference to <label>, and
# check the Dex checkout and the hooks in the user's settings.
record() {
  python3 "$HELPER" snapshot "$SB_HOME" "$SB_STUB/after.json" \
    --exclude "$SB_DEX_HOME" --exclude "$SB_REPO"
  python3 "$HELPER" diff "$SB_STUB/last.json" "$SB_STUB/after.json" "$1" >> "$SB_OBSERVED"
  mv "$SB_STUB/after.json" "$SB_STUB/last.json"
  dex_dir_status > "$SB_STUB/dex-dir.after"
  diff "$SB_STUB/dex-dir.before" "$SB_STUB/dex-dir.after" >&2 \
    || fail "step $1 wrote into the Dex checkout $ROOT (above)"
  python3 "$HELPER" dex-hooks "$SB_HOME" "$ROOT" "$1" >&2 \
    || fail "step $1 left a hook in ~/.claude/settings.json that is neither the user's nor Dex's (above)"
}

GRACE_SECONDS=10   # for a step's own processes to finish
SETTLE_SECONDS=5   # before a sandbox's final snapshot
# test-timeout.py's status when --grace ran out with processes still running.
GRACE_EXPIRED=125

# step <label> <stdin-file> <expect-rc> <command...> — run one entry point
# with a clean environment in its own process group, wait for the group to
# drain, and record what it wrote under HOME. A process left behind, in the
# group or detached but still naming the sandbox, fails the step. GW_PLAIN=1
# is a session the user started: no DEX_DIR or DEX_HOME, and the stub fires
# the hooks it finds.
step() {
  local label="$1" input="$2" expect_rc="$3" rc=0 dex_env=()
  shift 3
  SB_LAST_STEP="$label"
  [[ "${GW_PLAIN:-0}" == 1 ]] || dex_env=(DEX_DIR="$ROOT" ${SB_DEX_HOME_ENV[@]+"${SB_DEX_HOME_ENV[@]}"})
  (
    cd "$SB_REPO"
    env -i \
      HOME="$SB_HOME" USER="${USER:-dex}" LOGNAME="${USER:-dex}" SHELL=/bin/zsh TERM=dumb LANG=C.UTF-8 \
      PATH="$STUB_BIN:$TOOLS_BIN:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${SB_STUB%/stub}/tmp" \
      CODEX_HOME="$SB_HOME/.codex" ZDOTDIR="$SB_HOME" GIT_CONFIG_NOSYSTEM=1 \
      XDG_CONFIG_HOME="$SB_HOME/.config" XDG_CACHE_HOME="$SB_HOME/.cache" \
      XDG_DATA_HOME="$SB_HOME/.local/share" XDG_STATE_HOME="$SB_HOME/.local/state" \
      ${TOOLCHAIN_ENV[@]+"${TOOLCHAIN_ENV[@]}"} ${dex_env[@]+"${dex_env[@]}"} \
      DEXCODE_SYNC=0 DEXCODE_CONTEXT_SYNC=0 PYTHONDONTWRITEBYTECODE=1 \
      GW_STEP="$label" GW_STUB_DIR="$SB_STUB" GW_FIXTURES="$RTK_FIXTURES" GW_DEX_DIR="$ROOT" \
      GW_REAL_NODE="$REAL_NODE" GW_FIRE_HOOKS="${GW_PLAIN:-0}" \
      python3 "$TIMEOUT" --grace "$GRACE_SECONDS" 300 "$@" < "$input"
  ) > "$SB_STUB/$label.out" 2>&1 || rc=$?
  # A command that itself exits 125 reads the same; nothing Dex runs here does.
  [[ "$rc" != "$GRACE_EXPIRED" ]] || fail "step $label left background processes in its group"
  python3 "$HELPER" leftovers "${SB_STUB%/stub}" "$GRACE_SECONDS" >&2 \
    || fail "step $label left background processes (above, now killed)"
  if [[ "$rc" != "$expect_rc" ]]; then
    printf 'step %s exited %s, expected %s:\n' "$label" "$rc" "$expect_rc" >&2
    tail -n 40 "$SB_STUB/$label.out" >&2
    exit 1
  fi
  record "$label"
}

dx_step() { # <label> <stdin> <rc> <zsh code run after sourcing dx.sh>
  step "$1" "$2" "$3" zsh -fc "source \"\$DEX_DIR/dx.sh\"; $4"
}

plain_step() { # <label>
  GW_PLAIN=1 step "$1" "$NO_INPUT" 0 claude
}

DEFAULTS="$TMP_DIR/defaults.in"  # Enter at every prompt: config.sh defaults
python3 -c 'print("\n" * 200, end="")' > "$DEFAULTS"
NO_INPUT=/dev/null
# bin/config.sh asks for the session-messaging answer, and records it, only on
# a terminal. pty.spawn starts its child in a session of its own, outside the
# step's process group, so the grace does not cover that child's descendants;
# the leftover scan after the step does.
ON_A_TTY=(python3 -c 'import os, pty, sys
code = os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:]))
sys.exit(code if code >= 0 else 128 - code)')

# run_scenario <name> <installed:0|1> — the installed run is someone who used
# `dx install` and has no DEX_HOME; the isolated run launches with one. Both
# run at the same path and are moved aside afterwards.
run_scenario() {
  new_sandbox "$TMP_DIR/box"
  if [[ "$2" == 1 ]]; then
    SB_DEX_HOME_ENV=()
    # The rc append, and its refusal, are covered by tests/dx-without-rc-test.sh.
    dx_step install "$NO_INPUT" 0 'dx install --no-shell-integration'
  fi
  dx_step init "$DEFAULTS" 0 'dx init'
  step config "$DEFAULTS" 0 "${ON_A_TTY[@]}" zsh -fc 'source "$DEX_DIR/dx.sh"; dx config'
  dx_step sync "$NO_INPUT" 0 'dx sync'
  dx_step tools "$NO_INPUT" 0 'dx tools bootstrap'
  dx_step reload "$NO_INPUT" 0 'dx reload'
  dx_step status "$NO_INPUT" 0 'dx status'
  dx_step session "$NO_INPUT" 0 'dx --session "list the files"'
  # Phase 6 of the lifecycle. The stub leaves no completion receipt, so
  # dxcomplete pauses and exits 1 after the launch.
  dx_step phase "$NO_INPUT" 1 'dxcomplete'
  dx_step wt-create "$NO_INPUT" 0 '__dx_setup_worktree "gw task" && __dx_startup_claim_release'
  dx_step wt-remove "$NO_INPUT" 0 'dxrm gw-task'
  dx_step maintain "$NO_INPUT" 0 'dx maintain --no-sync --no-pr --dry-run --include-working-tree'
  dx_step provider "$NO_INPUT" 0 'dx provider use claude-subscription'
  dx_step setup "$NO_INPUT" 0 'dx setup --direct'
  plain_step plain
  if [[ "$2" == 1 ]]; then
    dx_step uninstall "$NO_INPUT" 0 'dx uninstall'
  fi
  finish_sandbox
  mv "$TMP_DIR/box" "$TMP_DIR/$1"
}

run_scenario isolated 0
cat "$TMP_DIR/isolated/observed.tsv" >> "$ALL_OBSERVED"
ISOLATED_STUB="$TMP_DIR/isolated/stub"

# Coverage: a step that failed early writes nothing and would pass for clean.
grep -Eq '"argv": \["mcp", "add".*"tool": "claude"' "$ISOLATED_STUB/calls.jsonl" \
  || fail "init never ran claude mcp add"
for label in session phase plain; do
  grep -q "\"step\": \"$label\"" "$ISOLATED_STUB/launches.jsonl" \
    || fail "no stub claude launch recorded for step $label"
done
grep -q '"event": "Stop"' "$ISOLATED_STUB/hooks.jsonl" || fail "the plain session fired no Stop hook"

# fresh <label> <rc> <zsh code> [--no-skills] — one entry point alone.
fresh() {
  new_sandbox "$TMP_DIR/$1" "${@:4}"
  dx_step "$1" "$NO_INPUT" "$2" "$3"
  finish_sandbox
  cat "$SB_OBSERVED" >> "$ALL_OBSERVED"
}
fresh session-fresh 0 'dx --session "list the files"'
# No ~/.claude/skills yet, so Dex links the whole directory.
fresh tools-fresh 0 'dx tools bootstrap' --no-skills
fresh status-fresh 0 'dx status'
fresh phase-fresh 1 'dxcomplete'
# The Stop hook's mkdir of DX_LOOP_DIR only shows on a machine where no Dex
# command has created that directory yet: hooks installed, then a plain session.
new_sandbox "$TMP_DIR/reload-fresh"
dx_step reload-fresh "$NO_INPUT" 0 'dx reload'
plain_step plain-fresh
finish_sandbox
cat "$SB_OBSERVED" >> "$ALL_OBSERVED"

run_scenario installed 1
# The installed run's other steps repeat the isolated run's entry points; its
# own are install and uninstall.
grep -E '^(install|uninstall)	' "$TMP_DIR/installed/observed.tsv" >> "$ALL_OBSERVED"

python3 "$HELPER" check "$ALL_OBSERVED" "$FIXTURES/expected.tsv" "$ROOT" >&2 \
  || fail "global writes differ from tests/fixtures/global-writes/expected.tsv (above)"
python3 "$HELPER" parity "$TMP_DIR/installed/stub/launches.jsonl" \
  "$ISOLATED_STUB/launches.jsonl" "$FIXTURES/parity-allow.tsv" >&2 \
  || fail "installed and isolated launches differ outside parity-allow.tsv (above)"

printf 'no-global-writes tests passed\n'
