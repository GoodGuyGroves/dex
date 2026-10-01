#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# dex uninstall — remove global installation
# SC2088 suppressed: tilde in display strings is intentionally literal (e.g., "~/.claude/skills").
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"
INSTALL_STATE_FILE="$CLAUDE_DIR/.dex-install-state.json"
ZSHRC="$HOME/.zshrc"

usage() {
  cat <<'USAGE'
Usage: dx uninstall

Remove Dex's global skills, hooks, and shell integration for the current user.
The Dex source checkout is left in place.

Options:
  -h, --help  Show this help
USAGE
}

show_help=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help=1 ;;
    *)
      dx_error "Unknown uninstall option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done
if [[ $show_help -eq 1 ]]; then
  usage
  exit 0
fi

echo "Dex — Global Uninstall"
echo ""

uninstall_failed=0

# 1. Remove Claude skill links (only those pointing into Dex)
dx_remove_claude_skill_links || true

# 2. Remove Codex skill links
if ! dx_uninstall_codex_skills; then
  dx_warn "Continuing uninstall after incomplete Codex skill cleanup"
fi

# Remove marker-owned Codex instructions and Dex's RTK PATH link. Downloaded
# tool and artifact caches stay in place so uninstall never discards evidence.
if ! dx_uninstall_rtk_codex_instructions; then
  dx_warn "Continuing uninstall after incomplete RTK instruction cleanup"
  uninstall_failed=1
fi

# 3. Remove global Dex hooks and Dex-managed worktree settings, keeping the
# user's own entries. A failure keeps the install state for the next attempt.
if dx_remove_claude_global_hooks; then
  rm -f "$INSTALL_STATE_FILE" 2>/dev/null || true
else
  uninstall_failed=1
fi

# 5. Remove source line and Dex comment from zshrc
if grep -qE "$DX_ZSHRC_SOURCE_ACTIVE_PATTERN" "$ZSHRC" 2>/dev/null; then
  # -x matches entire line; removes "# Dex" or "# Dex — ..." exact lines.
  # Also removes the DEX_DIR export and source lines. The source-line pattern
  # is anchored to source/. commands: the old bare 'dex.*dx\.sh' also deleted
  # any user line that merely mentioned both strings (an alias, a comment).
  # grep -v exits 1 when no lines survive filtering (valid when .zshrc
  # contained only Dex lines), so 1 is tolerated — but higher codes are real
  # errors, and an unchecked write here once meant a failed filter could
  # truncate the user's ~/.zshrc.
  zshrc_filter_status=0
  zshrc_filtered=$(grep -vxE '# Dex( —.*)?' "$ZSHRC" | grep -vE '^export DEX_DIR=' \
    | grep -vE "^[[:space:]]*(source|\.)[[:space:]].*(${DX_ZSHRC_SOURCE_PATTERN})") \
    || zshrc_filter_status=$?
  if [[ $zshrc_filter_status -le 1 ]] \
    && printf '%s\n' "$zshrc_filtered" > "${ZSHRC}.tmp" \
    && mv "${ZSHRC}.tmp" "$ZSHRC"; then
    dx_done "Removed Dex lines from ~/.zshrc"
  else
    rm -f "${ZSHRC}.tmp" 2>/dev/null || true
    dx_error "Could not rewrite ~/.zshrc; it was left unchanged. Remove the Dex lines by hand."
    uninstall_failed=1
  fi
else
  dx_skip "No Dex source line in ~/.zshrc"
fi

echo ""
if [[ $uninstall_failed -eq 1 ]]; then
  dx_error "Uninstall finished with incomplete settings cleanup. Resolve the errors above and run 'dx uninstall' again."
  exit 1
fi

echo "Uninstall complete. Run: source ~/.zshrc"
echo ""
echo "Note: $DEX_DIR was NOT deleted. Remove it manually if you want."
dx_info "Tool and artifact caches were retained under ${DX_TOOL_DIR:-$HOME/.claude/.dex-tools} and ${DX_ARTIFACT_DIR:-$HOME/.claude/.dex-artifacts}."
