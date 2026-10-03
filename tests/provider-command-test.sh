#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-provider-command-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
# The legacy ~/.dex/providers.json layout under this HOME.
unset DEX_HOME
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export CODEX_HOME="$TMP_DIR/codex-home"
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/repo/.dex"

# Keep the provider doctor isolated from any real Claude or Codex installation.
for tool in python3 git grep find basename dirname env; do
  tool_path=$(command -v "$tool")
  ln -s "$tool_path" "$TMP_DIR/bin/$tool"
done
# Node is optional for Dex, and the router readiness check below turns on
# whether this shell can see one. Resolve it before the sandbox narrows PATH.
host_node=$(command -v node 2>/dev/null || true)
export PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cat > "$TMP_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
  printf '%s\n' "Logged in with ChatGPT"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config" "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "review" && "${3:-}" == "--help" ]]; then
  printf '%s\n' "--ignore-user-config" "--dangerously-bypass-approvals-and-sandbox"
  exit 0
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/codex"

git -C "$TMP_DIR/repo" init -q
git -C "$TMP_DIR/repo" config user.email dex@example.test
git -C "$TMP_DIR/repo" config user.name "Dex Test"
git -C "$TMP_DIR/repo" commit -q --allow-empty -m init

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

while IFS= read -r env_name; do
  [[ -n "$env_name" ]] && unset "$env_name"
done < <(dx_provider_external_env_names)
while IFS= read -r env_name; do
  [[ -n "$env_name" ]] && unset "$env_name"
done < <(dx_provider_claude_override_env_names)
unset DX_AGENT_OVERRIDE DX_MODEL_OVERRIDE DX_ALLOW_API_BILLED_AUTH
export DX_PROVIDER_PROFILE="codex-subscription"
dx_install_codex_skills >/dev/null

assert_fails_with() {
  local expected="$1"
  shift
  local output status
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    printf 'expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf 'expected failure to contain %s, got:\n%s\n' "$expected" "$output" >&2
    exit 1
  fi
}

cd "$TMP_DIR/repo"
doctor_output=$(dx_provider_command doctor 2>&1)
grep -Fq "direct Codex delegation does not require it" <<<"$doctor_output"
grep -Fq "Codex is logged in with ChatGPT" <<<"$doctor_output"
grep -Fq "Dex Codex skills linked" <<<"$doctor_output"
dx_provider_agent_ready_check
provider_prompt=$(dx_provider_prompt)
grep -Fq "already running through Dex's signed-in Codex CLI wrapper" <<<"$provider_prompt"
if grep -Fq "Claude Code remains the outer lifecycle harness" <<<"$provider_prompt"; then
  printf 'Codex provider prompt still described a Claude outer harness\n' >&2
  exit 1
fi

export DX_PROVIDER_PROFILE="claude-subscription"
dx_provider_apply
assert_fails_with "Claude Code CLI not found; the claude-subscription profile cannot launch work." \
  dx_provider_agent_ready_check
export DX_PROVIDER_PROFILE="codex-subscription"
dx_provider_apply

assert_fails_with "Usage: dx provider list" dx_provider_command list unexpected
assert_fails_with "Usage: dx provider current" dx_provider_command current unexpected
assert_fails_with "Usage: dx provider doctor" dx_provider_command doctor unexpected
assert_fails_with "Usage: dx provider use [--repo] <profile>" dx_provider_command use claude-subscription unexpected
assert_fails_with "Usage: dx provider help" dx_provider_command help unexpected
[[ ! -e "$HOME/.dex/providers.json" ]] || assert_at $LINENO

cd "$TMP_DIR"
assert_fails_with "Cannot set a repo provider profile outside a git repository." \
  dx_provider_command use --repo claude-subscription

cat > "$TMP_DIR/repo/.dex/providers.json" <<'JSON'
{
  "default": "broken",
  "profiles": {
    "broken": {
      "engine": "claude",
      "auth": "subscription",
      "unknown_field": "value"
    }
  }
}
JSON

cd "$TMP_DIR/repo"
assert_fails_with "Reason: profile 'broken' has unknown key 'unknown_field'" \
  dx_provider_command list

# The selection marker follows resolution; default labels describe saved settings.
rm -f "$TMP_DIR/repo/.dex/providers.json"
(
  unset DX_PROVIDER_PROFILE DX_AGENT DX_AGENT_OVERRIDE DX_MODEL DX_MODEL_OVERRIDE DX_EFFORT DX_EFFORT_OVERRIDE
  list_file="$TMP_DIR/provider-list.txt"
  repo_config=$(dx_provider_repo_config)
  dx_provider_command list > "$list_file"
  assert_contains "Global default: claude-subscription (built-in fallback)" "$list_file"
  assert_contains "Selected profile: claude-subscription" "$list_file"
  grep -Eq '^\* +claude-subscription +built-in +global default ' "$list_file"
  assert_contains "CCR subscription accounts: dx accounts" "$list_file"
  assert_contains "Add another account: dx account add" "$list_file"

  dx_provider_command use ccr-subscription >/dev/null
  dx_provider_command list > "$list_file"
  assert_contains "Global default: ccr-subscription" "$list_file"
  grep -Eq '^\* +ccr-subscription +built-in +global default ' "$list_file"
  [[ $(grep -c 'profiles in ' "$list_file") == 0 ]] || assert_at $LINENO

  dx_provider_command use --repo codex-subscription >/dev/null
  dx_provider_command list > "$list_file"
  assert_contains "Repository default: codex-subscription" "$list_file"
  assert_contains "Repository config: $repo_config" "$list_file"
  grep -Eq '^\* +codex-subscription +built-in +repo default ' "$list_file"
  grep -Eq '^ +ccr-subscription +built-in +global default ' "$list_file"

  DX_PROVIDER_PROFILE=claude-subscription dx_provider_command list > "$list_file"
  grep -Eq '^\* +claude-subscription ' "$list_file"
  grep -Eq '^ +codex-subscription +built-in +repo default ' "$list_file"
  DX_AGENT_OVERRIDE=claude dx_provider_command list > "$list_file"
  grep -Eq '^\* +ccr-subscription +built-in +global default ' "$list_file"

  # Same-named custom profiles must only mark the selected definition.
  for config_file in "$DX_PROVIDER_GLOBAL_CONFIG" "$TMP_DIR/repo/.dex/providers.json"; do
    cat > "$config_file" <<'JSON'
{"profiles":{"shared":{"engine":"claude","auth":"subscription"}}}
JSON
  done
  dx_provider_command use shared >/dev/null
  dx_provider_command list > "$list_file"
  grep -Eq '^\* +shared +global +global default ' "$list_file"
  [[ $(grep -c '^\* ' "$list_file") == 1 ]] || assert_at $LINENO

  dx_provider_command use --repo shared >/dev/null
  dx_provider_command list > "$list_file"
  grep -Eq '^\* +shared +repo +repo default ' "$list_file"
  [[ $(grep -c '^\* ' "$list_file") == 1 ]] || assert_at $LINENO

  # A bad override must leave the list available for finding a valid profile.
  DX_PROVIDER_PROFILE=missing-profile dx_provider_command list > "$list_file" 2>&1
  assert_contains "Run 'dx provider list' to see available profiles." "$list_file"
  assert_contains "Selected profile: unresolved" "$list_file"
  assert_contains "Global config: $DX_PROVIDER_GLOBAL_CONFIG" "$list_file"
  [[ $(grep -c '^\* ' "$list_file") == 0 ]] || assert_at $LINENO
)
rm -f "$DX_PROVIDER_GLOBAL_CONFIG" "$TMP_DIR/repo/.dex/providers.json"

# Gateway profiles with api-token auth must launch through BSD env, where
# options must precede NAME=VALUE operands (regression: a -u flag appended
# after the assignments made every gateway launch exit 127 on macOS).
rm -f "$TMP_DIR/repo/.dex/providers.json"
mkdir -p "$HOME/.dex"
cat > "$HOME/.dex/providers.json" <<'JSON'
{
  "profiles": {
    "test-gateway": {
      "engine": "anthropic-gateway",
      "auth": "api-token",
      "model": "claude-test-model",
      "base_url": "https://gateway.example.test",
      "auth_env": "DEX_TEST_GATEWAY_TOKEN"
    }
  }
}
JSON
cat > "$TMP_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'claude-stub token=%s base=%s leaked=%s sync=%s factory_url=%s\n' \
  "${ANTHROPIC_AUTH_TOKEN:-}" "${ANTHROPIC_BASE_URL:-}" "${DEX_TEST_GATEWAY_TOKEN:-absent}" \
  "${DEX_FACTORY_SYNC:-absent}" "${DEX_FACTORY_URL:-absent}"
SH
chmod +x "$TMP_DIR/bin/claude"
export DX_PROVIDER_PROFILE="test-gateway"
export DEX_TEST_GATEWAY_TOKEN="gateway-secret"
# Factory sync coordinates must not leak into the launched session: its
# tokens are stripped, so an inherited sync flag only produces per-event
# configuration errors.
export DEX_FACTORY_SYNC="true"
export DEX_FACTORY_URL="https://factory.example.test"
dx_provider_apply
set +e
gateway_output=$(dx_provider_claude 2>&1)
gateway_status=$?
set -e
if [[ $gateway_status -ne 0 ]]; then
  printf 'gateway launch failed (%s):\n%s\n' "$gateway_status" "$gateway_output" >&2
  exit 1
fi
grep -Fq "token=gateway-secret" <<<"$gateway_output"
grep -Fq "base=https://gateway.example.test" <<<"$gateway_output"
grep -Fq "leaked=absent" <<<"$gateway_output"
grep -Fq "sync=absent" <<<"$gateway_output"
grep -Fq "factory_url=absent" <<<"$gateway_output"
unset DEX_TEST_GATEWAY_TOKEN DEX_FACTORY_SYNC DEX_FACTORY_URL
rm -f "$HOME/.dex/providers.json" "$TMP_DIR/bin/claude"
export DX_PROVIDER_PROFILE="codex-subscription"
dx_provider_apply

# dx_agent_normalize answers on stdout, so every caller reads it through $( ).
# The line naming the agents that do work went to stdout too, which meant it
# was captured with the value and discarded: `dx --agent gpt4` said only
# "Unsupported agent: gpt4" and left the user to guess the alternatives.
if dx_agent_normalize gpt4 > "$TMP_DIR/agent-stdout.txt" 2> "$TMP_DIR/agent-stderr.txt"; then
  printf 'dx_agent_normalize accepted an unsupported agent\n' >&2
  exit 1
fi
assert_contains "Unsupported agent: gpt4" "$TMP_DIR/agent-stderr.txt"
assert_contains "Supported agents: claude, codex" "$TMP_DIR/agent-stderr.txt"
if [[ -s "$TMP_DIR/agent-stdout.txt" ]]; then
  printf 'dx_agent_normalize wrote diagnostics onto its own return value:\n' >&2
  cat "$TMP_DIR/agent-stdout.txt" >&2
  exit 1
fi

# And the answer itself is still exactly the value, nothing more.
assert_eq "claude" "$(dx_agent_normalize claude)" "normalized claude"
assert_eq "codex" "$(dx_agent_normalize Codex)" "normalized Codex"

# Native routing installs the gateway into the user's Claude settings, so a
# direct profile still reaches CCR. Without the readiness check following it
# there, an unusable router answers every request with a retrying 503 from the
# gateway instead of Dex naming the account to repair.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/bin/claude"
chmod +x "$TMP_DIR/bin/claude"
[[ -z "$host_node" ]] || ln -sf "$host_node" "$TMP_DIR/bin/node"
export DEX_ROUTER_HOME="$TMP_DIR/router"
mkdir -p "$DEX_ROUTER_HOME"
chmod 700 "$DEX_ROUTER_HOME"
export DX_PROVIDER_PROFILE="claude-subscription"
dx_provider_apply

write_router_config() {
  printf '{"version":1,"enabled":true,"models":[],"native":{"enabled":%s}}\n' "$1" > "$DEX_ROUTER_HOME/config.json"
  chmod 600 "$DEX_ROUTER_HOME/config.json"
}

# No router config at all is the ordinary case: nothing consults CCR.
[[ ! -e "$DEX_ROUTER_HOME/config.json" ]] || assert_at $LINENO
dx_provider_agent_ready_check || assert_at $LINENO

# Routing enabled but scoped to the ccr-subscription profile leaves a direct
# launch alone, because plain claude keeps its own subscription.
write_router_config false
dx_provider_agent_ready_check || assert_at $LINENO

# Native routing on, and no account the router can use: refuse with the reason.
# Needs a real Node, because that is what decides whether the check can run.
write_router_config true
if [[ -n "$host_node" ]]; then
  assert_fails_with "Native routing sends every Claude Code launch through CCR" \
    dx_provider_agent_ready_check
  assert_fails_with "dx router native disable" dx_provider_agent_ready_check
fi

# The client settings reach the gateway through an absolute interpreter, so a
# Node this shell cannot see, or one too old to run the router, says nothing
# about whether the router works. A verdict we could not reach must not stop a
# launch that would have succeeded.
rm -f "$TMP_DIR/bin/node"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_DIR/bin/node"
chmod +x "$TMP_DIR/bin/node"
dx_provider_agent_ready_check || assert_at $LINENO
rm -f "$TMP_DIR/bin/node"

rm -f "$TMP_DIR/bin/claude"
unset DEX_ROUTER_HOME
export DX_PROVIDER_PROFILE="codex-subscription"
dx_provider_apply

# --agent claude keeps a matching ccr-subscription default. With no enabled CCR
# account behind it that profile cannot launch, so the launch path refuses up
# front, naming the profile, where it came from and the ways out. An enabled
# account, an explicit profile, and the plain no-override path are unchanged.
(
  cd "$TMP_DIR/repo"
  export DEX_ROUTER_HOME="$TMP_DIR/router-accounts"
  mkdir -p "$DEX_ROUTER_HOME"
  chmod 700 "$DEX_ROUTER_HOME"
  unset DX_PROVIDER_PROFILE
  refresh_as_claude() { DX_AGENT_OVERRIDE=claude __dx_refresh_provider; }
  write_accounts() {
    printf '{"version":1,"accounts":[{"id":"one","name":"main","provider":"anthropic","enabled":%s}]}\n' \
      "$1" > "$DEX_ROUTER_HOME/accounts.json"
    chmod 600 "$DEX_ROUTER_HOME/accounts.json"
  }

  printf '%s\n' '{"default":"ccr-subscription"}' > .dex/providers.json
  assert_fails_with "resolved to ccr-subscription, this repository's default in .dex/providers.json" refresh_as_claude
  assert_fails_with "but CCR has no enabled account" refresh_as_claude
  assert_fails_with "dx provider use claude-subscription" refresh_as_claude
  assert_fails_with "dx account add" refresh_as_claude
  assert_fails_with "DX_PROVIDER_PROFILE=claude-subscription" refresh_as_claude
  write_accounts false
  assert_fails_with "but CCR has no enabled account" refresh_as_claude
  write_accounts true
  refresh_as_claude || assert_at $LINENO
  [[ "$DX_PROVIDER_PROFILE_RESOLVED" == ccr-subscription ]] || assert_at $LINENO
  rm -f "$DEX_ROUTER_HOME/accounts.json"
  # A registry Dex cannot read is the router's to judge.
  printf '{broken\n' > "$DEX_ROUTER_HOME/accounts.json"
  refresh_as_claude || assert_at $LINENO
  rm -f "$DEX_ROUTER_HOME/accounts.json"

  # Not an agent override: the user chose the profile, so the router decides.
  DX_PROVIDER_PROFILE=ccr-subscription __dx_refresh_provider || assert_at $LINENO
  __dx_refresh_provider || assert_at $LINENO
  [[ "$DX_PROVIDER_PROFILE_RESOLVED" == ccr-subscription ]] || assert_at $LINENO
  # Listing profiles never launches, so it never refuses.
  DX_AGENT_OVERRIDE=claude dx_provider_command list > "$TMP_DIR/agent-list.out" 2>&1 \
    || { cat "$TMP_DIR/agent-list.out" >&2; assert_at $LINENO; }

  # The same from the user's default.
  rm -f .dex/providers.json
  dx_provider_command use ccr-subscription >/dev/null
  assert_fails_with "your default in $DX_PROVIDER_GLOBAL_CONFIG" refresh_as_claude
  # A repo default for another agent is skipped, as before.
  printf '%s\n' '{"default":"codex-subscription"}' > .dex/providers.json
  assert_fails_with "your default in $DX_PROVIDER_GLOBAL_CONFIG" refresh_as_claude
  rm -f .dex/providers.json "$DX_PROVIDER_GLOBAL_CONFIG"
  # No configured default: --agent claude is the built-in direct profile.
  refresh_as_claude || assert_at $LINENO
  [[ "$DX_PROVIDER_PROFILE_RESOLVED" == claude-subscription ]] || assert_at $LINENO
)

printf 'provider command tests passed\n'
