# shellcheck shell=bash
# Dex shared library — common constants and bootstrap
#
# Source this from any script:
#   source "$DEX_DIR/lib/common.sh"
#
# Provides: DEX_DIR, the Dex state paths resolved from DEX_HOME (DX_STATE_DIR,
# DX_LOOP_DIR, DX_ARTIFACT_DIR, DX_TOOL_DIR, DX_RUN_ROOT and the rest, below),
# dx_repo_root()
# Also sources: lib/lock.sh, lib/git.sh, lib/session.sh, lib/session-process.sh,
# lib/override.sh, lib/completion.sh,
# lib/session-runtime.sh, lib/session-catalog.sh, lib/output.sh,
# lib/host-budget.sh, lib/worktree.sh,
# lib/provider.sh, lib/codex.sh, lib/dexcode.sh, lib/ui-capture.sh, lib/rtk.sh,
# lib/events.sh, lib/review.sh, lib/review-capacity.sh, lib/review-policy.sh,
# lib/review-controller.sh, lib/review-acceptance.sh, lib/review-diagnostics.sh,
# lib/review-loop.sh, lib/factory.sh,
# lib/run-spec.sh, lib/agent-tools.sh, lib/maintenance.sh, lib/project-state.sh,
# lib/ticket.sh,
# lib/lifecycle-control.sh, lib/session-management.sh, lib/attribution.sh, and
# lib/worker.sh

if [[ -z "${DEX_DIR:-}" ]]; then
  # Auto-detect from this file's location (lib/common.sh → repo root).
  # BASH_SOURCE works in bash; $0 works in zsh when sourced.
  _dx_self="${BASH_SOURCE[0]:-$0}"
  DEX_DIR="$(cd "$(dirname "$_dx_self")/.." && pwd)"
  export DEX_DIR
  unset _dx_self
fi
# Dex state paths. DEX_HOME, when set to an absolute path, is the one root for
# all Dex state and every path below defaults beneath it; unset, each keeps
# its legacy location. An explicit value of any one of them still wins, and
# empty counts as unset. A trailing / is dropped; a relative or `~` DEX_HOME
# is ignored with a warning.
# hooks/dex_paths.py and scripts/dex-paths.cjs mirror this table for readers
# that run without this file; tests/dex-home-paths-test.sh keeps them in step.
#
# Export: with DEX_HOME set, every path is exported so hooks, spawned CLI
# sessions and review waves agree. Unset, only the original five are, as
# before; the rest stay shell variables and each child resolves its own.
#
# DX_PATHS_FROM records the DEX_HOME and HOME the exported values came from. A
# child that changed either one recomputes each path still equal to the old
# default, so `HOME=B bin/setup.sh` from a shell resolved for A writes under B.
# A value that differs from the old default is a real override and stays.

# __dx_path_default <name> <dex_home> <home> — sets __dx_default (the
# caller's local); empty when
# the name has no default in that mode (DEXCODE_CONFIG_DIR without DEX_HOME
# keeps lib/dexcode.sh's call-time XDG default).
__dx_path_default() {
  local sub legacy
  case "$1" in
    DX_STATE_DIR) sub=state legacy=.claude/.dex-phases ;;
    DX_LOOP_DIR) sub=loops legacy=.claude/.dex-loops ;;
    DX_ARTIFACT_DIR) sub=artifacts legacy=.claude/.dex-artifacts ;;
    DX_TOOL_DIR) sub=tools legacy=.claude/.dex-tools ;;
    DX_RUN_ROOT) sub=runs legacy=.dex/runs ;;
    DX_MAINTENANCE_DIR) sub=maintenance legacy=.claude/.dex-maintenance ;;
    DX_LOG_DIR) sub=logs legacy=.dex/logs ;;
    DEX_ROUTER_HOME) sub=router legacy=.dex/router ;;
    DEXCODE_CONFIG_DIR) sub=dexcode legacy= ;;
    DX_PROVIDER_GLOBAL_CONFIG) sub=providers.json legacy=.dex/providers.json ;;
    DX_SETUP_FILE) sub=setup.json legacy=.dex/setup.json ;;
    DX_INSTALL_STATE_FILE) sub=install-state.json legacy=.claude/.dex-install-state.json ;;
  esac
  if [[ -n "$2" ]]; then
    __dx_default="$2/$sub"
  elif [[ -n "$legacy" ]]; then
    __dx_default="$3/$legacy"
  else
    __dx_default=""
  fi
}

# dx_resolve_state_paths — apply the rules above to the current DEX_HOME and
# HOME. Runs when this file is sourced, and again at the top of dx.sh's public
# commands so an `export DEX_HOME=...` in an interactive shell takes effect
# without `dx reload`. No forks; with an unchanged marker it only fills gaps.
#
# ponytail: provenance is value-based. An override set to exactly the old
# default cannot be told from an inherited default, so it is recomputed when
# HOME or DEX_HOME changes; pick a path that differs from the default to keep
# it. hooks/dex_paths.py and scripts/dex-paths.cjs do not read DX_PATHS_FROM,
# so a reader started directly with another HOME uses the values it inherited.
# Upgrade path: export an explicit list of overridden names alongside it.
dx_resolve_state_paths() {
  local __dx_home="${DEX_HOME:-}" __dx_old __dx_n __dx_v __dx_default
  while [[ "$__dx_home" == ?*/ ]]; do __dx_home="${__dx_home%/}"; done
  if [[ -n "$__dx_home" && "$__dx_home" != /* ]]; then
    command -v dx_warn >/dev/null 2>&1 || source "$DEX_DIR/lib/output.sh"
    dx_warn "Ignoring DEX_HOME=$__dx_home: it must be an absolute path. Using the default state locations."
    __dx_home=""
  fi
  # Empty, relative and `~` all end up unset, so children agree.
  if [[ -n "$__dx_home" ]]; then export DEX_HOME="$__dx_home"; else unset DEX_HOME; fi
  __dx_old="${DX_PATHS_FROM:-}"
  [[ "$__dx_old" != "$__dx_home|$HOME" ]] || __dx_old=""
  for __dx_n in DX_STATE_DIR DX_LOOP_DIR DX_ARTIFACT_DIR DX_TOOL_DIR DX_RUN_ROOT \
      DX_MAINTENANCE_DIR DX_LOG_DIR DEX_ROUTER_HOME DEXCODE_CONFIG_DIR \
      DX_PROVIDER_GLOBAL_CONFIG DX_SETUP_FILE DX_INSTALL_STATE_FILE; do
    eval "__dx_v=\${$__dx_n:-}"
    if [[ -n "$__dx_v" && -n "$__dx_old" ]]; then
      __dx_path_default "$__dx_n" "${__dx_old%%|*}" "${__dx_old#*|}"
      [[ "$__dx_v" != "$__dx_default" ]] || __dx_v=""
    fi
    if [[ -z "$__dx_v" ]]; then
      __dx_path_default "$__dx_n" "$__dx_home" "$HOME"
      __dx_v="$__dx_default"
    fi
    if [[ -z "$__dx_v" ]]; then
      unset "$__dx_n"
      continue
    fi
    case "$__dx_home:$__dx_n" in
      ?*:*|*:DX_STATE_DIR|*:DX_LOOP_DIR|*:DX_ARTIFACT_DIR|*:DX_TOOL_DIR|*:DX_RUN_ROOT)
        export "$__dx_n=$__dx_v" ;;
      *) eval "$__dx_n=\$__dx_v" ;;
    esac
  done
  export DX_PATHS_FROM="$__dx_home|$HOME"
}
dx_resolve_state_paths

# Matches a ~/.zshrc line that loads Dex: the current install layout, the
# legacy dex-cli checkout name, and DEX_DIR-based source lines. Shared by
# bin/install.sh, bin/status.sh, and bin/uninstall.sh so detection and removal
# stay in lockstep.
# shellcheck disable=SC2034  # consumed by the bin/ scripts above
DX_ZSHRC_SOURCE_PATTERN='dex(-cli)?/dx\.sh|DEX_DIR.*/dx\.sh'

# The same reference, but only where it can actually run: a line whose first
# non-blank character is not `#`. Commenting the source line out is how people
# turn Dex off, and asking the bare pattern then answers "already installed"
# for a line the shell never executes — so install adds nothing, status reports
# integration that is not there, and uninstall claims a removal it did not do.
# shellcheck disable=SC2034  # consumed by the bin/ scripts above
DX_ZSHRC_SOURCE_ACTIVE_PATTERN="^[[:space:]]*[^#[:space:]].*(${DX_ZSHRC_SOURCE_PATTERN})"

# __dx_path_metadata <mode|mtime> <path>
# Python's lstat contract is the same on macOS and Linux. Native stat flags
# are not: GNU stat accepts BSD's -f flag as a different successful command.
__dx_path_metadata() {
  local field="$1" target="$2"
  python3 - "$field" "$target" <<'PY'
import os
import stat
import sys

field, target = sys.argv[1:]
try:
    metadata = os.lstat(target)
except OSError:
    raise SystemExit(1)

if field == "mode":
    print(format(stat.S_IMODE(metadata.st_mode), "o"))
elif field == "mtime":
    print(int(metadata.st_mtime))
else:
    raise SystemExit(2)
PY
}

# dx_path_mode <path> — print the path's octal permission bits.
dx_path_mode() {
  __dx_path_metadata mode "$1"
}

# dx_path_mtime <path> — print the path's modification time as epoch seconds.
dx_path_mtime() {
  __dx_path_metadata mtime "$1"
}

# dx_repo_root — print the *main* repo toplevel or return 1
# If cwd is inside a dex worktree (.dex/worktrees/<name>/...),
# returns the main repo root, not the worktree root. This prevents dx
# from creating nested worktrees when the user's shell is cd'd into one.
dx_repo_root() {
  local root
  if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
    root=""
  fi
  if [[ -z "$root" ]]; then
    echo "ERROR: Not in a git repository." >&2
    return 1
  fi
  # Escape worktree paths — strip /.dex/worktrees/<name> suffix
  if [[ "$root" == *"/.dex/worktrees/"* ]]; then
    root="${root%%/.dex/worktrees/*}"
  fi
  echo "$root"
}

# Wait cheaply. Lock retries and timeout supervisors call this many times a
# second, and a runtime owner does so for the life of its session; on a shared
# host every external `sleep` is a fork. zsh selects on nothing with a timeout,
# and bash loads its own `sleep` builtin where the platform ships it (Debian
# and Ubuntu package it as bash-builtins; Fedora installs it by default),
# falling back to the external command elsewhere. Bash's `read -t` was tried
# first: its alarm-driven timeout longjmps over a running trap handler, and
# glibc aborts bash with "longjmp causes uninitialized stack frame" whenever a
# signal lands inside a supervisor that traps it. A built-in sleep returns
# through the normal path and leaves traps to run afterwards.
dx_pause() {
  local seconds="${1:-1}"
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    if zmodload zsh/zselect 2>/dev/null; then
      local hundredths
      hundredths=$(( seconds * 100 ))
      hundredths="${hundredths%%.*}"
      [[ "$hundredths" -gt 0 ]] 2>/dev/null || hundredths=1
      zselect -t "$hundredths" 2>/dev/null || true
      return 0
    fi
  elif [[ -n "${BASH_VERSION:-}" && -z "${__DX_PAUSE_SLEEP:-}" ]]; then
    # Once per shell. A `sleep` function defined by the caller still wins over
    # the builtin, as functions do, so tests that shadow sleep keep working.
    if enable -f sleep sleep 2>/dev/null; then __DX_PAUSE_SLEEP=builtin; else __DX_PAUSE_SLEEP=external; fi
  fi
  sleep "$seconds"
}

# Source sibling libraries — guard each call so partial installs get a clear error.
__dx_require_lib() {
  local lib="$DEX_DIR/lib/$1"
  if [[ ! -f "$lib" ]]; then
    printf 'dex: missing library %s — reinstall Dex or check DEX_DIR\n' "$lib" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$lib"
}
# Fast paths that only read state can name the modules they need in
# DX_COMMON_MODULES (space-separated, without the .sh suffix, in load order).
# The status line runs on every TUI render, and loading all of lib/ — including
# the ~90KB review and dexcode modules — dominated its budget. The variable is
# deliberately not exported: a child process gets the full set unless it opts
# out for itself.
if [[ -n "${DX_COMMON_MODULES:-}" ]]; then
  # Split on whitespace explicitly: zsh does not word-split an unquoted
  # parameter, so a bare ${DX_COMMON_MODULES} loop would treat the whole
  # list as one module name there.
  while IFS= read -r _dx_module; do
    [[ -n "$_dx_module" ]] || continue
    __dx_require_lib "${_dx_module}.sh"
  done <<EOF
$(printf '%s\n' "$DX_COMMON_MODULES" | tr ' ' '\n')
EOF
  unset _dx_module
  return 0 2>/dev/null || true
fi

__dx_require_lib lock.sh
__dx_require_lib git.sh
__dx_require_lib session.sh
__dx_require_lib session-process.sh
__dx_require_lib override.sh
__dx_require_lib completion.sh
__dx_require_lib session-runtime.sh
__dx_require_lib session-catalog.sh
__dx_require_lib output.sh
__dx_require_lib host-budget.sh
__dx_require_lib worktree.sh
__dx_require_lib provider.sh
__dx_require_lib codex.sh
__dx_require_lib dexcode.sh
__dx_require_lib ui-capture.sh
__dx_require_lib rtk.sh
__dx_require_lib events.sh
__dx_require_lib review.sh
__dx_require_lib review-capacity.sh
__dx_require_lib review-policy.sh
__dx_require_lib review-controller.sh
__dx_require_lib review-acceptance.sh
__dx_require_lib review-diagnostics.sh
__dx_require_lib review-loop.sh
__dx_require_lib factory.sh
__dx_require_lib run-spec.sh
__dx_require_lib agent-tools.sh
__dx_require_lib maintenance.sh
__dx_require_lib reviewers.sh
__dx_require_lib project-state.sh
__dx_require_lib ticket.sh
__dx_require_lib lifecycle-control.sh
__dx_require_lib session-management.sh
__dx_require_lib attribution.sh
__dx_require_lib worker.sh
__dx_require_lib triage.sh
