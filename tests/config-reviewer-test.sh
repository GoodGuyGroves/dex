#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
# config.sh runs below on PATH=/usr/bin:/bin. On macOS /usr/bin/git is the
# xcrun shim, which looks for git under DEVELOPER_DIR; a Nix dev shell points
# that at an Apple SDK with no git, so git fails and config.sh reports "Not in
# a git repository". run-all.sh starts tests from `env -i`, so only a direct
# run inherits these.
unset DEVELOPER_DIR SDKROOT
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-config-reviewer-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
mkdir -p "$HOME" "$TMP_DIR/repo/.dex"

git init -q "$TMP_DIR/repo"
git -C "$TMP_DIR/repo" config user.email test@example.com
git -C "$TMP_DIR/repo" config user.name Test
printf '%s\n' '# Dex project' '## Workflow' 'Keep this section.' > "$TMP_DIR/repo/.dex/dex.md"

(
  cd "$TMP_DIR/repo"
  printf '%s\n' \
    3 n n n n n n n \
    'bad|handle request' \
    'octocat request extra' \
    'octocat request wait=maybe' \
    'valid-user request' \
    '@greptileai mention wait=yes adapter=greptile' \
    'greptile-apps mention wait=yes' \
    'github-copilot request wait=yes' \
    '@example/team-name mention' \
    '' \
    | PATH=/usr/bin:/bin bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/config.out" 2>&1

grep -q "Invalid handle 'bad|handle'" "$TMP_DIR/config.out"
grep -q 'enter exactly one handle and one type' "$TMP_DIR/config.out"
grep -q '^| Handle | Type | Wait | Adapter | Notes |$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^| valid-user | request | no | generic | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^| @example/team-name | mention | no | generic | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^| @greptileai | mention | yes | greptile | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"
# wait=yes with no adapter infers the bot's adapter instead of writing generic.
grep -q '^| greptile-apps | mention | yes | greptile | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^| github-copilot | request | yes | copilot | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"
if grep -q 'bad|handle\|octocat' "$TMP_DIR/repo/.dex/dex.md"; then
  printf 'invalid reviewer input reached dex.md\n' >&2
  exit 1
fi
grep -q '^## Workflow$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^Keep this section\.$' "$TMP_DIR/repo/.dex/dex.md"

# A rerun keeps Wait/Adapter values for reviewers that stay, and the default
# Copilot row uses the copilot adapter.
(
  cd "$TMP_DIR/repo"
  printf '%s\n' \
    3 n n n n n n y \
    '@greptileai mention' \
    '' \
    | PATH=/usr/bin:/bin bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/config2.out" 2>&1
grep -q '^| Copilot | request | no | copilot | GitHub Copilot review |$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^| @greptileai | mention | yes | greptile | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"
if grep -q 'valid-user' "$TMP_DIR/repo/.dex/dex.md"; then
  printf 'a reviewer that was not re-entered survived the rerun\n' >&2
  exit 1
fi

# An explicit `generic` on a waited row survives a rerun too, even for a bot
# handle whose blank cell would infer the bot's adapter.
sed -i.bak \
  -e 's/^| @greptileai | mention | yes | greptile |/| @greptileai | mention | yes | generic |/' \
  -e 's/^| Copilot | request | no | copilot |/| Copilot | request | yes | generic |/' \
  "$TMP_DIR/repo/.dex/dex.md"
rm -f "$TMP_DIR/repo/.dex/dex.md.bak"
(
  cd "$TMP_DIR/repo"
  printf '%s\n' \
    3 n n n n n n y \
    '@greptileai mention' \
    '' \
    | PATH=/usr/bin:/bin bash "$ROOT/bin/config.sh"
) > "$TMP_DIR/config3.out" 2>&1
grep -q '^| Copilot | request | yes | generic | GitHub Copilot review |$' "$TMP_DIR/repo/.dex/dex.md"
grep -q '^| @greptileai | mention | yes | generic | Added via dx config |$' "$TMP_DIR/repo/.dex/dex.md"

printf 'config reviewer tests passed\n'
