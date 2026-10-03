#!/usr/bin/env python3
"""Transform Claude settings, Dex install-state JSON, Dex's MCP registry and
its per-launch plugin directories."""

import copy
import json
import os
import re
import shlex
import shutil
import subprocess
import sys


DEFAULT_DEX_DIR = "$HOME/work/dex"
HOOK_NAMES = (
    "load-ticket-context.sh",
    "user-prompt-submit.sh",
    "guard-handler.py",
    "rtk-claude-hook.sh",
    "post-commit-guard.sh",
    "phase-loop.sh",
    "stop-sound.sh",
    "pre-compact.sh",
    "session-end.sh",
)
LEGACY_HOOK_PATTERN = re.compile(
    r'(^|[\s"])[^\s"]*/dex(?:-cli)?/hooks/(?:'
    + "|".join(re.escape(name) for name in HOOK_NAMES)
    + r')([\s"]|$)'
)


def load_object(path):
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def emit(value, compact=False):
    options = {"ensure_ascii": False}
    if compact:
        options["separators"] = (",", ":")
    else:
        options["indent"] = 2
    print(json.dumps(value, **options))


def replace_strings(value, old, new):
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_strings(item, old, new) for item in value]
    if isinstance(value, dict):
        return {key: replace_strings(item, old, new) for key, item in value.items()}
    return value


# A global install (`dx install --global-hooks`) prefixes every command with
# this gate, so a session Dex launched, which carries the same hooks in its
# launch settings, does not run them twice.
LAUNCH_GATE = '[ -z "${DEX_LAUNCHED:-}" ] || exit 0; '
GATED = False


def gate_commands(template):
    for groups in (template.get("hooks") or {}).values():
        for group in groups if isinstance(groups, list) else []:
            for hook in group.get("hooks") or [] if isinstance(group, dict) else []:
                command = hook.get("command") if isinstance(hook, dict) else None
                if isinstance(command, str) and not command.startswith(LAUNCH_GATE):
                    hook["command"] = LAUNCH_GATE + command
    return template


def customized_template(path, dex_dir):
    template = replace_strings(load_object(path), DEFAULT_DEX_DIR, dex_dir)
    return gate_commands(template) if GATED else template


def worktree_dirs(settings):
    worktree = settings.get("worktree")
    if not isinstance(worktree, dict):
        return []
    directories = worktree.get("symlinkDirectories", [])
    return directories if isinstance(directories, list) else []


def is_dex_command(command, dex_dir, home):
    if not isinstance(command, str):
        return False
    markers = (
        f"{dex_dir}/hooks/",
        f"{home}/work/dex/hooks/",
        "$HOME/work/dex/hooks/",
        "$DEX_DIR/hooks/",
    )
    return (
        any(marker in command for marker in markers)
        or ("export DEX_DIR=" in command and "/hooks/" in command)
        or bool(LEGACY_HOOK_PATTERN.search(command))
    )


def has_dex_hooks(settings, dex_dir, home):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return False
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            commands = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(commands, list):
                continue
            if any(
                isinstance(hook, dict) and is_dex_command(hook.get("command"), dex_dir, home)
                for hook in commands
            ):
                return True
    return False


def required_settings_complete(settings, template):
    hooks = settings.get("hooks")
    template_hooks = template.get("hooks")
    if not isinstance(hooks, dict) or not isinstance(template_hooks, dict):
        return False

    for event, required_groups in template_hooks.items():
        installed_groups = hooks.get(event)
        if not isinstance(required_groups, list) or not isinstance(installed_groups, list):
            return False

        unmatched = copy.deepcopy(installed_groups)
        for required_group in required_groups:
            try:
                unmatched.remove(required_group)
            except ValueError:
                return False

    installed_dirs = worktree_dirs(settings)
    return all(directory in installed_dirs for directory in worktree_dirs(template))


def filtered_groups(groups, dex_dir, home):
    retained = []
    for group in groups:
        commands = group.get("hooks") if isinstance(group, dict) else None
        if not isinstance(commands, list):
            retained.append(copy.deepcopy(group))
            continue
        filtered = [
            hook
            for hook in commands
            if not (
                isinstance(hook, dict)
                and is_dex_command(hook.get("command"), dex_dir, home)
            )
        ]
        if filtered:
            updated = copy.deepcopy(group)
            updated["hooks"] = filtered
            retained.append(updated)
    return retained


def deep_merge(left, right):
    merged = copy.deepcopy(left) if isinstance(left, dict) else {}
    for key, value in (right if isinstance(right, dict) else {}).items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def append_unique(base, additions):
    result = copy.deepcopy(base)
    for item in additions:
        if item not in result:
            result.append(copy.deepcopy(item))
    return result


def unordered_equal(left, right):
    if len(left) != len(right):
        return False
    unmatched = copy.deepcopy(right)
    for item in left:
        try:
            unmatched.remove(item)
        except ValueError:
            return False
    return not unmatched


def merge_settings(existing, template, dex_dir, home):
    # Only these two keys have merge rules. A third one added to the template
    # would otherwise install as a silent no-op, and the failure would surface
    # much later as a setting that simply never took effect.
    unhandled = sorted(set(template) - {"hooks", "worktree"})
    if unhandled:
        raise ValueError(
            "settings template has keys with no merge rule: " + ", ".join(unhandled)
        )

    result = copy.deepcopy(existing)
    existing_hooks = existing.get("hooks")
    merged_hooks = copy.deepcopy(existing_hooks) if isinstance(existing_hooks, dict) else {}
    template_hooks = template.get("hooks", {})
    if not isinstance(template_hooks, dict):
        raise ValueError("settings template hooks must be an object")
    for event, template_groups in template_hooks.items():
        if not isinstance(template_groups, list):
            raise ValueError(f"settings template hook event {event!r} must be an array")
        existing_groups = merged_hooks.get(event, [])
        retained = filtered_groups(existing_groups, dex_dir, home) if isinstance(existing_groups, list) else []
        if event == "PreToolUse":
            # Dex's guards must evaluate before any retained user hook: a user
            # hook that rewrites or approves the call must not run ahead of
            # the guard that would have flagged it. Other events keep user
            # hooks first.
            merged_hooks[event] = copy.deepcopy(template_groups) + retained
        else:
            merged_hooks[event] = retained + copy.deepcopy(template_groups)
    result["hooks"] = merged_hooks

    existing_worktree = existing.get("worktree")
    template_worktree = template.get("worktree")
    existing_worktree = existing_worktree if isinstance(existing_worktree, dict) else {}
    template_worktree = template_worktree if isinstance(template_worktree, dict) else {}
    merged_worktree = deep_merge(existing_worktree, template_worktree)
    if (
        existing_worktree.get("symlinkDirectories") is not None
        or template_worktree.get("symlinkDirectories") is not None
    ):
        merged_worktree["symlinkDirectories"] = append_unique(
            worktree_dirs(existing), worktree_dirs(template)
        )
    result["worktree"] = merged_worktree
    return result


def remove_dex_hooks(settings, dex_dir, home):
    result = copy.deepcopy(settings)
    hooks = result.get("hooks")
    if not isinstance(hooks, dict):
        return result
    retained_events = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            retained_events[event] = groups
            continue
        retained = filtered_groups(groups, dex_dir, home)
        if retained:
            retained_events[event] = retained
    if retained_events:
        result["hooks"] = retained_events
    else:
        result.pop("hooks", None)
    return result


def command_render_template(template_path, dex_dir):
    emit(customized_template(template_path, dex_dir))


def command_template_dirs(template_path):
    emit(worktree_dirs(load_object(template_path)), compact=True)


def command_managed_dirs(existing_path, template_path, dex_dir, home):
    existing = load_object(existing_path)
    template = customized_template(template_path, dex_dir)
    existing_dirs = worktree_dirs(existing)
    template_dirs = worktree_dirs(template)
    if has_dex_hooks(existing, dex_dir, home) and (
        unordered_equal(existing_dirs, template_dirs)
        or all(directory in existing_dirs for directory in template_dirs)
    ):
        managed = template_dirs
    else:
        managed = [directory for directory in template_dirs if directory not in existing_dirs]
    emit(managed, compact=True)


def command_merge_settings(existing_path, template_path, dex_dir, home):
    existing = load_object(existing_path)
    template = customized_template(template_path, dex_dir)
    emit(merge_settings(existing, template, dex_dir, home))


def command_merge_state(state_path, directories_json):
    directories = json.loads(directories_json)
    if not isinstance(directories, list):
        raise ValueError("managed worktree directories must be an array")
    state = load_object(state_path) if os.path.isfile(state_path) else {}
    worktree = state.get("worktree")
    if worktree is None:
        worktree = {}
        state["worktree"] = worktree
    if not isinstance(worktree, dict):
        raise ValueError("install-state worktree must be an object")
    managed = worktree.get("managedSymlinkDirectories", [])
    if not isinstance(managed, list):
        raise ValueError("managedSymlinkDirectories must be an array")
    worktree["managedSymlinkDirectories"] = append_unique(managed, directories)
    emit(state)


def command_has_hooks(settings_path, dex_dir, home):
    settings = load_object(settings_path)
    return 0 if has_dex_hooks(settings, dex_dir, home) else 1


def command_settings_complete(settings_path, template_path, dex_dir, home):
    settings = load_object(settings_path)
    template = customized_template(template_path, dex_dir)
    return 0 if required_settings_complete(settings, template) else 1


def command_remove_hooks(settings_path, dex_dir, home):
    emit(remove_dex_hooks(load_object(settings_path), dex_dir, home))


def command_state_dirs(state_path):
    state = load_object(state_path)
    worktree = state.get("worktree", {})
    if not isinstance(worktree, dict):
        raise ValueError("install-state worktree must be an object")
    directories = worktree.get("managedSymlinkDirectories", [])
    if not isinstance(directories, list):
        raise ValueError("managedSymlinkDirectories must be an array")
    emit(directories, compact=True)


def command_remove_dirs(settings_path, directories_json):
    settings = load_object(settings_path)
    managed = json.loads(directories_json)
    if not isinstance(managed, list):
        raise ValueError("managed worktree directories must be an array")
    worktree = settings.get("worktree")
    if isinstance(worktree, dict):
        directories = worktree.get("symlinkDirectories")
        if isinstance(directories, list):
            retained = [directory for directory in directories if directory not in managed]
            if retained:
                worktree["symlinkDirectories"] = retained
            else:
                worktree.pop("symlinkDirectories", None)
        if not worktree:
            settings.pop("worktree", None)
    emit(settings)


def command_legacy_hooks(settings_path, dex_dir, home):
    """0 when a Dex hook in these settings lacks the launch gate: an install
    from before hooks became launch-scoped, which runs twice in Dex launches."""
    settings = load_object(settings_path)
    for groups in (settings.get("hooks") or {}).values():
        for group in groups if isinstance(groups, list) else []:
            for hook in group.get("hooks") or [] if isinstance(group, dict) else []:
                command = hook.get("command") if isinstance(hook, dict) else None
                if (isinstance(command, str) and is_dex_command(command, dex_dir, home)
                        and not command.startswith(LAUNCH_GATE)):
                    return 0
    return 1


def command_clear_install_worktree(state_path):
    state = load_object(state_path) if os.path.isfile(state_path) else {}
    state.pop("worktree", None)
    emit(state)


def settings_layer(value, label):
    """A --settings value: inline JSON or a path, as Claude Code accepts it."""
    try:
        if value.strip().startswith("{"):
            layer = json.loads(value)
        else:
            with open(value, encoding="utf-8") as handle:
                layer = json.load(handle)
    except (OSError, ValueError) as error:
        raise ValueError(f"cannot read {label} {value}: {error}")
    if not isinstance(layer, dict):
        raise ValueError(f"{label} {value} must contain a JSON object")
    hooks = layer.get("hooks", {})
    shape_ok = isinstance(hooks, dict) and all(
        isinstance(groups, list) and all(
            isinstance(group, dict) and isinstance(group.get("hooks", []), list)
            and all(isinstance(hook, dict) for hook in group.get("hooks", []))
            for group in groups)
        for groups in hooks.values())
    if not shape_ok:
        raise ValueError(f"{label} {value}: hooks must map each event to a list of "
                         "groups, each with a list of hook objects")
    return layer


# Where Claude Code writes plan files in a Dex launch, relative to the launch
# directory. Claude Code resolves plansDirectory against its working directory
# and falls back to ~/.claude/plans for a value outside it, so it cannot point
# at DEX_HOME. lib/events.sh DX_CLAUDE_PLANS_SUBDIR names the same path.
PLANS_DIRECTORY = ".dex/plans"


def launch_settings(template, statusline, inbound, rtk, layers, dex_dir, home):
    """One settings document for a Dex launch. Lowest to highest: Dex's
    defaults, each caller layer in order, then DEX_EXTRA_SETTINGS. Hook
    arrays add up, symlinkDirectories is a union, and Dex's own hook groups
    are always present because disableAllHooks is Dex's to decide, as is
    plansDirectory, which the run's plan copy depends on."""
    if not rtk:
        for groups in template.get("hooks", {}).values():
            for group in groups:
                group["hooks"] = [hook for hook in group.get("hooks", [])
                                  if "rtk-claude-hook.sh" not in hook.get("command", "")]
            groups[:] = [group for group in groups if group["hooks"]]
    # No dimmed next-prompt guess in a Dex session: one Enter or Tab would
    # send it, and in a driven terminal that can be a merge or a new lifecycle.
    # No auto-memory either: it lives in ~/.claude/projects/<repo>/memory,
    # shared by every session in the repository, outside DEX_HOME and the
    # repo. Dex's durable notes go in .dex/memory/. The setting, not
    # CLAUDE_CODE_DISABLE_AUTO_MEMORY: it reaches only this launch, a nested
    # claude does not inherit it, and DEX_EXTRA_SETTINGS can still opt back in.
    result: dict = {"promptSuggestionEnabled": False, "autoMemoryEnabled": False}
    if statusline:
        result["statusLine"] = {"type": "command", "command": "bash " + shlex.quote(statusline)}
    if inbound:
        result["crossSessionInbound"] = inbound
    hooks, directories = {}, []
    for layer in layers:
        layer = copy.deepcopy(layer)
        layer.pop("disableAllHooks", None)
        for event, groups in (layer.pop("hooks", None) or {}).items():
            if isinstance(groups, list):
                hooks.setdefault(event, []).extend(groups)
        directories = append_unique(directories, worktree_dirs(layer))
        result = deep_merge(result, layer)
    if hooks:
        result["hooks"] = hooks
    if directories:
        result.setdefault("worktree", {})["symlinkDirectories"] = directories
    result = merge_settings(result, template, dex_dir, home)
    # --settings outranks user and project settings, so this also overrides a
    # disableAllHooks there that would otherwise silence Dex's hooks.
    result["disableAllHooks"] = False
    result["plansDirectory"] = PLANS_DIRECTORY
    return result


def command_launch_settings(*arguments):
    if len(arguments) < 5:
        raise ValueError("launch-settings expects <template> <dex-dir> <statusline> "
                         "<inbound> <rtk 0|1> [--settings value ...]")
    template_path, dex_dir, statusline, inbound, rtk = arguments[:5]
    caller = arguments[5:]
    layers =[settings_layer(value, "--settings") for value in caller]
    extra = os.environ.get("DEX_EXTRA_SETTINGS", "")
    if extra:
        if extra.strip().startswith("{") or not os.path.isfile(extra):
            raise ValueError(f"DEX_EXTRA_SETTINGS must name a settings file: {extra}")
        layers.append(settings_layer(extra, "DEX_EXTRA_SETTINGS"))
    template = customized_template(template_path, dex_dir)
    emit(launch_settings(template, statusline, inbound, rtk == "1", layers,
                         dex_dir, os.environ.get("HOME", "")))


def command_inbound_value(settings_path):
    """Print the user-scope crossSessionInbound value; nothing when unset."""
    settings = load_object(settings_path) if os.path.isfile(settings_path) else {}
    value = settings.get("crossSessionInbound")
    if isinstance(value, str) and value:
        print(value)


def command_session_messaging(state_path):
    """Print on, off, or unset for the session-messaging answer Dex recorded."""
    state = load_object(state_path) if os.path.isfile(state_path) else {}
    value = state.get("sessionMessaging")
    print("on" if value is True else "off" if value is False else "unset")


def command_set_session_messaging(state_path, state_value):
    if state_value not in ("on", "off"):
        raise ValueError(f"session messaging must be on or off; got {state_value!r}")
    state = load_object(state_path) if os.path.isfile(state_path) else {}
    state["sessionMessaging"] = state_value == "on"
    emit(state)


# ── Dex's MCP registry and per-launch plugins ─────────────────────────────
# The registry ($DX_TOOL_DIR/mcp-registry.json) holds the MCP servers Dex adds
# to the sessions it launches, in Claude's --mcp-config shape. Nothing here
# writes the user's own Claude or Codex configuration.

MCP_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,120}$")


def write_json_atomic(path, value):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.replace(tmp, path)


def registry_servers(path):
    if not os.path.isfile(path):
        return {}
    servers = load_object(path).get("mcpServers", {})
    if not isinstance(servers, dict):
        raise ValueError(f"{path}: mcpServers must be an object")
    return servers


def remote_server(entry):
    """A server reached over the network rather than started locally."""
    return isinstance(entry, dict) and (
        "url" in entry or entry.get("type") in ("http", "sse", "streamable-http"))


def launch_registry_servers(path):
    """The registry servers a launch may load. The shell sets DX_MCP_LOCAL_ONLY=1
    from dx_offline (lib/common.sh) to leave out the remote ones; it is
    internal to Dex, not a user setting."""
    servers = registry_servers(path)
    if os.environ.get("DX_MCP_LOCAL_ONLY") == "1":
        servers = {name: entry for name, entry in servers.items() if not remote_server(entry)}
    return servers


def quiet_load(path):
    """A user file Dex only reads: unreadable or invalid counts as empty."""
    try:
        return load_object(path)
    except (OSError, ValueError):
        return {}


def server_names(document, *keys):
    for key in keys:
        document = document.get(key) if isinstance(document, dict) else None
    return set(document) if isinstance(document, dict) else set()


def command_registry_set(path, name, target, *args):
    """Add or replace one entry: an HTTP server when the target is a URL and
    no arguments follow, otherwise a stdio command. `--env NAME=VALUE` pairs
    in front of the name add environment variables. Prints added, updated or
    unchanged."""
    env = {}
    while name == "--env":
        key, _, value = target.partition("=")
        env[key] = value
        name, target, args = args[0], args[1], args[2:]
    if not MCP_NAME.match(name):
        raise ValueError(f"invalid MCP server name: {name!r}")
    if re.match(r"https?://", target) and not args:
        entry = {"type": "http", "url": target}
    else:
        entry = {"command": target, "args": list(args)}
    if env:
        entry["env"] = env
    data = load_object(path) if os.path.isfile(path) else {}
    servers = data.setdefault("mcpServers", {})
    previous = servers.get(name)
    if previous == entry:
        print("unchanged")
        return
    servers[name] = entry
    write_json_atomic(path, data)
    print("added" if previous is None else "updated")


def command_registry_import(path, source, *flags):
    """Copy the servers in an .mcp.json-shaped file that the registry lacks,
    whole (type, headers and env included); print their names. --dry-run
    only prints them."""
    wanted = {name: entry for name, entry in
              (load_object(source).get("mcpServers") or {}).items()
              if MCP_NAME.match(name) and isinstance(entry, dict)}
    data = load_object(path) if os.path.isfile(path) else {}
    servers = data.setdefault("mcpServers", {})
    added = [name for name in wanted if name not in servers]
    for name in added:
        print(name)
    if added and "--dry-run" not in flags:
        servers.update((name, wanted[name]) for name in added)
        write_json_atomic(path, data)


def command_registry_names(path):
    for name in registry_servers(path):
        print(name)


def name_list(document, *keys):
    for key in keys:
        document = document.get(key) if isinstance(document, dict) else None
    return {item for item in document if isinstance(item, str)} if isinstance(document, list) else set()


def command_launch_mcp(registry, root):
    """The registry as one launch's --mcp-config, without the names the user
    already configured at user, local or project scope (so theirs wins) or
    disabled. Prints nothing when no server is left."""
    home = os.environ.get("HOME", "")
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    state = quiet_load(os.path.join(config_dir, ".claude.json") if os.environ.get("CLAUDE_CONFIG_DIR")
                       else os.path.join(home, ".claude.json"))
    # A linked worktree shares the disabled lists Claude keeps under the main
    # checkout's path.
    projects = [root]
    try:
        common = subprocess.run(["git", "-C", root, "rev-parse", "--git-common-dir"],
                                capture_output=True, text=True, timeout=3).stdout.strip()
        common = os.path.realpath(os.path.join(root, common)) if common else ""
        if os.path.basename(common) == ".git":
            projects.append(os.path.dirname(common))
    except (OSError, subprocess.SubprocessError):
        pass
    taken = (server_names(state, "mcpServers") | server_names(state, "projects", root, "mcpServers")
             | name_list(state, "disabledMcpServers")
             | server_names(quiet_load(os.path.join(root, ".mcp.json")), "mcpServers")
             | server_names(quiet_load(os.path.join(config_dir, "settings.json")), "mcpServers"))
    for project in projects:
        taken |= (name_list(state, "projects", project, "disabledMcpServers")
                  | name_list(state, "projects", project, "disabledMcpjsonServers"))
    for layer in ("settings.json", "settings.local.json"):
        taken |= name_list(quiet_load(os.path.join(root, ".claude", layer)), "disabledMcpjsonServers")
    servers = {name: entry for name, entry in launch_registry_servers(registry).items() if name not in taken}
    if servers:
        emit({"mcpServers": servers}, compact=True)


def toml_value(value):
    """A JSON string or string list as a TOML value. ensure_ascii=False keeps
    astral characters whole: JSON would escape them as surrogate pairs, which
    TOML rejects. TOML also forbids a raw DEL, so it is escaped, and a lone
    surrogate, which no TOML escape can carry, becomes U+FFFD."""
    def char(c):
        if c == "\x7f":
            return "\\u007f"
        if 0xD800 <= ord(c) <= 0xDFFF:
            return "\\ufffd"
        return c
    return "".join(char(c) for c in json.dumps(value, ensure_ascii=False))


def toml_table(mapping):
    return "{%s}" % ", ".join(f"{toml_value(key)} = {toml_value(value)}" for key, value in mapping.items())


def codex_server_names(text):
    """The MCP server names a config.toml defines, read with tomllib where
    there is one (Python 3.11+), else by the line scan below: [mcp_servers.<name>]
    tables, keys inside an [mcp_servers] table, and top-level dotted keys."""
    try:
        import tomllib
        servers = tomllib.loads(text).get("mcp_servers")
        return set(servers) if isinstance(servers, dict) else set()
    except ImportError:
        pass
    except ValueError:
        pass  # an invalid file still gets the line scan
    names, table = set(), ""
    key = r'("?)([^".\]=\s]+)\1'
    for line in text.splitlines():
        header = re.match(r"^\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?$", line)
        if header:
            table = header.group(1)
            nested = re.match(r"^mcp_servers\." + key, table)
            if nested:
                names.add(nested.group(2))
            continue
        if table == "mcp_servers":
            match = re.match(r"^\s*" + key + r"\s*[=.]", line)
        elif table == "":
            match = re.match(r"^\s*mcp_servers\s*\.\s*" + key + r"\s*[=.]", line)
        else:
            match = None
        if match:
            names.add(match.group(2))
    return names


def command_codex_mcp_overrides(registry, codex_config):
    """One `-c` value per line that adds a registry server to a Codex launch:
    mcp_servers.<name>.<field>=<TOML value>. Names already in the user's
    config.toml are skipped, so theirs wins. Every value, env included, ends
    up in the codex argv."""
    try:
        with open(codex_config, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        text = ""
    taken = codex_server_names(text)

    def strings(value):
        return isinstance(value, dict) and all(isinstance(item, str) for item in value.values())

    for name, entry in launch_registry_servers(registry).items():
        if name in taken or not re.match(r"^[A-Za-z0-9_-]+$", name) or not isinstance(entry, dict):
            continue
        if isinstance(entry.get("command"), str):
            fields = [("command", toml_value(entry["command"]))]
            args = entry.get("args") or []
            if isinstance(args, list) and all(isinstance(arg, str) for arg in args):
                fields.append(("args", toml_value(args)))
        elif isinstance(entry.get("url"), str):
            fields = [("url", toml_value(entry["url"]))]
            if entry.get("headers") and strings(entry["headers"]):
                fields.append(("http_headers", toml_table(entry["headers"])))
        else:
            continue
        if entry.get("env") and strings(entry["env"]):
            fields.append(("env", toml_table(entry["env"])))
        for field, value in fields:
            print(f"mcp_servers.{name}.{field}={value}")


# Marketplace entry keys that describe a plugin as a component path rather
# than inline, and keys a generated plugin.json leaves out.
PLUGIN_COMPONENT_KEYS = ("commands", "agents", "skills", "hooks", "mcpServers",
                         "lspServers", "outputStyles")
MARKETPLACE_ONLY_KEYS = ("source", "strict", "category", "tags")
# Files larger than this are not scanned for CLAUDE_PLUGIN_DATA.
PLUGIN_SCAN_LIMIT = 1024 * 1024


def names_a_path(document):
    """The first component key given as a path string (or a list of them)."""
    for key in PLUGIN_COMPONENT_KEYS:
        value = document.get(key)
        if isinstance(value, str) or (isinstance(value, list) and any(isinstance(item, str) for item in value)):
            return key
    return None


def inside(path, root):
    return path == root or path.startswith(root + os.sep)


def plugin_refusal(entry, marketplace_root):
    """Why Dex will not load this marketplace entry per launch, or None."""
    source = entry.get("source")
    if not isinstance(source, str) or not source.startswith("./"):
        return "its source is not a directory inside the marketplace"
    root = os.path.realpath(marketplace_root)
    path = os.path.realpath(os.path.join(root, source))
    if not inside(path, root) or not os.path.isdir(path):
        return "its source directory is missing or outside the marketplace"
    key = names_a_path(entry)
    if key:
        return f"its {key} names a path"
    manifest = os.path.join(path, ".claude-plugin", "plugin.json")
    if os.path.isfile(manifest):
        key = names_a_path(quiet_load(manifest))
        if key:
            return f"its plugin.json {key} names a path"
    if "CLAUDE_PLUGIN_DATA" in json.dumps(entry):
        return "it uses CLAUDE_PLUGIN_DATA, which writes under ~/.claude/plugins/data"
    for directory, dirs, files in os.walk(path, followlinks=False):
        dirs[:] = [name for name in dirs if name != ".git"]
        for name in dirs + files:
            full = os.path.join(directory, name)
            # A link may point inside the plugin, where its target is scanned
            # in its own right; anywhere else, shared files included, it is
            # content this plugin's checks would not see.
            if os.path.islink(full) and not inside(os.path.realpath(full), path):
                return f"{os.path.relpath(full, path)} links outside the plugin"
        for name in files:
            full = os.path.join(directory, name)
            if os.path.islink(full) or not os.path.isfile(full) or os.path.getsize(full) > PLUGIN_SCAN_LIMIT:
                continue
            try:
                with open(full, "rb") as handle:
                    if b"CLAUDE_PLUGIN_DATA" in handle.read():
                        return "it uses CLAUDE_PLUGIN_DATA, which writes under ~/.claude/plugins/data"
            except OSError:
                pass
    return None


def resolve_plugin(entry, root, target):
    """The refusal reason for one entry, or None once <target> is built."""
    reason = plugin_refusal(entry, root)
    if reason:
        return reason
    source = os.path.realpath(os.path.join(root, entry["source"]))
    if os.path.isfile(os.path.join(source, ".claude-plugin", "plugin.json")):
        os.symlink(source, target)
        return None
    if entry.get("strict") is not False:
        return "it has no plugin.json and is not a strict:false entry"
    os.makedirs(os.path.join(target, ".claude-plugin"))
    for name in os.listdir(source):
        os.symlink(os.path.join(source, name), os.path.join(target, name))
    write_json_atomic(os.path.join(target, ".claude-plugin", "plugin.json"),
                      {key: value for key, value in entry.items() if key not in MARKETPLACE_ONLY_KEYS})
    return None


def command_resolve_plugins(marketplaces, resolved, *refs):
    """Rebuild <resolved>/<plugin> for each <plugin>@<marketplace>: a link to
    a plugin that has its own manifest, or, for a `strict: false` entry, a
    directory with a plugin.json generated from the marketplace entry and
    links to the plugin's files. One line per ref: `ok`, `refused <reason>`,
    `missing` (not in a marketplace Dex has), or `absent` (marketplace not
    fetched). A bad entry is refused on its own; the rest still resolve."""
    staging = f"{resolved}.tmp.{os.getpid()}"
    previous = f"{resolved}.old.{os.getpid()}"
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)
    try:
        catalogs = {}
        for ref in refs:
            plugin, _, market = ref.partition("@")
            root = os.path.join(marketplaces, market)
            if market not in catalogs:
                catalogs[market] = quiet_load(os.path.join(root, ".claude-plugin", "marketplace.json")) \
                    if os.path.isdir(root) else None
            catalog = catalogs[market]
            if catalog is None:
                print(f"absent {ref}")
                continue
            entry = next((item for item in catalog.get("plugins") or []
                          if isinstance(item, dict) and item.get("name") == plugin), None)
            if entry is None:
                print(f"missing {ref}")
                continue
            target = os.path.join(staging, plugin)
            try:
                reason = resolve_plugin(entry, root, target)
            except (AttributeError, KeyError, OSError, TypeError, ValueError) as error:
                reason = f"it could not be prepared: {error}"
            if reason:
                if os.path.islink(target):
                    os.unlink(target)
                else:
                    shutil.rmtree(target, ignore_errors=True)
                print(f"refused {ref} {reason}")
            else:
                print(f"ok {ref}")
        if os.path.lexists(resolved):
            os.rename(resolved, previous)
        os.rename(staging, resolved)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        shutil.rmtree(previous, ignore_errors=True)


def command_launch_plugin_dirs(resolved, root, *refs):
    """The resolved plugin directories for these refs, one per line, without
    any the user decided on themselves: a ref present in enabledPlugins in
    their user, project or local settings, true or false."""
    home_dir = os.path.join(os.environ.get("HOME", ""), ".claude")
    layers = [os.path.join(home_dir, "settings.json"),
              os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or home_dir, "settings.json"),
              os.path.join(root, ".claude", "settings.json"),
              os.path.join(root, ".claude", "settings.local.json")]
    decided = set()
    for layer in layers:
        plugins = quiet_load(layer).get("enabledPlugins")
        decided |= set(plugins) if isinstance(plugins, dict) else set()
    for ref in refs:
        path = os.path.join(resolved, ref.partition("@")[0])
        if ref not in decided and os.path.isdir(path):
            print(path)


COMMANDS = {
    "render-template": (2, command_render_template),
    "template-dirs": (1, command_template_dirs),
    "managed-dirs-added": (4, command_managed_dirs),
    "merge-settings": (4, command_merge_settings),
    "merge-install-state": (2, command_merge_state),
    "has-dex-hooks": (3, command_has_hooks),
    "settings-complete": (4, command_settings_complete),
    "remove-dex-hooks": (3, command_remove_hooks),
    "state-dirs": (1, command_state_dirs),
    "remove-worktree-dirs": (2, command_remove_dirs),
    "inbound-value": (1, command_inbound_value),
    "session-messaging": (1, command_session_messaging),
    "set-session-messaging": (2, command_set_session_messaging),
    "legacy-dex-hooks": (3, command_legacy_hooks),
    "clear-install-worktree": (1, command_clear_install_worktree),
    "launch-settings": (None, command_launch_settings),
    "registry-set": (None, command_registry_set),
    "registry-import": (None, command_registry_import),
    "registry-names": (1, command_registry_names),
    "launch-mcp": (2, command_launch_mcp),
    "codex-mcp-overrides": (2, command_codex_mcp_overrides),
    "resolve-plugins": (None, command_resolve_plugins),
    "launch-plugin-dirs": (None, command_launch_plugin_dirs),
}
# The commands that render or check the global install, the only ones --gated
# applies to.
GATED_COMMANDS = ("render-template", "managed-dirs-added", "merge-settings", "settings-complete")


def main(arguments):
    global GATED
    # --gated: render the template the way a global install writes it.
    if arguments and arguments[-1] == "--gated":
        GATED, arguments = True, arguments[:-1]
    if not arguments or arguments[0] not in COMMANDS:
        print("usage: settings-json.py <command> [arguments ...] [--gated]", file=sys.stderr)
        print("commands: " + ", ".join(COMMANDS), file=sys.stderr)
        return 2
    command, command_arguments = arguments[0], arguments[1:]
    if GATED and command not in GATED_COMMANDS:
        print(f"settings-json: --gated applies only to {', '.join(GATED_COMMANDS)}", file=sys.stderr)
        return 2
    expected, handler = COMMANDS[command]
    # None: the handler checks its own arguments.
    if expected is not None and len(command_arguments) != expected:
        print(f"settings-json: {command} expects {expected} arguments", file=sys.stderr)
        return 2
    try:
        status = handler(*command_arguments)
        return status if status is not None else 0
    except (AttributeError, KeyError, OSError, TypeError, ValueError) as error:
        print(f"settings-json: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
