# shellcheck shell=bash
# Dex helpers for conservative Claude/Codex tooling bootstrap.
#
# This module intentionally installs only Dex-owned links, official MCP
# servers, and a narrow allowlist of official Claude Code plugins. The MCP
# servers and plugins live under $DX_TOOL_DIR and reach the sessions Dex
# launches only: nothing is registered in the user's Claude or Codex config.

DX_CLAUDE_OFFICIAL_MARKETPLACE_NAME="claude-plugins-official"
DX_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE="anthropics/claude-plugins-official"
DX_OPENAI_CODEX_MARKETPLACE_NAME="openai-codex"
DX_OPENAI_CODEX_MARKETPLACE_SOURCE="openai/codex-plugin-cc"
# Where the marketplaces are cloned from, and the commit each is pinned to. A
# Dex release bumps a pin to take that marketplace's updates. The environment
# can point both at a local fixture (the tests do).
DX_CLAUDE_OFFICIAL_MARKETPLACE_URL="${DX_CLAUDE_OFFICIAL_MARKETPLACE_URL:-https://github.com/${DX_CLAUDE_OFFICIAL_MARKETPLACE_SOURCE}.git}"
DX_CLAUDE_OFFICIAL_MARKETPLACE_REF="${DX_CLAUDE_OFFICIAL_MARKETPLACE_REF:-3b600518a637492d37c9877aeb49c2a55d939c04}"
DX_OPENAI_CODEX_MARKETPLACE_URL="${DX_OPENAI_CODEX_MARKETPLACE_URL:-https://github.com/${DX_OPENAI_CODEX_MARKETPLACE_SOURCE}.git}"
DX_OPENAI_CODEX_MARKETPLACE_REF="${DX_OPENAI_CODEX_MARKETPLACE_REF:-db52e28f4d9ded852ab3942cea316258ae4ef346}"
DX_OPENAI_DOCS_MCP_NAME="openaiDeveloperDocs"
DX_OPENAI_DOCS_MCP_URL="https://developers.openai.com/mcp"

dx_claude_dir() {
  printf '%s\n' "$HOME/.claude"
}

# Per-skill link management is shared with the Codex path; the helpers live
# in lib/codex.sh.
dx_install_claude_skill_links() {
  __dx_install_skill_links "$1" "Claude Code"
}

dx_count_claude_dex_skill_links() {
  __dx_count_dex_skill_links "$1"
}

dx_install_claude_dex_link() {
  local kind="$1" target="$2"
  local claude_dir link current

  claude_dir=$(dx_claude_dir)
  link="$claude_dir/$kind"
  mkdir -p "$claude_dir"

  if [[ -L "$link" ]]; then
    current=$(readlink "$link")
    if [[ "$current" == "$target" ]]; then
      dx_ok "${HOME}/.claude/${kind} -> ${target}"
      return 0
    fi

    dx_warn "${HOME}/.claude/${kind} points to ${current}; leaving it unchanged"
    return 1
  fi

  if [[ -e "$link" ]]; then
    dx_warn "${HOME}/.claude/${kind} exists and is not a symlink; leaving it unchanged"
    return 1
  fi

  if ln -s "$target" "$link"; then
    dx_done "Symlinked ${HOME}/.claude/${kind} -> ${target}"
    return 0
  fi

  dx_warn "Failed to symlink ${HOME}/.claude/${kind}"
  return 1
}

dx_install_claude_dex_links() {
  local failed=0 claude_dir skills_link

  claude_dir=$(dx_claude_dir)
  skills_link="$claude_dir/skills"

  if [[ -d "$skills_link" && ! -L "$skills_link" ]]; then
    dx_install_claude_skill_links "$skills_link" || failed=1
  else
    dx_install_claude_dex_link "skills" "$DEX_DIR/skills" || failed=1
  fi

  return "$failed"
}

# Dex's skills reach Claude per launch, as the plugin `dex` that
# dx_provider_claude passes with --plugin-dir. Linking them into
# ~/.claude/skills as well, for sessions Dex did not launch, is opt-in
# (`dx install --global-skills`). A Dex session then lists each skill twice,
# bare and as dex:<name>, which is harmless.

# none, linked (the whole directory, or a link for every Dex skill name the
# user does not already use for a skill of their own) or partial (some
# names have nothing at all, which --global-skills would fill).
dx_claude_global_skills_state() {
  local link skill_dir
  link="$(dx_claude_dir)/skills"
  if [[ -L "$link" ]]; then
    if [[ "$(readlink "$link")" == "$DEX_DIR/skills" ]]; then
      printf 'linked\n'
    else
      printf 'none\n'
    fi
    return 0
  fi
  if [[ "$(dx_count_claude_dex_skill_links "$link")" -eq 0 ]]; then
    printf 'none\n'
    return 0
  fi
  for skill_dir in "$DEX_DIR"/skills/*/; do
    [[ -f "${skill_dir}SKILL.md" ]] || continue
    skill_dir="${skill_dir%/}"
    if [[ ! -e "$link/${skill_dir##*/}" && ! -L "$link/${skill_dir##*/}" ]]; then
      printf 'partial\n'
      return 0
    fi
  done
  printf 'linked\n'
}

dx_check_claude_dex_links() {
  case "$(dx_claude_global_skills_state)" in
    none) dx_ok "Claude skills load per launch (plugin dex)" ;;
    linked) dx_ok "Claude skills load per launch (plugin dex), plus global links in ~/.claude/skills ('dx install --no-global-skills' removes them)" ;;
    *)
      dx_warn "${HOME}/.claude/skills has a partial set of Dex skill links; run 'dx install --global-skills' or 'dx install --no-global-skills'"
      return 1
      ;;
  esac
}

# Remove the Dex links from ~/.claude/skills: the whole-directory link, or
# each per-skill link. Anything not pointing into Dex stays. Shared by
# `dx uninstall` and `dx install --no-global-skills`.
dx_remove_claude_skill_links() {
  local skills_dir target current removed=0 failed=0
  skills_dir="$(dx_claude_dir)/skills"
  if [[ -L "$skills_dir" ]]; then
    target=$(readlink "$skills_dir")
    if [[ "$target" == "$DEX_DIR/skills" ]]; then
      rm "$skills_dir"
      dx_done "Removed ~/.claude/skills symlink"
    else
      dx_skip "${HOME}/.claude/skills points to $target (not Dex)"
    fi
    return 0
  fi
  if [[ ! -d "$skills_dir" ]]; then
    dx_skip "No ${HOME}/.claude/skills; nothing to remove"
    return 0
  fi
  while IFS= read -r target; do
    [[ -L "$target" ]] || continue
    current=$(readlink "$target")
    case "$current" in
      "$DEX_DIR"/skills/*)
        if rm "$target"; then
          removed=$((removed + 1))
        else
          dx_warn "Could not remove ${target}"
          failed=$((failed + 1))
        fi
        ;;
    esac
  done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
  if [[ $failed -gt 0 ]]; then
    dx_warn "Removed ${removed} Claude skill link(s); failed ${failed}"
    return 1
  elif [[ $removed -gt 0 ]]; then
    dx_done "Removed ${removed} Claude skill link(s)"
  else
    dx_skip "No Dex Claude skill links found"
  fi
}

# Dex's hooks reach Claude through each launch's --settings file
# (dx_provider_claude), never through the user's own settings. Installing them
# there too, for sessions Dex did not launch, is opt-in: `dx install
# --global-hooks` writes commands gated on DEX_LAUNCHED, so a Dex launch does
# not run them twice.
dx_claude_settings_file() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
}

# The files a Dex install may have written hooks into: where Claude reads
# (CLAUDE_CONFIG_DIR), and ~/.claude/settings.json, where older Dex always
# wrote whatever CLAUDE_CONFIG_DIR said.
__dx_claude_hook_settings_files() {
  local current
  current=$(dx_claude_settings_file)
  printf '%s\n' "$current"
  [[ "$current" == "$HOME/.claude/settings.json" ]] || printf '%s\n' "$HOME/.claude/settings.json"
}

DX_LEGACY_GLOBAL_HOOKS_WARNING="Dex hooks in your Claude settings predate launch-scoped hooks, so they run in every Claude session, including ones Dex did not launch, and run twice in Dex sessions if they point at another Dex checkout. Run 'dx install --global-hooks' to keep them for other sessions, or 'dx install --no-global-hooks' to remove them."

DX_STALE_GLOBAL_HOOKS_WARNING="Old Dex hooks in ~/.claude/settings.json are leftovers Claude does not read while CLAUDE_CONFIG_DIR is set. Run 'dx install --no-global-hooks' to remove them."

# none, global (the opt-in, gated install), legacy (ungated hooks from an
# install that predates launch-scoped hooks, in the file Claude reads) or
# stale (such hooks only in ~/.claude/settings.json while CLAUDE_CONFIG_DIR
# points Claude elsewhere).
dx_claude_global_hooks_state() {
  local settings_file current helper="$DEX_DIR/scripts/settings-json.py" state=none
  current=$(dx_claude_settings_file)
  while IFS= read -r settings_file; do
    [[ -f "$settings_file" ]] || continue
    python3 "$helper" has-dex-hooks "$settings_file" "$DEX_DIR" "$HOME" >/dev/null 2>&1 || continue
    if python3 "$helper" legacy-dex-hooks "$settings_file" "$DEX_DIR" "$HOME" >/dev/null 2>&1; then
      if [[ "$settings_file" == "$current" ]]; then
        printf 'legacy\n'
        return 0
      fi
      state=stale
    elif [[ "$state" == none ]]; then
      state=global
    fi
  done < <(__dx_claude_hook_settings_files)
  printf '%s\n' "$state"
}

# Install or refresh the gated global hooks.
dx_refresh_claude_settings() {
  local quiet="${1:-1}"

  if [[ "$quiet" -eq 1 ]]; then
    bash "$DEX_DIR/bin/install-settings.sh" --quiet
  else
    bash "$DEX_DIR/bin/install-settings.sh"
  fi
}

dx_claude_settings_complete() {
  local settings_file template_file="$DEX_DIR/settings.json"
  local helper="$DEX_DIR/scripts/settings-json.py"
  settings_file=$(dx_claude_settings_file)

  command -v python3 >/dev/null 2>&1 || return 1
  [[ -f "$settings_file" && -f "$template_file" && -f "$helper" ]] || return 1

  python3 "$helper" settings-complete \
    "$settings_file" "$template_file" "$DEX_DIR" "$HOME" --gated >/dev/null 2>&1
}

dx_check_claude_settings() {
  case "$(dx_claude_global_hooks_state)" in
    none)
      dx_ok "Claude hooks are launch-scoped (no global install)"
      return 0
      ;;
    legacy)
      dx_warn "$DX_LEGACY_GLOBAL_HOOKS_WARNING"
      return 1
      ;;
    stale)
      dx_warn "$DX_STALE_GLOBAL_HOOKS_WARNING"
      return 1
      ;;
  esac
  if dx_claude_settings_complete; then
    dx_ok "Global Claude hooks and worktree settings are complete"
    return 0
  fi
  dx_warn "Global Claude hooks are incomplete; run 'dx install --global-hooks' to repair them"
  return 1
}

# Keep an opted-in global install current; warn about a legacy one.
dx_refresh_global_claude_hooks() {
  case "$(dx_claude_global_hooks_state)" in
    none) return 0 ;;
    legacy)
      dx_warn "$DX_LEGACY_GLOBAL_HOOKS_WARNING"
      return 0
      ;;
    stale)
      dx_warn "$DX_STALE_GLOBAL_HOOKS_WARNING"
      return 0
      ;;
  esac
  if dx_refresh_claude_settings 1 && dx_claude_settings_complete; then
    return 0
  fi
  dx_warn "Global Claude hooks remain incomplete after repair"
  return 1
}

# Take back what a global install added to the user's Claude settings: Dex's
# hook commands, and the worktree directories the install state says Dex
# added. The user's own hooks and directories stay. Shared by `dx uninstall`
# and `dx install --no-global-hooks`. Covers both files an install may have
# written (__dx_claude_hook_settings_files).
dx_remove_claude_global_hooks() {
  local settings_file state_file="$DX_INSTALL_STATE_FILE"
  local helper="$DEX_DIR/scripts/settings-json.py" tmp dirs="[]" failed=0 hook_status
  local files=()
  while IFS= read -r settings_file; do
    files+=("$settings_file")
  done < <(__dx_claude_hook_settings_files)

  for settings_file in "${files[@]}"; do
    [[ -f "$settings_file" ]] || continue
    tmp="${settings_file}.tmp.$$"
    hook_status=0
    python3 "$helper" has-dex-hooks "$settings_file" "$DEX_DIR" "$HOME" || hook_status=$?
    case "$hook_status" in
      0)
        if python3 "$helper" remove-dex-hooks "$settings_file" "$DEX_DIR" "$HOME" > "$tmp" \
          && [[ -s "$tmp" ]] && mv "$tmp" "$settings_file"; then
          dx_done "Removed Dex hooks from ${settings_file}"
        else
          rm -f "$tmp"
          dx_error "Failed to remove Dex hooks from ${settings_file}. Install Python 3, then try again."
          failed=1
        fi
        ;;
      1) dx_skip "No Dex hooks in ${settings_file}" ;;
      *)
        dx_error "Failed to inspect ${settings_file}. Install Python 3, then try again."
        failed=1
        ;;
    esac
  done

  if [[ -f "$state_file" ]] && ! dirs=$(python3 "$helper" state-dirs "$state_file"); then
    dx_error "Failed to read Dex install state; keeping $state_file for a later uninstall attempt"
    return 1
  fi
  if [[ "$dirs" == "[]" ]]; then
    dx_skip "No Dex-managed worktree settings in settings"
    return "$failed"
  fi
  for settings_file in "${files[@]}"; do
    [[ -f "$settings_file" ]] || continue
    tmp="${settings_file}.tmp.$$"
    if python3 "$helper" remove-worktree-dirs "$settings_file" "$dirs" > "$tmp" \
      && [[ -s "$tmp" ]] && mv "$tmp" "$settings_file"; then
      dx_done "Removed Dex worktree settings from ${settings_file}"
    else
      rm -f "$tmp"
      dx_error "Failed to remove Dex worktree settings from ${settings_file}"
      return 1
    fi
  done
  tmp="${state_file}.tmp.$$"
  if ! { python3 "$helper" clear-install-worktree "$state_file" > "$tmp" \
    && [[ -s "$tmp" ]] && mv "$tmp" "$state_file"; }; then
    rm -f "$tmp"
    dx_error "Failed to update $state_file"
    return 1
  fi
  return "$failed"
}

# Cross-session messaging. Claude Code holds a message for approval when it
# reaches a session that bypasses permission prompts, which every Dex launch
# does, and drops it after five minutes when nobody answers. Dex records the
# user's answer in its own install state and passes crossSessionInbound=accept
# to the sessions it launches. It never edits the user's Claude settings for
# this, so a hold or refuse the user set there stays theirs and wins.

# The value Claude Code reads from the user's own settings file, or nothing.
dx_claude_inbound_setting() {
  python3 "$DEX_DIR/scripts/settings-json.py" inbound-value \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
}

# on, off, or unset.
dx_session_messaging_preference() {
  python3 "$DEX_DIR/scripts/settings-json.py" session-messaging \
    "$DX_INSTALL_STATE_FILE"
}

dx_set_session_messaging_preference() {
  local state="$1" file="$DX_INSTALL_STATE_FILE" tmp
  tmp="${file}.tmp.$$"
  mkdir -p "$(dirname "$file")"
  if python3 "$DEX_DIR/scripts/settings-json.py" \
       set-session-messaging "$file" "$state" > "$tmp" \
     && [[ -s "$tmp" ]] && mv "$tmp" "$file"; then
    return 0
  fi
  rm -f "$tmp"
  dx_warn "Could not update $file"
  return 1
}

# Prints "accept" when a Dex launch should deliver peer messages unattended.
# Delivery is on unless the user answered off: Dex sessions coordinate
# through these messages, and a held message is lost when nobody is watching.
# An unreadable preference passes nothing rather than guessing. Managed
# settings and stricter project files apply on their own under Claude's
# precedence rules; only the user-scope value needs checking here.
dx_session_messaging_launch_value() {
  command -v python3 >/dev/null 2>&1 || return 0
  case "$(dx_session_messaging_preference 2>/dev/null)" in
    on|unset) ;;
    *) return 0 ;;
  esac
  case "$(dx_claude_inbound_setting 2>/dev/null)" in
    hold|refuse) return 0 ;;
  esac
  printf 'accept\n'
}

# ── Dex's MCP registry ──────────────────────────────────────────────────────
# The MCP servers Dex adds to the sessions it launches, in Claude's
# --mcp-config shape. dx_provider_claude passes it per launch (without
# --strict-mcp-config, so the user's own servers still load) and bin/dxcodex.sh
# turns it into `-c mcp_servers…` overrides. A name the user configured
# themselves is left out of the launch, so theirs wins.

dx_dex_mcp_registry() {
  printf '%s/mcp-registry.json\n' "$DX_TOOL_DIR"
}

dx_dex_plugins_dir() {
  printf '%s/plugins\n' "$DX_TOOL_DIR"
}

# dx_mcp_registry_set [--env NAME=VALUE]... <name> <url | command [args...]>
dx_mcp_registry_set() {
  local name result
  name="$1"
  [[ "$name" != --env ]] || name="$3"
  [[ "$name" != --env ]] || name="$5"
  if ! result=$(python3 "$DEX_DIR/scripts/settings-json.py" registry-set "$(dx_dex_mcp_registry)" "$@"); then
    dx_warn "Could not add MCP server '${name}' to Dex's registry"
    return 1
  fi
  if [[ "$result" == unchanged ]]; then
    dx_ok "MCP server '${name}' is in Dex's registry"
  else
    dx_done "Added MCP server '${name}' to Dex's registry (loads in Dex launches)"
  fi
}

dx_mcp_registry_has() {
  [[ -f "$(dx_dex_mcp_registry)" ]] || return 1
  python3 "$DEX_DIR/scripts/settings-json.py" registry-names "$(dx_dex_mcp_registry)" 2>/dev/null \
    | grep -Fxq -- "$1"
}

# __dx_check_mcp_server <name> — the registry, or else the user's own
# registration with each agent CLI installed here.
__dx_check_mcp_server() {
  local name="$1" cli label failed=0
  if dx_mcp_registry_has "$name"; then
    dx_ok "MCP server '${name}' loads in Dex launches (Dex registry)"
    return 0
  fi
  for cli in claude codex; do
    command -v "$cli" >/dev/null 2>&1 || continue
    label=Claude
    [[ "$cli" == codex ]] && label=Codex
    if __dx_mcp_server_exists "$cli" "$name"; then
      dx_ok "${label} MCP server '${name}' configured in your own settings"
    else
      dx_warn "${label} MCP server '${name}' is not configured; run 'dx tools bootstrap'"
      failed=1
    fi
  done
  return "$failed"
}

# The per-launch --mcp-config document for the current repository, or nothing.
dx_dex_launch_mcp_config() {
  local registry root
  registry=$(dx_dex_mcp_registry)
  [[ -f "$registry" ]] || return 0
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  python3 "$DEX_DIR/scripts/settings-json.py" launch-mcp "$registry" "$root"
}

# ── Per-phase MCP servers ────────────────────────────────────────────────────
# A project names the MCP servers each lifecycle phase loads in the `## MCP`
# section of its .dex/dex.md; scripts/mcp-scope.py resolves it against Dex's
# registry and the user's own Claude configuration (see docs/mcp-phases.md).

# dx_mcp_declared <repo> — does the project's .dex/dex.md have a `## MCP`
# section? A cheap check, so launches in a repository without one start no
# python3; the resolver decides what the section says.
dx_mcp_declared() {
  [[ -f "$1/.dex/dex.md" ]] || return 1
  grep -Eiq '^##[[:space:]]+MCP[[:space:]]*$' "$1/.dex/dex.md"
}

# __dx_mcp_report_warn <context> <repo> — one warning per resolver report
# line on stdin, so a server a phase asked for is never dropped silently.
__dx_mcp_report_warn() {
  local mcp_context="$1" mcp_repo="$2" mcp_kind mcp_value
  while IFS=$'\t' read -r mcp_kind mcp_value; do
    case "$mcp_kind" in
      missing)
        dx_warn "MCP (${mcp_context}): '${mcp_value}' is not defined in any Claude MCP configuration or Dex's registry; launching without it."
        ;;
      disabled)
        dx_warn "MCP (${mcp_context}): '${mcp_value}' is disabled in your Claude settings; launching without it."
        ;;
      unset-env)
        dx_warn "MCP (${mcp_context}): a selected server reads \${${mcp_value}}, which is unset; check its authentication before relying on it."
        ;;
      invalid)
        dx_warn "Ignoring part of '## MCP' in ${mcp_repo}/.dex/dex.md: ${mcp_value}."
        ;;
    esac
  done
}

# __dx_mcp_resolve <context> <repo> <mcp-scope.py arguments…> — print the
# resolved mode (inherit, none, scoped, or unset for undeclared review waves)
# and warn for each problem the resolver reported. Returns 1 when it failed.
__dx_mcp_resolve() {
  local mcp_context="$1" mcp_repo="$2" mcp_output mcp_mode
  shift 2
  mcp_output=$(python3 "$DEX_DIR/scripts/mcp-scope.py" "$@") || return 1
  mcp_mode="${mcp_output%%$'\n'*}"
  case "$mcp_mode" in
    inherit|none|scoped|unset) ;;
    *) return 1 ;;
  esac
  if [[ "$mcp_output" == *$'\n'* ]]; then
    __dx_mcp_report_warn "$mcp_context" "$mcp_repo" <<< "${mcp_output#*$'\n'}"
  fi
  printf '%s\n' "$mcp_mode"
}

# dx_mcp_launch_config <repo> <phase 0-6> <inline 0|1> <out-file> — the MCP
# mode for a lifecycle launch; a scoped result is written to <out-file>.
dx_mcp_launch_config() {
  local mcp_label
  mcp_label=$(dx_lifecycle_phase_label "$2" 2>/dev/null) || mcp_label="Phase $2"
  __dx_mcp_resolve "$mcp_label" "$1" launch "$1" "$2" "$3" "$(dx_dex_mcp_registry)" "$4"
}

# dx_mcp_review_wave_config <repo> <out-file> — the same for review waves.
dx_mcp_review_wave_config() {
  __dx_mcp_resolve "review waves" "$1" review-waves "$1" "$(dx_dex_mcp_registry)" "$2"
}

# dx_mcp_phase_report <repo> — the resolver's per-phase rows for dx status
# and dx doctor (see scripts/mcp-scope.py report).
dx_mcp_phase_report() {
  python3 "$DEX_DIR/scripts/mcp-scope.py" report "$1" "$(dx_dex_mcp_registry)"
}

# The registry as Codex `-c` values, one per line.
dx_dex_codex_mcp_overrides() {
  local registry
  registry=$(dx_dex_mcp_registry)
  [[ -f "$registry" ]] || return 0
  python3 "$DEX_DIR/scripts/settings-json.py" codex-mcp-overrides "$registry" \
    "${CODEX_HOME:-$HOME/.codex}/config.toml"
}

# ── Per-launch plugins ──────────────────────────────────────────────────────
# The allowlisted marketplaces are cloned under $DX_TOOL_DIR/plugins at a
# pinned commit, every allowlisted plugin is resolved into plugins/resolved,
# and each launch passes one --plugin-dir per plugin the repository selects.
# No `claude plugin marketplace add`, `install` or `enable`.

DX_DEX_PLUGIN_REFS=(
  codex@openai-codex
  frontend-design@claude-plugins-official
  typescript-lsp@claude-plugins-official
  pyright-lsp@claude-plugins-official
  rust-analyzer-lsp@claude-plugins-official
  gopls-lsp@claude-plugins-official
)

# dx_install_dex_marketplace <name> <url> <ref> — clone the marketplace, or
# bring an existing clone back to its pinned commit: the origin URL reset,
# local edits and untracked files discarded. A directory that is not a git
# clone is replaced. Git is always told the clone's own .git, so nothing
# planted in the directory can point it at another repository.
dx_install_dex_marketplace() {
  local name="$1" url="$2" ref="$3" dir tmp old git_dir=() cloned=0
  dir="$(dx_dex_plugins_dir)/marketplaces/$name"
  git_dir=(git -C "$dir" --git-dir="$dir/.git" --work-tree="$dir")
  # An empty or broken .git counts as no clone at all: re-cloned and swapped.
  if [[ -d "$dir/.git" ]] && git --git-dir="$dir/.git" rev-parse --git-dir >/dev/null 2>&1; then
    cloned=1
  fi
  if [[ "$cloned" == 1 && "$("${git_dir[@]}" rev-parse HEAD 2>/dev/null)" == "$ref" \
    && -z "$("${git_dir[@]}" status --porcelain --ignored 2>/dev/null)" ]] \
    && [[ "$("${git_dir[@]}" remote get-url origin 2>/dev/null)" == "$url" ]]; then
    dx_ok "Claude plugin marketplace '${name}' is at its pinned commit"
    return 0
  fi
  if dx_offline; then
    dx_skip "Claude plugin marketplace '${name}' not fetched (DEX_OFFLINE=1)"
    return 0
  fi
  dx_info "Fetching Claude plugin marketplace '${name}' at ${ref}"
  if [[ "$cloned" != 1 ]]; then
    tmp="${dir}.tmp.$$" old="${dir}.old.$$"
    mkdir -p "${dir%/*}"
    rm -rf "${tmp:?}"
    if ! dx_run_with_timeout 300 git clone --quiet --no-checkout "$url" "$tmp" >/dev/null 2>&1; then
      rm -rf "${tmp:?}"
      dx_warn "Could not clone Claude plugin marketplace '${name}' from ${url}"
      return 1
    fi
    if [[ -e "$dir" || -L "$dir" ]] && ! mv "$dir" "$old"; then
      rm -rf "${tmp:?}"
      dx_warn "Could not replace ${dir}, which is not a git clone"
      return 1
    fi
    mv "$tmp" "$dir" || { dx_warn "Could not move the new clone into ${dir}"; return 1; }
    rm -rf "${old:?}"
  fi
  "${git_dir[@]}" remote set-url origin "$url" >/dev/null 2>&1 || true
  if ! "${git_dir[@]}" cat-file -e "${ref}^{commit}" 2>/dev/null; then
    dx_run_with_timeout 300 "${git_dir[@]}" fetch --quiet origin >/dev/null 2>&1 \
      || dx_run_with_timeout 300 "${git_dir[@]}" fetch --quiet origin "$ref" >/dev/null 2>&1 || true
  fi
  if ! "${git_dir[@]}" -c advice.detachedHead=false checkout --quiet -f --detach "$ref" >/dev/null 2>&1 \
    || ! "${git_dir[@]}" clean -fdxq >/dev/null 2>&1; then
    dx_warn "Could not check out Claude plugin marketplace '${name}' at pinned commit ${ref}"
    return 1
  fi
  dx_done "Claude plugin marketplace '${name}' at ${ref}"
}

dx_install_safe_official_claude_plugins() {
  local failed=0 plugins line ready=""
  if ! command -v claude >/dev/null 2>&1; then
    dx_skip "Claude Code CLI not found; skipping Claude plugins"
    return 0
  fi
  dx_install_dex_marketplace "$DX_CLAUDE_OFFICIAL_MARKETPLACE_NAME" \
    "$DX_CLAUDE_OFFICIAL_MARKETPLACE_URL" "$DX_CLAUDE_OFFICIAL_MARKETPLACE_REF" || failed=1
  if command -v codex >/dev/null 2>&1; then
    dx_install_dex_marketplace "$DX_OPENAI_CODEX_MARKETPLACE_NAME" \
      "$DX_OPENAI_CODEX_MARKETPLACE_URL" "$DX_OPENAI_CODEX_MARKETPLACE_REF" || failed=1
  fi
  plugins=$(dx_dex_plugins_dir)
  if dx_offline && [[ ! -d "$plugins/marketplaces" ]]; then
    dx_skip "Claude plugins not prepared: no marketplace clone yet (DEX_OFFLINE=1)"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in
      "ok "*) ready="${ready:+$ready, }${line#ok }" ;;
      "refused "*)
        line="${line#refused }"
        dx_warn "Refusing Claude plugin ${line%% *}: ${line#* }"
        failed=1
        ;;
      "missing "*) dx_warn "Claude plugin ${line#missing } is not in its marketplace"; failed=1 ;;
    esac
  done < <(python3 "$DEX_DIR/scripts/settings-json.py" resolve-plugins \
    "$plugins/marketplaces" "$plugins/resolved" "${DX_DEX_PLUGIN_REFS[@]}" || printf 'error\n')
  if [[ -n "$ready" ]]; then
    dx_done "Claude plugins ready to load in Dex launches: ${ready}"
  else
    dx_warn "No Claude plugin could be prepared under ${plugins}"
    failed=1
  fi
  return "$failed"
}

# dx_claude_plugin_available <ref> — resolved for Dex launches, or enabled in
# the user's own Claude settings.
dx_claude_plugin_available() {
  [[ -d "$(dx_dex_plugins_dir)/resolved/${1%@*}" ]] && return 0
  [[ "$(dx_claude_plugin_status "$1")" == enabled ]]
}

# The --plugin-dir values for the current repository, one per line: the
# plugins it selects that are resolved, minus any the user enabled or disabled
# themselves.
dx_dex_launch_plugin_dirs() {
  local resolved root ref reason refs=()
  resolved="$(dx_dex_plugins_dir)/resolved"
  [[ -d "$resolved" ]] || return 0
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  while IFS=$'\t' read -r ref reason; do
    [[ -n "$ref" ]] && refs+=("$ref")
  done < <(dx_safe_official_claude_plugins_for_project "$root")
  [[ ${#refs[@]} -gt 0 ]] || return 0
  python3 "$DEX_DIR/scripts/settings-json.py" launch-plugin-dirs "$resolved" "${root:-$PWD}" "${refs[@]}"
}

dx_claude_plugin_status() {
  local plugin_ref="$1" plugin_json

  command -v claude >/dev/null 2>&1 || {
    printf '%s\n' "missing"
    return 0
  }

  if ! plugin_json=$(claude plugin list --json 2>/dev/null); then
    printf '%s\n' "unknown"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$plugin_json" | python3 -c '
import json
import sys

target = sys.argv[1]
try:
    plugins = json.load(sys.stdin)
except Exception:
    print("unknown")
    raise SystemExit(0)

for plugin in plugins:
    if plugin.get("id") == target:
        print("enabled" if plugin.get("enabled") else "disabled")
        raise SystemExit(0)

print("missing")
' "$plugin_ref"
    return 0
  fi

  if grep -F "\"id\": \"$plugin_ref\"" >/dev/null 2>&1 <<< "$plugin_json"; then
    printf '%s\n' "unknown"
  else
    printf '%s\n' "missing"
  fi
}

# `find -name` treats exact names and glob patterns identically, so one finder
# serves both spellings.
dx_find_project_file() {
  local root="$1" pattern="$2"
  [[ -n "$root" && -d "$root" ]] || return 1

  find "$root" -maxdepth 4 \
    \( -path "*/.git" -o -path "*/.dex/worktrees" -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
    -o -type f -name "$pattern" -print -quit 2>/dev/null
}

dx_project_has_file() {
  local root="$1" pattern
  shift

  for pattern in "$@"; do
    [[ -n "$(dx_find_project_file "$root" "$pattern")" ]] && return 0
  done
  return 1
}

dx_project_package_json_has_dependency() {
  local root="$1" dependency_regex="$2"
  local package_file

  [[ -n "$root" && -d "$root" ]] || return 1

  while IFS= read -r package_file; do
    if grep -Eiq "\"(${dependency_regex})\"[[:space:]]*:" "$package_file" 2>/dev/null; then
      return 0
    fi
  done < <(find "$root" -maxdepth 4 \
    \( -path "*/.git" -o -path "*/.dex/worktrees" -o -path "*/node_modules" -o -path "*/vendor" \) -prune \
    -o -type f -name "package.json" -print 2>/dev/null)

  return 1
}

dx_project_uses_javascript_or_typescript() {
  local root="$1"
  dx_project_has_file "$root" "package.json" "tsconfig.json" "jsconfig.json" && return 0
  dx_project_has_file "$root" "*.ts" "*.tsx" "*.js" "*.jsx" && return 0
  return 1
}

dx_project_uses_frontend() {
  local root="$1"

  dx_project_package_json_has_dependency "$root" 'react|react-dom|next|vue|@vue/[A-Za-z0-9._/-]+|svelte|@sveltejs/[A-Za-z0-9._/-]+|astro|nuxt|@angular/core|vite|preact|solid-js|@remix-run/[A-Za-z0-9._/-]+' && return 0
  dx_project_has_file "$root" "vite.config.ts" "vite.config.js" "next.config.js" "next.config.mjs" "next.config.ts" "svelte.config.js" "astro.config.mjs" "nuxt.config.ts" "tailwind.config.js" "tailwind.config.ts" && return 0
  dx_project_has_file "$root" "*.tsx" "*.jsx" "*.vue" "*.svelte" && return 0

  return 1
}

dx_project_uses_python() {
  local root="$1"
  dx_project_has_file "$root" "pyproject.toml" "setup.py" "requirements.txt" "Pipfile" && return 0
  dx_project_has_file "$root" "*.py" && return 0
  return 1
}

dx_project_uses_rust() {
  local root="$1"
  dx_project_has_file "$root" "Cargo.toml" && return 0
  return 1
}

dx_project_uses_go() {
  local root="$1"
  dx_project_has_file "$root" "go.mod" && return 0
  return 1
}

dx_safe_official_claude_plugins_for_project() {
  local root="${1:-}"

  if command -v codex >/dev/null 2>&1; then
    printf '%s\t%s\n' "codex@openai-codex" "OpenAI Codex slash commands inside Claude Code"
  fi

  [[ -n "$root" && -d "$root" ]] || return 0

  if dx_project_uses_frontend "$root"; then
    printf '%s\t%s\n' "frontend-design@claude-plugins-official" "frontend project design assistance"
  fi
  if dx_project_uses_javascript_or_typescript "$root"; then
    printf '%s\t%s\n' "typescript-lsp@claude-plugins-official" "TypeScript/JavaScript code intelligence"
  fi
  if dx_project_uses_python "$root"; then
    printf '%s\t%s\n' "pyright-lsp@claude-plugins-official" "Python code intelligence"
  fi
  if dx_project_uses_rust "$root"; then
    printf '%s\t%s\n' "rust-analyzer-lsp@claude-plugins-official" "Rust code intelligence"
  fi
  if dx_project_uses_go "$root"; then
    printf '%s\t%s\n' "gopls-lsp@claude-plugins-official" "Go code intelligence"
  fi
}

dx_check_safe_official_claude_plugins() {
  local root="${1:-}" failed=0 plugin_ref reason

  if ! command -v claude >/dev/null 2>&1; then
    dx_skip "Claude Code CLI not found; skipping Claude plugin check"
    return 0
  fi

  while IFS=$'\t' read -r plugin_ref reason; do
    [[ -n "$plugin_ref" ]] || continue
    if dx_claude_plugin_available "$plugin_ref"; then
      dx_ok "Claude plugin '${plugin_ref}' available"
    else
      dx_warn "Claude plugin '${plugin_ref}' is not prepared; needed for ${reason}. Run 'dx tools bootstrap'"
      failed=1
    fi
  done < <(dx_safe_official_claude_plugins_for_project "$root")

  return "$failed"
}

dx_install_openai_docs_mcp_servers() {
  if dx_offline; then
    dx_skip "OpenAI docs MCP (remote) not registered (DEX_OFFLINE=1)"
    return 0
  fi
  dx_mcp_registry_set "$DX_OPENAI_DOCS_MCP_NAME" "$DX_OPENAI_DOCS_MCP_URL"
}

dx_check_openai_docs_mcp_servers() {
  __dx_check_mcp_server "$DX_OPENAI_DOCS_MCP_NAME"
}

dx_check_ui_capture_tooling() {
  local failed=0

  if dx_ui_capture_tooling_ready; then
    dx_ok "UI capture browser, media, and local narration tooling installed"
  else
    dx_warn "UI capture browser, media, or local narration tooling is incomplete"
    failed=1
  fi
  __dx_check_mcp_server playwright || failed=1
  __dx_check_mcp_server chrome-devtools || failed=1

  return "$failed"
}

dx_check_codex_skill_links() {
  local expected installed

  if ! command -v codex >/dev/null 2>&1; then
    dx_skip "Codex CLI not found; skipping Codex skill check"
    return 0
  fi
  if ! dx_codex_home_writes_enabled; then
    dx_skip "Codex skill links are opt-in ('dx tools bootstrap --codex-home')"
    return 0
  fi

  expected=$(dx_count_dex_skills)
  installed=$(dx_count_codex_dex_skills)
  if [[ "$expected" -gt 0 && "$installed" -eq "$expected" ]]; then
    dx_ok "Dex Codex skills linked (${installed}/${expected})"
    return 0
  fi

  dx_warn "Dex Codex skills are not fully linked (${installed}/${expected})"
  return 1
}

# DEX_SKIP_TOOL_BOOTSTRAP=1 turns every install off, whoever calls; checks
# still run. Writes into $CODEX_HOME (skill links, RTK instructions) happen
# only with DEX_CODEX_HOME_WRITES=1 (`dx tools bootstrap --codex-home`).
dx_bootstrap_agent_tooling() {
  local root="${1:-}" mode="${2:-install}" failed=0

  if [[ "$mode" == "check" ]]; then
    dx_info "Checking Claude/Codex tooling bootstrap"
    dx_check_claude_dex_links || failed=1
    dx_check_claude_settings || failed=1
    dx_check_codex_skill_links || failed=1
    dx_check_ui_capture_tooling || failed=1
    dx_check_rtk_tooling || failed=1
    dx_check_openai_docs_mcp_servers || failed=1
    dx_check_safe_official_claude_plugins "$root" || failed=1
    return "$failed"
  fi

  if [[ "${DEX_SKIP_TOOL_BOOTSTRAP:-0}" == 1 ]]; then
    dx_skip "Skipping Claude/Codex tooling bootstrap (DEX_SKIP_TOOL_BOOTSTRAP=1)"
    return 0
  fi

  dx_info "Installing Claude/Codex tooling bootstrap"

  # Only an explicit opt-in is recorded; a marker alone never re-records itself.
  if [[ "${DEX_CODEX_HOME_WRITES:-}" == 1 ]] \
    && ! { mkdir -p "$(dirname "$(dx_codex_home_writes_marker)")" && : > "$(dx_codex_home_writes_marker)"; }; then
    dx_warn "Could not record the Codex home opt-in in $(dx_codex_home_writes_marker)"
  fi
  if ! command -v codex >/dev/null 2>&1; then
    dx_skip "Codex CLI not found; skipping Codex skills"
  elif dx_codex_home_writes_enabled; then
    dx_install_codex_skills || failed=1
  else
    dx_skip "Codex skill links and RTK instructions are opt-in ('dx tools bootstrap --codex-home')"
  fi

  dx_install_ui_capture_tooling || failed=1
  dx_install_rtk_tooling || failed=1
  dx_install_openai_docs_mcp_servers || failed=1
  dx_install_safe_official_claude_plugins || failed=1
  dx_refresh_global_claude_hooks || failed=1

  if [[ -f "$DEX_ROUTER_HOME/config.json" ]] && command -v node >/dev/null 2>&1; then
    local native_router_output
    if native_router_output=$(node "$DEX_DIR/scripts/ccr/native.cjs" sync 2>&1); then
      [[ -z "$native_router_output" ]] || dx_ok "$native_router_output"
    else
      dx_warn "$native_router_output"
      failed=1
    fi
  fi

  return "$failed"
}
