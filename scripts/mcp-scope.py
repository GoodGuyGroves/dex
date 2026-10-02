#!/usr/bin/env python3
"""Which MCP servers a Dex launch gets.

A project may declare, per lifecycle phase, the MCP servers a launch loads, in
a fenced block under `## MCP` in its `.dex/dex.md`:

    ## MCP

    ```yaml
    default: inherit          # inherit | none | [server, ...]
    plan: [linear, github]
    verify: none
    review_waves: none
    ```

`inherit` keeps whatever the user configured; `none` and a list launch with
`--strict-mcp-config`, so only the named servers load. A name is looked up in
Dex's MCP registry, the user's `.claude.json`, the project's `.mcp.json` and
the local (per-project) servers, in that order of precedence, lowest first. A
name nowhere to be found, or one the user disabled, is reported rather than
dropped without a word.

One Claude process runs from the phase it launched at to the end of the
lifecycle, and its MCP servers are fixed when it starts. So an inline launch
gets every server a later phase will need: the union of the values from its
phase onwards, and `inherit` if any of them inherits. With no `## MCP` section
the built-in table below gives exactly the phases Dex has always launched
without MCP servers.

This module is also the selection engine behind `scripts/ccr/mcp-scope.cjs`
(`dx context scope`), so both read the same layers and disabled lists.

    mcp-scope.py launch <repo> <phase 0-6> <inline 0|1> <registry> <out-file>
    mcp-scope.py review-waves <repo> <registry> <out-file>
    mcp-scope.py report <repo> <registry>
    mcp-scope.py scope-json < request.json

`launch` and `review-waves` print the mode (`inherit`, `none`, `scoped`, or
`unset` for review waves the project did not declare) on the first line and
then one tab-separated report line per problem: `missing`, `disabled`,
`unset-env` or `invalid`. A `scoped` result writes the strict configuration to
<out-file> with mode 0600. Output names servers and variables only, never a
URL, header or value. Exit 2 means a Claude configuration file could not be
read; the caller keeps its built-in behaviour.
"""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

PHASES = ("setup", "plan", "implement", "review", "verify", "pr", "complete")
# The phases a project may name. Setup and the review host session always
# inherit: they never ran without MCP servers.
CONFIGURABLE = ("plan", "implement", "verify", "pr", "complete")
KEYS = ("default",) + CONFIGURABLE + ("review_waves",)
BUILTIN = {
    "setup": "inherit",
    "plan": "none",
    "implement": "inherit",
    "review": "inherit",
    "verify": "none",
    "pr": "none",
    "complete": "none",
}
NAME = re.compile(r"^[A-Za-z0-9_.-]{1,120}$")
TOOL = re.compile(r"^[A-Za-z][A-Za-z0-9]{0,80}$")
ENV_REFERENCE = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
MAX_CONFIG_BYTES = 4 * 1024 * 1024


class ScopeError(Exception):
    """A request or configuration the scope cannot be built from."""


def _contract():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        "dex_project_contract", os.path.join(here, "project-contract.py"))
    if spec is None or spec.loader is None:
        raise ScopeError("scripts/project-contract.py is missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ── The project's declarations ──────────────────────────────────────────────

def _printable(text):
    """A project's own text, safe to print on a terminal line."""
    return re.sub(r"[\x00-\x1f\x7f]", "?", text)


def _value(key, raw, problems):
    """`inherit`, `none` or a list of names; None when the value is invalid."""
    if isinstance(raw, str):
        if raw in ("inherit", "none"):
            return raw
        raw = [raw]
    names = []
    for name in raw:
        if not NAME.match(name):
            problems.append(f"{key}: '{_printable(name)}' is not a valid MCP server name")
            return None
        if name not in names:
            names.append(name)
    return names or "none"


def read_policy(repo):
    """The project's `## MCP` values and any problems with them.

    Returns ({key: value}, [problem, ...]); an absent file, section or block
    is an empty policy. A key that is unknown or invalid is reported and left
    out, so its phase falls back as if it were not written.
    """
    path = os.path.join(repo, ".dex", "dex.md")
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return {}, []
    contract = _contract()
    lines = contract.section_lines(text, "MCP")
    body = contract.fenced_block(lines) if lines is not None else None
    if body is None:
        return {}, []
    mapping = contract.parse_mapping(body)
    if mapping is None:
        return {}, ["the block under '## MCP' is not a flat mapping of scalars and lists"]
    policy, problems = {}, []
    for key, raw in mapping.items():
        if key not in KEYS:
            hint = "; use flat phase keys (plan: [...])" if key == "phases" else ""
            problems.append(f"'{key}' is not a ## MCP key{hint}")
            continue
        value = _value(key, raw, problems)
        if value is not None:
            policy[key] = value
    return policy, problems


def declared(policy, phase):
    """A phase's own value and where it came from: project, default, builtin."""
    if phase in CONFIGURABLE:
        if phase in policy:
            return policy[phase], "project"
        if "default" in policy:
            return policy["default"], "default"
    return BUILTIN[phase], "builtin"


def combine(values):
    """One launch's value for several phases: inherit wins, then the union."""
    names = []
    for value in values:
        if value == "inherit":
            return "inherit"
        if value != "none":
            names.extend(name for name in value if name not in names)
    return names or "none"


def launch_value(policy, index, inline):
    phases = PHASES[index:] if inline else PHASES[index:index + 1]
    return combine(declared(policy, phase)[0] for phase in phases)


# ── The servers Claude would load ───────────────────────────────────────────

def _read(path):
    try:
        info = os.stat(path)
    except FileNotFoundError:
        return {}
    except OSError as error:
        raise ScopeError(_unreadable(path)) from error
    try:
        if not os.path.isfile(path) or info.st_size > MAX_CONFIG_BYTES:
            raise ValueError("invalid size")
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
        if not isinstance(document, dict):
            raise ValueError("invalid object")
        return document
    except (OSError, ValueError) as error:
        raise ScopeError(_unreadable(path)) from error


def _unreadable(path):
    return f"Cannot read MCP configuration at {path}. Correct it before launching a scoped session."


def _quiet(path):
    """A settings file Dex only reads for disabled lists: unreadable is empty."""
    try:
        return _read(path)
    except ScopeError:
        return {}


def _get(document, *keys):
    for key in keys:
        document = document.get(key) if isinstance(document, dict) else None
    return document


def _names(document, *keys):
    value = _get(document, *keys)
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def _servers(document, *keys):
    value = _get(document, *keys)
    return value if isinstance(value, dict) else {}


def _git(directory, *args):
    try:
        result = subprocess.run(["git", "-C", directory, *args], capture_output=True,
                                text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def _object(value):
    # A JSON object counts as present even when empty, as in the Node module.
    return value if isinstance(value, dict) else None


def layers(cwd, root=None, registry=None, home=None, config_dir=None):
    """Every MCP server Claude would load here, and the names it disabled."""
    if not root:
        root = _git(cwd, "rev-parse", "--show-toplevel") or cwd
    home = home if home is not None else os.path.expanduser("~")
    state_file = (os.path.join(config_dir, ".claude.json") if config_dir
                  else os.path.join(home, ".claude.json"))
    user = _read(state_file)
    project = _read(os.path.join(root, ".mcp.json"))
    common = _git(root, "rev-parse", "--git-common-dir")
    common = os.path.normpath(os.path.join(root, common)) if common else ""
    projects = _get(user, "projects")
    projects = projects if isinstance(projects, dict) else {}
    shared = {}
    if common and os.path.basename(common) == ".git":
        shared = _object(projects.get(os.path.dirname(common))) or {}
    here = _object(projects.get(cwd)) or _object(projects.get(root)) or {}
    available = {}
    for layer in (_servers(_read(registry), "mcpServers") if registry else {},
                  _servers(user, "mcpServers"), _servers(project, "mcpServers"),
                  _servers(here, "mcpServers")):
        available.update(layer)
    disabled = set(_names(user, "disabledMcpServers"))
    for document in (shared, here):
        disabled.update(_names(document, "disabledMcpServers"))
        disabled.update(_names(document, "disabledMcpjsonServers"))
    for layer in ("settings.json", "settings.local.json"):
        disabled.update(_names(_quiet(os.path.join(root, ".claude", layer)), "disabledMcpjsonServers"))
    return available, disabled


def _off(name, entry, disabled):
    return (name in disabled or (isinstance(entry, dict)
            and (entry.get("enabled") is False or entry.get("disabled") is True)))


def select(include, available, disabled, env_names):
    """The configuration for an include list, plus what could not be had."""
    wanted = list(dict.fromkeys(include))
    linear = available.get("linear")
    if "linear" in wanted and "linear" in available and not _off("linear", linear, disabled):
        # The hosted Linear server replaces the older linear-server entry.
        wanted = [name for name in wanted if name != "linear-server"]
    selected, omitted, missing_env = {}, [], []
    for name, entry in available.items():
        if name not in wanted or _off(name, entry, disabled):
            omitted.append(name)
            continue
        if not isinstance(entry, dict):
            raise ScopeError(f"Invalid configuration for MCP server {name}.")
        selected[name] = entry
        for variable in ENV_REFERENCE.findall(json.dumps(entry)):
            if variable not in env_names and variable not in missing_env:
                missing_env.append(variable)
    return {
        "config": {"mcpServers": selected},
        "selected": list(selected),
        "omitted": omitted,
        "missing": [name for name in wanted if name not in available],
        "disabled": [name for name in wanted
                     if name in available and _off(name, available[name], disabled)],
        "missing_env": missing_env,
    }


# ── Commands ────────────────────────────────────────────────────────────────

def _environment_names():
    return {name for name, value in os.environ.items() if value}


def _resolve(repo, value, registry):
    """Select the servers for a list value from where the launch runs."""
    available, disabled = layers(os.getcwd(), root=repo, registry=registry or None,
                                 config_dir=os.environ.get("CLAUDE_CONFIG_DIR") or None)
    return select(value, available, disabled, _environment_names())


def _write_private(path, document):
    directory = os.path.dirname(os.path.abspath(path))
    handle, temporary = tempfile.mkstemp(prefix=".mcp-scope.", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(document, stream, ensure_ascii=False)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _emit(value, repo, registry, out_file, problems):
    lines = [f"invalid\t{problem}" for problem in problems]
    if value in ("inherit", "none"):
        print(value)
    else:
        result = _resolve(repo, value, registry)
        _write_private(out_file, result["config"])
        print("scoped")
        lines += [f"missing\t{name}" for name in result["missing"]]
        lines += [f"disabled\t{name}" for name in result["disabled"]]
        lines += [f"unset-env\t{name}" for name in result["missing_env"]]
    for line in lines:
        print(line)
    return 0


def command_launch(repo, phase, inline, registry, out_file):
    if not re.fullmatch(r"[0-6]", phase) or inline not in ("0", "1"):
        raise ScopeError("launch expects a phase 0-6 and inline 0 or 1")
    policy, problems = read_policy(repo)
    return _emit(launch_value(policy, int(phase), inline == "1"), repo, registry, out_file, problems)


def command_review_waves(repo, registry, out_file):
    policy, problems = read_policy(repo)
    if "review_waves" not in policy:
        print("unset")
        for problem in problems:
            print(f"invalid\t{problem}")
        return 0
    return _emit(policy["review_waves"], repo, registry, out_file, problems)


def command_report(repo, registry):
    """What each configurable phase and review waves load, for `dx status` and
    `dx doctor`. One `phase<TAB>key<TAB>text` row each, where text is never
    empty, then `missing<TAB>key<TAB>name`, `disabled<TAB>key<TAB>name` and
    `invalid<TAB>message` lines for every problem."""
    policy, problems = read_policy(repo)
    rows = [(phase,) + declared(policy, phase) for phase in CONFIGURABLE]
    if "review_waves" in policy:
        rows.append(("review_waves", policy["review_waves"], "project"))
    else:
        rows.append(("review_waves", "none", "builtin"))
    issues = []
    for key, value, source in rows:
        if value == "inherit":
            text = "inherited"
        elif value == "none":
            text = "none"
        else:
            result = _resolve(repo, value, registry)
            text = ", ".join(result["selected"]) or "none resolved"
            notes = []
            if result["missing"]:
                notes.append("missing: " + ", ".join(result["missing"]))
            if result["disabled"]:
                notes.append("disabled: " + ", ".join(result["disabled"]))
            if notes:
                text += " (" + "; ".join(notes) + ")"
            issues += [f"missing\t{key}\t{name}" for name in result["missing"]]
            issues += [f"disabled\t{key}\t{name}" for name in result["disabled"]]
        if source != "project":
            text += " [" + ("default" if source == "default" else "built-in") + "]"
        print(f"phase\t{key}\t{text}")
    for line in issues:
        print(line)
    for problem in problems:
        print(f"invalid\t{problem}")
    return 0


def command_scope_json():
    """The `dx context scope` selection for scripts/ccr/mcp-scope.cjs.

    Reads {policy, home, cwd, root, registry, config_dir, env_names} and prints
    {config, summary, builtin_tools}, or {error} with the message to throw.
    """
    try:
        request = json.load(sys.stdin)
        policy = request.get("policy") or {}
        include = policy.get("include")
        if not isinstance(include, list):
            raise ScopeError("MCP scope requires an include array of server names.")
        if any(not isinstance(name, str) or not NAME.match(name) for name in include):
            raise ScopeError("Invalid MCP server name in scope.")
        tools = policy.get("builtin_tools")
        if tools is not None and (not isinstance(tools, list) or any(
                not isinstance(name, str) or not TOOL.match(name) for name in tools)):
            raise ScopeError("Invalid builtin_tools in MCP scope.")
        available, disabled = layers(request.get("cwd") or os.getcwd(), root=request.get("root"),
                                     registry=request.get("registry"), home=request.get("home"),
                                     config_dir=request.get("config_dir"))
        result = select(include, available, disabled, set(request.get("env_names") or []))
    except ScopeError as error:
        print(json.dumps({"error": str(error)}))
        return 0
    summary = {key: result[key] for key in ("selected", "omitted", "missing_env", "missing", "disabled")}
    print(json.dumps({"config": result["config"], "summary": summary, "builtin_tools": tools},
                     ensure_ascii=False))
    return 0


COMMANDS = {
    "launch": (5, command_launch),
    "review-waves": (3, command_review_waves),
    "report": (2, command_report),
    "scope-json": (0, command_scope_json),
}


def main(arguments):
    if not arguments or arguments[0] not in COMMANDS:
        print("usage: mcp-scope.py " + " | ".join(COMMANDS) + " [arguments ...]", file=sys.stderr)
        return 2
    expected, handler = COMMANDS[arguments[0]]
    if len(arguments) - 1 != expected:
        print(f"mcp-scope: {arguments[0]} expects {expected} arguments", file=sys.stderr)
        return 2
    try:
        return handler(*arguments[1:])
    except ScopeError as error:
        print(f"mcp-scope: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
