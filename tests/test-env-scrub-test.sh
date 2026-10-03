#!/usr/bin/env bash
# dex-test-lane: fast
# A test run directly (`bash tests/<name>-test.sh`) from a Dex session or the
# workspace dev shell must not inherit that shell's Dex settings: opt-outs such
# as DEXCODE_SYNC=0 or DX_RTK_ENABLED=0 flip what the test exercises, and a
# live DEX_RUN_ID sends events into the caller's run. tests/helpers.sh clears
# them; tests/run-all.sh already starts each test from `env -i`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-test-env-scrub-test.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# child_env <hermetic:0|1> — the environment a test sees after sourcing
# helpers, started from a polluted caller shell.
child_env() {
  local hermetic="$1"
  env -u DX_TEST_HERMETIC \
    DEXCODE_SYNC=0 DEXCODE_CONTEXT_SYNC=0 DEXCODE_SYNC_REQUIRED=1 DEX_FACTORY_SYNC=0 \
    DX_RTK_ENABLED=0 DX_RTK_BIN=/caller/rtk DEX_OFFLINE=1 DEX_TEST_JOBS=3 DEX_TEST_REAL_GIT=/caller/git \
    DEX_SESSION_ID=caller-session DEX_RUN_ID=caller-run DEX_HOME=/caller/dex-home \
    DX_STATE_DIR=/caller/state DEX_ROUTER_HOME=/caller/router \
    DEX_DIR=/checkout/under/test DX_TEST_LANES=fast DEX_TEST_CURRENT_NAME=caller-test \
    DX_HOST_MEMORY_FREE_PERCENT=7 DEX_PROBE_REAL_CLAUDE=1 \
    bash -c 'if [[ "$1" == 1 ]]; then export DX_TEST_HERMETIC=1; fi
      source "$2/tests/helpers.sh"
      env' child "$hermetic" "$ROOT" > "$TMP_DIR/env.$hermetic"
}

child_env 0
for name in DEXCODE_SYNC DEXCODE_CONTEXT_SYNC DEXCODE_SYNC_REQUIRED DEX_FACTORY_SYNC \
  DX_RTK_ENABLED DX_RTK_BIN DEX_OFFLINE DEX_SESSION_ID DEX_RUN_ID DX_STATE_DIR DEX_ROUTER_HOME \
  DEX_TEST_JOBS DEX_TEST_REAL_GIT; do
  if grep -q "^$name=" "$TMP_DIR/env.0"; then
    fail "a direct run kept the caller's $name"
  fi
done
grep -qx 'DEX_DIR=/checkout/under/test' "$TMP_DIR/env.0" || fail 'a direct run dropped DEX_DIR'
grep -qx 'DX_TEST_LANES=fast' "$TMP_DIR/env.0" || fail 'a direct run dropped DX_TEST_* settings'
grep -qx 'DEX_TEST_CURRENT_NAME=caller-test' "$TMP_DIR/env.0" || fail 'a direct run dropped DEX_TEST_CURRENT_NAME'
grep -qx 'DX_HOST_MEMORY_FREE_PERCENT=7' "$TMP_DIR/env.0" || fail 'a direct run dropped DX_HOST_MEMORY_FREE_PERCENT'
# The real-CLI probe tests read their opt-in after sourcing helpers.
grep -qx 'DEX_PROBE_REAL_CLAUDE=1' "$TMP_DIR/env.0" || fail 'a direct run dropped DEX_PROBE_REAL_CLAUDE'
# Dex state goes to a fresh temporary DEX_HOME, never the caller's.
dex_home=$(sed -n 's/^DEX_HOME=//p' "$TMP_DIR/env.0")
[[ -n "$dex_home" && "$dex_home" != /caller/dex-home ]] || fail "a direct run kept DEX_HOME=$dex_home"
[[ -d "$dex_home" ]] || assert_at $LINENO
rm -rf "$dex_home"

# Under run-all the runner already chose every value: helpers leaves them be.
child_env 1
grep -qx 'DEXCODE_SYNC=0' "$TMP_DIR/env.1" || fail 'a hermetic run lost DEXCODE_SYNC'
grep -qx 'DEX_HOME=/caller/dex-home' "$TMP_DIR/env.1" || fail 'a hermetic run lost DEX_HOME'
grep -qx 'DX_STATE_DIR=/caller/state' "$TMP_DIR/env.1" || fail 'a hermetic run lost DX_STATE_DIR'

printf 'test-env-scrub-test: ok\n'
