#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# dex install — one-time global setup
# SC2088 suppressed: tilde in display strings is intentionally literal (e.g., "~/.claude/skills").
set -euo pipefail

if [[ -z "${DEX_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  DEX_DIR="$(dirname "$SCRIPT_DIR")"
  export DEX_DIR
fi
source "$DEX_DIR/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"
ZSHRC="$HOME/.zshrc"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
INSTALL_FAILED=0
SHELL_INTEGRATION=1

usage() {
  cat <<'USAGE'
Usage: dx install [--no-shell-integration]

Install Dex skills, hooks, tools, and shell integration for the current user.

Options:
  --no-shell-integration  Leave ~/.zshrc alone and print how to put Dex on
                          PATH from a dev shell or .envrc instead
  -h, --help              Show this help
USAGE
}

# Builtins only: a failed preflight prints this, and install's callers may
# run it with a PATH that has no cat.
dev_shell_instructions() {
  printf '%s\n' \
    "To use Dex without a shell rc, add this to a dev shell or .envrc:" \
    "  export DEX_DIR=\"$DEX_DIR\"" \
    '  export PATH="$DEX_DIR/shims:$PATH"' \
    "dx, dxls, dxrm and the rest then run as commands. dxcd prints its target" \
    'instead of changing directory: d=$(dxcd NAME) && cd "$d".'
}

show_help=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help=1 ;;
    --no-shell-integration) SHELL_INTEGRATION=0 ;;
    *)
      dx_error "Unknown install option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done
if [[ $show_help -eq 1 ]]; then
  usage
  exit 0
fi

echo "Dex — Global Install"
echo ""

# Everything Dex does at run time needs these three; finding out at first
# `dx` run is a worse experience than hearing it now.
for required_tool in git python3 zsh; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    dx_error "Missing required tool: $required_tool. Install it and rerun 'dx install'."
    exit 1
  fi
done
if ! command -v gh >/dev/null 2>&1; then
  dx_warn "GitHub CLI (gh) not found. PR creation, reviewer routing, and CI watching need it."
elif ! dx_github_pr_attachments_supported; then
  dx_warn "GitHub CLI does not support 'gh pr edit --attach'. Upgrade it to publish UI proof automatically."
fi

# Preflight: everything that would stop the install part-way, checked before
# anything is written. A read-only rc (home-manager links it into the Nix
# store; -w follows the link) used to abort only after the skills, settings
# and tools were already in place.
preflight_problems=()
if [[ -e "$CLAUDE_DIR" ]]; then
  [[ -d "$CLAUDE_DIR" && -w "$CLAUDE_DIR" ]] || preflight_problems+=("~/.claude is not a writable directory")
elif [[ ! -w "$HOME" ]]; then
  preflight_problems+=("~/.claude does not exist and $HOME is not writable")
fi
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  current=$(readlink "$CLAUDE_DIR/skills")
  [[ "$current" == "$DEX_DIR/skills" ]] \
    || preflight_problems+=("~/.claude/skills points to $current; remove it or choose a clean install target")
elif [[ -e "$CLAUDE_DIR/skills" && ! -d "$CLAUDE_DIR/skills" ]]; then
  preflight_problems+=("~/.claude/skills exists and is not a directory; remove it or choose a clean install target")
fi
if [[ -e "$SETTINGS_FILE" || -L "$SETTINGS_FILE" ]] && [[ ! -f "$SETTINGS_FILE" || ! -w "$SETTINGS_FILE" ]]; then
  preflight_problems+=("~/.claude/settings.json is not a writable file")
fi
if [[ $SHELL_INTEGRATION -eq 1 ]] && ! grep -qE "$DX_ZSHRC_SOURCE_ACTIVE_PATTERN" "$ZSHRC" 2>/dev/null; then
  if [[ -e "$ZSHRC" || -L "$ZSHRC" ]]; then
    [[ -w "$ZSHRC" ]] || preflight_problems+=("~/.zshrc is not writable (a home-manager or Nix-managed rc?); rerun with --no-shell-integration")
  elif [[ ! -w "$HOME" ]]; then
    preflight_problems+=("~/.zshrc does not exist and $HOME is not writable; rerun with --no-shell-integration")
  fi
fi
if [[ ${#preflight_problems[@]} -gt 0 ]]; then
  for problem in "${preflight_problems[@]}"; do
    dx_error "$problem"
  done
  echo ""
  dev_shell_instructions
  echo ""
  dx_error "Nothing was installed."
  exit 1
fi

# Ensure ~/.claude directory exists (Claude Code normally creates it, but we
# need it before creating symlinks)
mkdir -p "$CLAUDE_DIR"

# 1. Symlink skills (preflight refused a link that points elsewhere)
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  dx_ok "~/.claude/skills → $DEX_DIR/skills"
elif [[ -d "$CLAUDE_DIR/skills" ]]; then
  if ! dx_install_claude_skill_links "$CLAUDE_DIR/skills"; then
    dx_warn "Continuing install after incomplete Claude skill link setup"
    INSTALL_FAILED=1
  fi
else
  if ln -s "$DEX_DIR/skills" "$CLAUDE_DIR/skills"; then
    dx_done "Symlinked ~/.claude/skills → $DEX_DIR/skills"
  else
    dx_error "Failed to symlink ~/.claude/skills"
    INSTALL_FAILED=1
  fi
fi

# 2. Install conservative Claude/Codex tooling.
if ! dx_bootstrap_agent_tooling "" "install"; then
  dx_warn "Continuing install without complete Claude/Codex tooling bootstrap"
  INSTALL_FAILED=1
fi

# 3. Source dx.sh in ~/.zshrc
if [[ $SHELL_INTEGRATION -eq 0 ]]; then
  dx_skip "Shell integration (--no-shell-integration); ~/.zshrc left unchanged"
elif grep -qE "$DX_ZSHRC_SOURCE_ACTIVE_PATTERN" "$ZSHRC" 2>/dev/null; then
  dx_ok "dx.sh already sourced in ~/.zshrc"
else
  {
    echo ""
    echo "# Dex"
    echo "export DEX_DIR=\"$DEX_DIR\""
    echo "source \"\$DEX_DIR/dx.sh\""
  } >> "$ZSHRC"
  dx_done "Added DEX_DIR export and source to ~/.zshrc"
fi

# Warn users whose login shell is not zsh; a sourced dx.sh requires zsh. The
# shims run it under zsh themselves, from any shell.
if [[ $SHELL_INTEGRATION -eq 1 && "${SHELL:-}" != */zsh ]]; then
  dx_warn "Your current shell is '${SHELL:-unknown}'. Dex requires zsh — dx.sh uses zsh-only syntax."
  dx_warn "Switch to zsh (chsh -s \$(which zsh)) or source ~/.zshrc from a zsh session to use Dex."
fi

# 4. Make scripts executable. The .py files stay as Git shipped them: every
# caller runs them through python3, and re-flipping shell_parse.py's mode
# would dirty the checkout.
if chmod +x "$DEX_DIR/hooks/"*.sh "$DEX_DIR/bin/"*.sh 2>/dev/null; then
  dx_done "Made scripts executable"
else
  dx_error "Failed to make Dex scripts executable"
  INSTALL_FAILED=1
fi

if [[ $INSTALL_FAILED -ne 0 ]]; then
  echo ""
  dx_error "Install incomplete. Fix the warnings above, then run 'dx install' again."
  exit 1
fi

echo ""
if [[ $SHELL_INTEGRATION -eq 1 ]]; then
  echo "Install complete. Run: source ~/.zshrc"
else
  echo "Install complete."
  echo ""
  dev_shell_instructions
fi
echo ""
echo "Next: cd to a repo and run 'dx init' to bootstrap it."
