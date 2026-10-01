#!/usr/bin/env bash
# Launch-scoped Claude settings: every Dex launch gets exactly one --settings
# file carrying Dex's hooks, and nothing reaches ~/.claude/settings.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-launch-settings-test.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops" DX_RUN_ROOT="$TMP_DIR/runs"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts" DX_TOOL_DIR="$TMP_DIR/tools"
export DX_REVIEW_CAPACITY_DIR="$TMP_DIR/capacity"
unset CLAUDE_CONFIG_DIR DEX_HOME DEX_EXTRA_SETTINGS DEX_LAUNCHED DEX_SESSION_ID
mkdir -p "$HOME/.claude"
HELPER="$ROOT/scripts/settings-json.py"

# ── settings-json.py launch-settings ──────────────────────────────────────
printf '%s\n' '{"model":"extra","permissions":{"allow":["Extra"]},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo extra-stop"}]}]}}' \
  > "$TMP_DIR/extra.json"
printf '%s\n' '{"model":"second","worktree":{"symlinkDirectories":["second-cache","node_modules"]}}' \
  > "$TMP_DIR/second.json"
first='{"model":"first","disableAllHooks":true,"statusLine":{"type":"command","command":"mine"},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo first-stop"}]}],"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"echo first-read"}]}]}}'
DEX_EXTRA_SETTINGS="$TMP_DIR/extra.json" python3 "$HELPER" launch-settings "$ROOT/settings.json" \
  "$ROOT" "$ROOT/bin/status-line.sh" accept 0 "$first" "$TMP_DIR/second.json" > "$TMP_DIR/merged.json"
python3 - "$TMP_DIR/merged.json" "$ROOT" <<'PY'
import json, sys
settings, dex_dir = json.load(open(sys.argv[1])), sys.argv[2]
commands = lambda event: [hook["command"] for group in settings["hooks"][event] for hook in group["hooks"]]
assert settings["model"] == "extra", settings["model"]                # DEX_EXTRA_SETTINGS last
assert settings["permissions"] == {"allow": ["Extra"]}, settings
assert settings["statusLine"] == {"type": "command", "command": "mine"}, settings  # caller over default
assert settings["crossSessionInbound"] == "accept", settings
assert settings["disableAllHooks"] is False, settings                # outranks a user's true
stop = commands("Stop")
assert stop[:2] == ["echo first-stop", "echo extra-stop"], stop     # every layer's hooks add up
assert any("phase-loop.sh" in c for c in stop) and any("stop-sound.sh" in c for c in stop), stop
pre = commands("PreToolUse")
assert "guard-handler.py" in pre[0] and pre[-1] == "echo first-read", pre  # guards run first
assert not any("rtk-claude-hook.sh" in c for c in pre), pre           # RTK off: no RTK hook
dirs = settings["worktree"]["symlinkDirectories"]
assert dirs[0] == "second-cache" and dirs.count("node_modules") == 1 and ".venv" in dirs, dirs
for event in ("SessionStart", "UserPromptSubmit", "PostToolUse", "PreCompact", "SessionEnd"):
    assert any(dex_dir in c or "$DEX_DIR" in c for c in commands(event)), event
PY

# RTK on: its hook is there once. A Dex hook a caller repeats is not doubled.
python3 "$HELPER" launch-settings "$ROOT/settings.json" "$ROOT" '' '' 1 \
  "$(python3 "$HELPER" render-template "$ROOT/settings.json" "$ROOT")" > "$TMP_DIR/rtk.json"
python3 - "$TMP_DIR/rtk.json" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
commands = [h["command"] for groups in settings["hooks"].values() for g in groups for h in g["hooks"]]
assert sum("rtk-claude-hook.sh" in c for c in commands) == 1, commands
assert len(commands) == len(set(commands)), commands
assert "statusLine" not in settings and "crossSessionInbound" not in settings, settings
PY

# The global-install gate never reaches a launch file.
assert_rejected 'launch-settings --gated' python3 "$HELPER" launch-settings "$ROOT/settings.json" \
  "$ROOT" '' '' 0 --gated 2>/dev/null

# A settings layer that cannot be read fails the launch and names itself.
printf '{broken\n' > "$TMP_DIR/broken.json"
for extra in "$TMP_DIR/broken.json" "$TMP_DIR/missing.json" '{"model":"inline"}'; do
  if DEX_EXTRA_SETTINGS="$extra" python3 "$HELPER" launch-settings "$ROOT/settings.json" \
      "$ROOT" '' '' 0 > /dev/null 2> "$TMP_DIR/extra.err"; then
    printf 'an unusable DEX_EXTRA_SETTINGS (%s) was accepted\n' "$extra" >&2
    exit 1
  fi
  assert_contains "$extra" "$TMP_DIR/extra.err"
done
assert_rejected 'unreadable --settings' python3 "$HELPER" launch-settings "$ROOT/settings.json" \
  "$ROOT" '' '' 0 "$TMP_DIR/broken.json" 2>/dev/null

# ── dx_provider_claude ────────────────────────────────────────────────────
# The stub records its argv, every --settings file it was handed (read while
# the launch is running), and DEX_LAUNCHED.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_OUT.argv"
printf '%s\n' "${DEX_LAUNCHED:-unset}" > "$STUB_OUT.launched"
printf '%s\n' "${DX_LAUNCH_STATUS_LINE:-unset}" > "$STUB_OUT.status-request"
count=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings) count=$((count + 1)); cp "$2" "$STUB_OUT.settings" && printf '%s\n' "$2" > "$STUB_OUT.path"; shift ;;
    --settings=*) count=$((count + 1)) ;;
    --) break ;;
  esac
  shift
done
printf '%s\n' "$count" > "$STUB_OUT.count"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$TMP_DIR/bin/claude"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
export DX_RTK_ENABLED=0
launch() { # <label> <args...>
  local label="$1"
  shift
  (
    export PATH="$TMP_DIR/bin:$PATH" STUB_OUT="$TMP_DIR/$label"
    export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=claude DX_PROVIDER_PROFILE_RESOLVED=claude
    dx_provider_claude "$@"
  )
}

# The launch paths: a lifecycle phase, dxloop's resume, a one-shot print run.
# Only a lifecycle phase asks for Dex's status line (dx.sh sets
# DX_LAUNCH_STATUS_LINE=1); the request is not passed on to the session.
DX_LAUNCH_STATUS_LINE=1 launch phase --dangerously-skip-permissions --append-system-prompt-file /dev/null "go"
assert_eq 0 "$(cat "$TMP_DIR/phase.status-request")" 'status-line request consumed'
# A Codex engine gets no settings file, and the request does not reach it either.
(
  export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=codex-plugin DX_PROVIDER_PROFILE_RESOLVED=codex
  __dx_provider_claude_exec() {
    printf '%s|%s\n' "${DX_LAUNCH_STATUS_LINE:-unset}" "$*" > "$TMP_DIR/codex.exec"
  }
  DX_LAUNCH_STATUS_LINE=1 dx_provider_claude -p "go"
)
assert_eq '0|-p go' "$(cat "$TMP_DIR/codex.exec")" 'codex: request cleared, argv untouched'
launch loop --dangerously-skip-permissions --resume -n loop-session \
  --settings '{"model":"caller"}' --append-system-prompt "--settings is not a flag here"
launch print -p "one-shot" "--settings={\"effortLevel\":\"high\"}"
for label in phase loop print; do
  assert_eq 1 "$(cat "$TMP_DIR/$label.count")" "$label: one --settings"
  assert_eq 1 "$(cat "$TMP_DIR/$label.launched")" "$label: DEX_LAUNCHED"
  assert_no_file "$(cat "$TMP_DIR/$label.path")"
  case "$(cat "$TMP_DIR/$label.path")" in
    "$DX_LOOP_DIR/launch-settings/launch."*) ;;
    *) fail "$label: launch file outside DX_LOOP_DIR: $(cat "$TMP_DIR/$label.path")" ;;
  esac
done
grep -Fxq -- '--settings is not a flag here' "$TMP_DIR/loop.argv" || assert_at $LINENO
grep -Fxq -- 'loop-session' "$TMP_DIR/loop.argv" || assert_at $LINENO
python3 - "$TMP_DIR" <<'PY'
import json, sys
tmp = sys.argv[1]
load = lambda label: json.load(open("%s/%s.settings" % (tmp, label)))
phase, loop, one_shot = load("phase"), load("loop"), load("print")
assert "status-line.sh" in phase["statusLine"]["command"], phase
assert any("phase-loop.sh" in h["command"] for g in phase["hooks"]["Stop"] for h in g["hooks"]), phase
assert loop["model"] == "caller" and "statusLine" not in loop, loop
assert one_shot["effortLevel"] == "high" and "statusLine" not in one_shot, one_shot
PY

# DEX_HOME holds the launch file when set; the provider's exit status survives
# the cleanup; a file a killed launch left behind is swept once it is old.
mkdir -p "$TMP_DIR/dex-home/launch-settings"
touch -t 202001010000 "$TMP_DIR/dex-home/launch-settings/launch.stale"
touch "$TMP_DIR/dex-home/launch-settings/launch.recent"
rc=0
DEX_HOME="$TMP_DIR/dex-home" STUB_EXIT=7 launch home "go" || rc=$?
assert_eq 7 "$rc" 'provider exit status'
case "$(cat "$TMP_DIR/home.path")" in
  "$TMP_DIR/dex-home/launch-settings/launch."*) ;;
  *) fail "launch file ignored DEX_HOME: $(cat "$TMP_DIR/home.path")" ;;
esac
assert_no_file "$(cat "$TMP_DIR/home.path")"
assert_no_file "$TMP_DIR/dex-home/launch-settings/launch.stale"
assert_file "$TMP_DIR/dex-home/launch-settings/launch.recent"
# The directory a launch creates is private.
assert_eq 0o700 "$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$DX_LOOP_DIR/launch-settings")" 'launch-settings mode'

# A broken extra layer stops the launch before claude runs.
rm -f "$TMP_DIR/broken-extra.argv"
if DEX_EXTRA_SETTINGS="$TMP_DIR/broken.json" launch broken-extra "go" 2> "$TMP_DIR/broken-extra.err"; then
  fail 'a launch with an unreadable DEX_EXTRA_SETTINGS started'
fi
assert_no_file "$TMP_DIR/broken-extra.argv"
assert_contains "$TMP_DIR/broken.json" "$TMP_DIR/broken-extra.err"

# A --settings a flag/value pair hid would reach claude as a second settings
# layer: refused before claude runs. After `--` it is prompt text and passes.
for smuggled in "--append-system-prompt --settings hello" "--allowedTools --settings x" \
    "--betas --settings={}"; do
  rm -f "$TMP_DIR/smuggle.argv"
  # shellcheck disable=SC2086  # the case is a word list
  if launch smuggle $smuggled "go" 2> "$TMP_DIR/smuggle.err"; then
    fail "a hidden --settings passed: $smuggled"
  fi
  assert_no_file "$TMP_DIR/smuggle.argv"
  assert_contains "Pass --settings once" "$TMP_DIR/smuggle.err"
done
launch delimited -- "--settings"
assert_eq 1 "$(cat "$TMP_DIR/delimited.count")" 'after -- is prompt text'

# A layer whose hooks have the wrong shape fails with its path, not a traceback.
for shape in '{"hooks":[]}' '{"hooks":{"Stop":{}}}' '{"hooks":{"Stop":["x"]}}' \
    '{"hooks":{"Stop":[{"hooks":"x"}]}}'; do
  printf '%s\n' "$shape" > "$TMP_DIR/shape.json"
  if DEX_EXTRA_SETTINGS="$TMP_DIR/shape.json" python3 "$HELPER" launch-settings \
      "$ROOT/settings.json" "$ROOT" '' '' 0 > /dev/null 2> "$TMP_DIR/shape.err"; then
    fail "hooks of the wrong shape were accepted: $shape"
  fi
  assert_contains "$TMP_DIR/shape.json" "$TMP_DIR/shape.err"
  assert_not_contains "Traceback" "$TMP_DIR/shape.err"
done

# None of this touched the user's settings.
assert_no_file "$HOME/.claude/settings.json"

# ── the opt-in global install ─────────────────────────────────────────────
# Its commands are gated: inside a Dex launch they do nothing, outside they run.
python3 "$HELPER" render-template "$ROOT/settings.json" "$TMP_DIR/fake-dex" --gated > "$TMP_DIR/gated.json"
gated_stop=$(python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["hooks"]["Stop"][1]["hooks"][0]["command"])' "$TMP_DIR/gated.json")
mkdir -p "$TMP_DIR/fake-dex/hooks"
printf 'printf ran > "%s/gate.out"\n' "$TMP_DIR" > "$TMP_DIR/fake-dex/hooks/stop-sound.sh"
env DEX_LAUNCHED=1 DEX_DIR="$TMP_DIR/fake-dex" sh -c "$gated_stop" < /dev/null
assert_no_file "$TMP_DIR/gate.out"
env -u DEX_LAUNCHED DEX_DIR="$TMP_DIR/fake-dex" sh -c "$gated_stop" < /dev/null
assert_file "$TMP_DIR/gate.out"

# --no-global-hooks takes the hooks and managed directories back and keeps the
# rest of the install state, including the session-messaging answer.
printf '%s\n' '{"theme":"dark"}' > "$HOME/.claude/settings.json"
bash "$ROOT/bin/install-settings.sh" --quiet
dx_set_session_messaging_preference on
assert_eq global "$(dx_claude_global_hooks_state)" 'gated install'
dx_remove_claude_global_hooks > "$TMP_DIR/remove.out"
assert_eq '{"theme": "dark"}' \
  "$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$HOME/.claude/settings.json")" \
  'settings after --no-global-hooks'
assert_eq on "$(dx_session_messaging_preference)" 'session-messaging answer kept'
assert_eq '[]' "$(python3 "$HELPER" state-dirs "$HOME/.claude/.dex-install-state.json")" 'managed dirs forgotten'

# Older Dex wrote ~/.claude/settings.json whatever CLAUDE_CONFIG_DIR said, so
# with CLAUDE_CONFIG_DIR set a hook there is still found and taken back.
python3 "$HELPER" merge-settings "$HOME/.claude/settings.json" "$ROOT/settings.json" \
  "$ROOT" "$HOME" > "$TMP_DIR/legacy.json"
mv "$TMP_DIR/legacy.json" "$HOME/.claude/settings.json"
mkdir -p "$TMP_DIR/config-dir"
export CLAUDE_CONFIG_DIR="$TMP_DIR/config-dir"
assert_eq stale "$(dx_claude_global_hooks_state)" 'old hooks Claude does not read'
dx_check_claude_settings > "$TMP_DIR/stale.out" 2>&1 || true
assert_contains "Claude does not read while CLAUDE_CONFIG_DIR is set" "$TMP_DIR/stale.out"
assert_not_contains "run twice" "$TMP_DIR/stale.out"
dx_remove_claude_global_hooks > "$TMP_DIR/remove-legacy.out"
assert_eq none "$(dx_claude_global_hooks_state)" 'legacy hooks removed'
assert_not_contains '/hooks/' "$HOME/.claude/settings.json"
unset CLAUDE_CONFIG_DIR

# ── the /dxloop skill ─────────────────────────────────────────────────────
# Activation belongs to the dxloop wrapper, which launches through
# dx_provider_claude. The skill hands over a terminal command and never writes
# loop state from a plain session.
if grep -Eq '\.active|activate-loop|DX_LOOP_DIR|\.dex-loops|touch ' "$ROOT/skills/dxloop/SKILL.md"; then
  fail 'skills/dxloop/SKILL.md writes loop activation state'
fi
grep -Fq "dxloop '<prompt>'" "$ROOT/skills/dxloop/SKILL.md" || assert_at $LINENO

printf 'launch settings tests passed\n'
