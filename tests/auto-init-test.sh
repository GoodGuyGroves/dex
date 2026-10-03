#!/usr/bin/env bash
# dex-test-lane: fast
# Auto-init sets up .dex/ only with consent: it asks on a terminal, refuses
# elsewhere unless opted in, and installs the attribution hooks and PR template
# only when the user says yes to each.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-auto-init.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEX_SKIP_TOOL_BOOTSTRAP=1 DX_RTK_ENABLED=0 DEXCODE_SYNC=0 DEXCODE_CONTEXT_SYNC=0
unset DEX_AUTO_INIT DX_INIT_REQUESTED DEX_HEADLESS_RUN DEX_HEADLESS_RUN_SPEC_FILE DEX_SESSION_ID
mkdir -p "$HOME"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

new_repo() {
  local repo="$TMP_DIR/$1"
  git init -q "$repo"
  git -C "$repo" config user.email "dex@example.test"
  git -C "$repo" config user.name "Dex Test"
  printf '%s\n' "$repo"
}

# auto_init <repo> — the consent check and the init, as dx runs them.
auto_init() {
  REPO="$1" zsh -fc 'source "$DEX_DIR/dx.sh"; __dx_auto_init_consent "$REPO" && __dx_auto_init_run "$REPO"'
}

assert_nothing_installed() {
  [[ -z "$(git -C "$1" config --get core.hooksPath || true)" ]] || assert_at "$2"
  assert_no_file "$1/.github/pull_request_template.md"
}

# Without a terminal or an opt-in, nothing is created and the message names
# every opt-in.
refused=$(new_repo refused)
if auto_init "$refused" < /dev/null > "$TMP_DIR/refused.out" 2>&1; then
  assert_at $LINENO
fi
assert_contains "dx --init" "$TMP_DIR/refused.out"
assert_contains "DEX_AUTO_INIT=1" "$TMP_DIR/refused.out"
assert_contains "workflow.auto_init: true" "$TMP_DIR/refused.out"
[[ ! -e "$refused/.dex" ]] || assert_at $LINENO

# Each opt-in sets up .dex/ without the hooks or the PR template, and records
# that in dex.md so a later sync leaves them out too.
for opt_in in env flag spec; do
  repo=$(new_repo "opt-in-$opt_in")
  case "$opt_in" in
    env) DEX_AUTO_INIT=1 auto_init "$repo" < /dev/null > "$TMP_DIR/$opt_in.out" 2>&1 || assert_at $LINENO ;;
    flag) DX_INIT_REQUESTED=1 auto_init "$repo" < /dev/null > "$TMP_DIR/$opt_in.out" 2>&1 || assert_at $LINENO ;;
    spec)
      printf '{"workflow": {"auto_init": true}}\n' > "$TMP_DIR/spec.json"
      DEX_HEADLESS_RUN=1 DEX_HEADLESS_RUN_SPEC_FILE="$TMP_DIR/spec.json" \
        auto_init "$repo" < /dev/null > "$TMP_DIR/$opt_in.out" 2>&1 || assert_at $LINENO
      ;;
  esac
  assert_file "$repo/.dex/dex.md"
  assert_nothing_installed "$repo" $LINENO
  ! dx_attribution_hooks_enabled "$repo" || assert_at $LINENO
  ! dx_attribution_pr_template_enabled "$repo" || assert_at $LINENO
  dx_install_repo_attribution "$repo" > /dev/null
  assert_nothing_installed "$repo" $LINENO
done

# A run spec that leaves auto_init false is no opt-in.
spec_off=$(new_repo spec-off)
printf '{"workflow": {"auto_init": false}}\n' > "$TMP_DIR/spec-off.json"
if DEX_HEADLESS_RUN=1 DEX_HEADLESS_RUN_SPEC_FILE="$TMP_DIR/spec-off.json" \
  auto_init "$spec_off" < /dev/null > "$TMP_DIR/spec-off.out" 2>&1; then
  assert_at $LINENO
fi
[[ ! -e "$spec_off/.dex" ]] || assert_at $LINENO

# On a terminal: answer each question and check what was set up.
# tty_auto_init <repo> <answer>... — run the auto-init under a pseudo-terminal,
# answering each [y/N] prompt in turn.
tty_auto_init() {
  local repo="$1"
  shift
  REPO="$repo" python3 - "$@" <<'PY'
import os
import pty
import sys

answers = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("zsh", ["zsh", "-fc",
        'source "$DEX_DIR/dx.sh"; __dx_auto_init_consent "$REPO" && __dx_auto_init_run "$REPO"'])
output = b""
sent = 0
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    output += data
    while sent < len(answers) and output.count(b"[y/N]") > sent:
        os.write(fd, answers[sent].encode() + b"\n")
        sent += 1
_, wait_status = os.waitpid(pid, 0)
sys.stdout.write(output.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(wait_status))
PY
}

declined=$(new_repo tty-declined)
if tty_auto_init "$declined" n > "$TMP_DIR/tty-declined.out"; then
  assert_at $LINENO
fi
assert_contains "Set up Dex in" "$TMP_DIR/tty-declined.out"
[[ ! -e "$declined/.dex" ]] || assert_at $LINENO

hooks_only=$(new_repo tty-hooks)
tty_auto_init "$hooks_only" y y n > "$TMP_DIR/tty-hooks.out" || { cat "$TMP_DIR/tty-hooks.out" >&2; assert_at $LINENO; }
[[ -n "$(git -C "$hooks_only" config --get core.hooksPath)" ]] || assert_at $LINENO
assert_no_file "$hooks_only/.github/pull_request_template.md"
dx_attribution_hooks_enabled "$hooks_only" || assert_at $LINENO
! dx_attribution_pr_template_enabled "$hooks_only" || assert_at $LINENO

# With an opt-in, a terminal still asks about the hooks and the template.
template_only=$(new_repo tty-template)
DEX_AUTO_INIT=1 tty_auto_init "$template_only" n y > "$TMP_DIR/tty-template.out" \
  || { cat "$TMP_DIR/tty-template.out" >&2; assert_at $LINENO; }
assert_not_contains "Set up Dex in" "$TMP_DIR/tty-template.out"
[[ -z "$(git -C "$template_only" config --get core.hooksPath || true)" ]] || assert_at $LINENO
assert_file "$template_only/.github/pull_request_template.md"

# A headless run on a terminal is still headless: it needs an opt-in.
headless_tty=$(new_repo tty-headless)
if DEX_HEADLESS_RUN=1 tty_auto_init "$headless_tty" y y y > "$TMP_DIR/tty-headless.out"; then
  assert_at $LINENO
fi
assert_contains "DEX_AUTO_INIT=1" "$TMP_DIR/tty-headless.out"
[[ ! -e "$headless_tty/.dex" ]] || assert_at $LINENO

# `dx --init` reaches the lifecycle setup as an opt-in and does not outlive
# that one call.
flag_repo=$(new_repo dx-init-flag)
(
  cd "$flag_repo"
  zsh -fc 'source "$DEX_DIR/dx.sh"
    __dx_setup_in_place() { print "init_requested=${DX_INIT_REQUESTED:-0}"; return 1; }
    dx --init --no-worktree "tiny task"
    print "after=${DX_INIT_REQUESTED:-unset}"'
) > "$TMP_DIR/dx-init-flag.out" 2>&1 || true
assert_contains "init_requested=1" "$TMP_DIR/dx-init-flag.out"
assert_contains "after=unset" "$TMP_DIR/dx-init-flag.out"

printf 'auto-init tests passed\n'
