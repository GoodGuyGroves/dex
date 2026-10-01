#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

printf 'config reviewer tests passed\n'
