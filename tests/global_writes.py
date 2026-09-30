#!/usr/bin/env python3
"""Snapshot, diff and parity helpers for tests/no-global-writes-test.sh.

  snapshot <root> <out.json> [--exclude <path>]...
      Record every entry under <root>: type, mode, sha256 and symlink target.
      Directories are included and mtimes ignored, so the result is the same on
      macOS and Linux. A JSON file also gets an entry per key, two levels deep,
      and per element of a list at those levels (`#hooks.Stop[1a2b3c4d]`); a
      TOML file gets one per [table]. So a Dex hook added beside the user's is
      told apart from a user hook removed or rewritten.
  diff <before.json> <after.json> <step>
      Print `step<TAB>change<TAB>path<TAB>kind` rows for every entry that
      changed; kind is file, dir, link, key, other or unreadable. No
      directory or file carries its contents: each entry is its own row.
  check <observed.tsv> <expected.tsv> <dex-dir>
      Every observed row must match an expected row, and every expected row
      must match something observed. A stale row fails too: the unit that fixes
      a write deletes its own rows.
  parity <installed.jsonl> <isolated.jsonl> <allow.tsv>
      Compare the configuration each stub `claude` launch received, run by
      run; differences not allowlisted fail.
  seed <home> [--no-skills] / seeded <home> [--no-skills]
      Write the representative user files, or check that they survived.
  hooks-ok <hooks.jsonl>...
      Every hook the stub fired exited 0 (allow) or 2 (block), in time.
  dex-hooks <home> <dex-dir> <step>
      Every hook in ~/.claude/settings.json is the user's or runs from $DEX_DIR.
  selftest [<dex-dir>]
      Regression cases for diff folding and hook resolution.
  leftovers <sandbox> <wait-seconds>
      Wait for the sandbox's processes to finish; list and kill any left.

Stdlib only, and it has to run on the python3 that ships with macOS (3.9).
"""

import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import time


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _json_sha(value):
    return _sha(json.dumps(value, sort_keys=True).encode())


def _expand(entries, prefix, value, depth):
    """One entry per key (two levels) and per list element at those levels."""
    if isinstance(value, dict) and depth < 2:
        for key, item in value.items():
            name = "%s%s%s" % (prefix, "#" if depth == 0 else ".", key)
            entries[name] = _json_sha(item)
            _expand(entries, name, item, depth + 1)
    elif isinstance(value, list) and depth > 0:
        for item in value:
            entries["%s[%s]" % (prefix, _json_sha(item)[:8])] = "element"


def _structured_entries(rel, data):
    entries = {}
    if rel.endswith(".json"):
        try:
            value = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return entries
        if isinstance(value, dict):
            _expand(entries, rel, value, 0)
    elif rel.endswith(".toml"):
        table, lines = "", {}
        for line in data.decode("utf-8", "replace").splitlines():
            header = re.match(r"^\s*\[([^\]]+)\]\s*$", line)
            if header:
                table = header.group(1).strip()
            lines.setdefault(table, []).append(line)
        for table, body in lines.items():
            entries["%s#%s" % (rel, table or "(top)")] = _sha("\n".join(body).strip().encode())
    return entries


def snapshot(root, excludes):
    root = os.path.abspath(root)
    excludes = [os.path.abspath(path) for path in excludes]
    entries = {}

    def unreadable(error):
        entries[os.path.relpath(error.filename, root)] = "unreadable %s" % error.strerror

    for directory, dirs, files in os.walk(root, onerror=unreadable, followlinks=False):
        # os.walk lists a symlink to a directory among dirs but never enters it.
        dirs[:] = sorted(name for name in dirs if os.path.join(directory, name) not in excludes)
        for name in sorted(dirs + files):
            full = os.path.join(directory, name)
            if full in excludes:
                continue
            rel = os.path.relpath(full, root)
            try:
                info = os.lstat(full)
                mode = format(stat.S_IMODE(info.st_mode), "o")
                if stat.S_ISLNK(info.st_mode):
                    entries[rel] = "link %s" % os.readlink(full)
                elif stat.S_ISDIR(info.st_mode):
                    entries[rel] = "dir %s" % mode
                elif stat.S_ISREG(info.st_mode):
                    with open(full, "rb") as handle:
                        data = handle.read()
                    # A hard link shares its content with a path elsewhere,
                    # so it is its own kind, never absorbed by a fold row.
                    kind = "hardlink" if info.st_nlink > 1 else "file"
                    entries[rel] = "%s %s %s" % (kind, mode, _sha(data))
                    entries.update(_structured_entries(rel, data))
                else:
                    entries[rel] = "other %s" % mode
            except OSError as error:
                entries[rel] = "unreadable %s" % error.strerror
    return entries


def diff(before, after, step):
    rows = []
    for path in sorted(set(before) | set(after)):
        if path not in before:
            rows.append((path, "added"))
        elif path not in after:
            rows.append((path, "removed"))
        elif before[path] != after[path]:
            rows.append((path, "modified"))
    # A modified file or key whose own keys changed is described by those. A
    # file's keys start at `#`; `.` and `[` only separate keys once inside one,
    # so a sibling like `.zshrc.bak` never hides a `.zshrc` edit.
    paths = [path for path, _ in rows]

    def described_below(path):
        separators = "#.[" if "#" in path else "#"
        return any(other != path and other.startswith(path) and other[len(path)] in separators
                   for other in paths)

    return ["%s\t%s\t%s\t%s" % (step, change, path, _kind(after.get(path) or before[path]))
            for path, change in rows if change != "modified" or not described_below(path)]


def _kind(entry):
    word = entry.split(" ", 1)[0]
    return word if word in ("link", "hardlink", "dir", "file", "other", "unreadable") else "key"


def _read_tsv(filename):
    rows = []
    with open(filename, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if line.strip() and not line.lstrip().startswith("#"):
                rows.append((number, line.split("\t")))
    return rows


def _dex_skills(dex_dir):
    skills = os.path.join(dex_dir, "skills")
    return sorted(name for name in os.listdir(skills)
                  if os.path.isfile(os.path.join(skills, name, "SKILL.md")))


def _glob(glob, star="[^/]*", dex_dir=None, fold=False):
    """A glob as a compiled regex. In paths `*` stays inside one segment and
    `{dex-skill}` is one Dex skill name; a fold row also covers everything
    beneath the path it names."""
    regex = ""
    for token in re.split(r"(\{dex-skill\}|\*)", glob):
        if token == "*":
            regex += star
        elif token == "{dex-skill}" and dex_dir:
            regex += "(?:%s)" % "|".join(re.escape(name) for name in _dex_skills(dex_dir))
        else:
            regex += re.escape(token)
    below = r"(?:[.\[].*)?" if "#" in glob else "(?:[/#].*)?"  # a key's keys, a path's children
    return re.compile("^%s%s$" % (regex, below if fold else ""))


def check(observed_file, expected_file, dex_dir):
    expected = []
    for number, fields in _read_tsv(expected_file):
        if len(fields) < 5:
            raise SystemExit("%s:%d: want unit, step, change, path, flags"
                             % (expected_file, number))
        flags = fields[4].split(",")
        if ({"darwin", "linux"} & set(flags)) and sys.platform not in flags:
            continue
        expected.append({"line": number, "unit": fields[0], "change": fields[2],
                         "path": fields[3], "hits": dict.fromkeys(fields[1].split(","), 0),
                         "fold": "fold" in flags,
                         "regex": _glob(fields[3], dex_dir=dex_dir, fold="fold" in flags)})
    unexpected = []
    for _, fields in _read_tsv(observed_file):
        step, change, path, kind = fields[:4]
        matched = False
        for row in expected:
            # A fold row absorbs files, directories and keys. A symlink or
            # anything stranger has to be named by a row of its own: a link
            # planted in a cache could point anywhere.
            if row["fold"] and kind not in ("file", "dir", "key"):
                continue
            if (step in row["hits"] and row["change"] in (change, "*")
                    and row["regex"].match(path)):
                row["hits"][step] += 1
                matched = True
        if not matched:
            unexpected.append((step, change, path, kind))
    for step, change, path, kind in unexpected:
        print("UNEXPECTED WRITE  step=%-12s %-8s ~/%s (%s)" % (step, change, path, kind))
    stale = 0
    for row in expected:
        for step, hits in row["hits"].items():
            if not hits:
                stale += 1
                print("STALE EXPECTATION unit %s (%s:%d) step=%s %s ~/%s: nothing matched; "
                      "delete the row once its unit removes the write"
                      % (row["unit"], os.path.basename(expected_file), row["line"],
                         step, row["change"], row["path"]))
    return 1 if unexpected or stale else 0


# ── Effective launch configuration ───────────────────────────────────────


def _load_json(filename):
    try:
        with open(filename, encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _settings_arg(value):
    value = value.strip()
    if value.startswith("{"):
        try:
            parsed = json.loads(value)
            return parsed if isinstance(parsed, dict) else {}
        except ValueError:
            return {}
    return _load_json(value)


def _flag_values(argv, flag):
    values = []
    for index, arg in enumerate(argv):
        if arg == flag and index + 1 < len(argv):
            values.append(argv[index + 1])
        elif arg.startswith(flag + "="):
            values.append(arg.split("=", 1)[1])
    return values


def _git_root(cwd):
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=cwd,
                             capture_output=True, text=True, check=True).stdout.strip()
        return top or os.path.abspath(cwd)
    except (OSError, subprocess.CalledProcessError):
        return os.path.abspath(cwd)


def settings_layers(argv, env, cwd):
    """Claude Code's settings sources for a launch: user, project, local, --settings."""
    config_dir = env.get("CLAUDE_CONFIG_DIR") or os.path.join(env.get("HOME", ""), ".claude")
    root = _git_root(cwd)
    layers = [_load_json(os.path.join(config_dir, "settings.json")),
              _load_json(os.path.join(root, ".claude", "settings.json")),
              _load_json(os.path.join(root, ".claude", "settings.local.json"))]
    return layers + [_settings_arg(value) for value in _flag_values(argv, "--settings")]


def _skill_names(directory):
    try:
        return [name for name in sorted(os.listdir(directory))
                if os.path.isfile(os.path.join(directory, name, "SKILL.md"))]
    except OSError:
        return []


def effective_config(argv, env, cwd):
    """What a real `claude` started with this argv, env and cwd would load:
    hooks and settings from every settings layer; skills from the user and
    project skill directories and each --plugin-dir; MCP servers from
    ~/.claude.json (user and local scope), the project's .mcp.json and each
    --mcp-config, or only the latter under --strict-mcp-config."""
    home = env.get("HOME", "")
    config_dir = env.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    state_file = (os.path.join(config_dir, ".claude.json") if env.get("CLAUDE_CONFIG_DIR")
                  else os.path.join(home, ".claude.json"))
    root = _git_root(cwd)
    hooks, settings, plugins, settings_mcp = set(), set(), set(), set()
    for layer in settings_layers(argv, env, cwd):
        settings.update("%s=%s" % (key, json.dumps(value, sort_keys=True))
                        for key, value in layer.items() if key != "hooks")
        for event, groups in (layer.get("hooks") or {}).items():
            for group in groups if isinstance(groups, list) else []:
                for hook in (group.get("hooks") or []) if isinstance(group, dict) else []:
                    if isinstance(hook, dict):
                        hooks.add("%s|%s|%s" % (event, group.get("matcher", ""),
                                                hook.get("command", "")))
        plugins.update(ref for ref, on in (layer.get("enabledPlugins") or {}).items() if on)
        settings_mcp.update(layer.get("mcpServers") or {})

    skills = set(_skill_names(os.path.join(config_dir, "skills")))
    skills.update(_skill_names(os.path.join(root, ".claude", "skills")))
    for plugin_dir in _flag_values(argv, "--plugin-dir"):
        plugins.add("dir:" + os.path.basename(os.path.normpath(plugin_dir)))
        skills.update(_skill_names(os.path.join(plugin_dir, "skills")))

    mcp = set()
    if "--strict-mcp-config" not in argv:
        state = _load_json(state_file)
        mcp.update("user:" + name for name in state.get("mcpServers") or {})
        local = (state.get("projects") or {}).get(root) or {}
        mcp.update("local:" + name for name in local.get("mcpServers") or {})
        mcp.update("project:" + name for name in
                   _load_json(os.path.join(root, ".mcp.json")).get("mcpServers") or {})
        mcp.update("settings:" + name for name in settings_mcp)
    for config in _flag_values(argv, "--mcp-config"):
        mcp.update("flag:" + name for name in _settings_arg(config).get("mcpServers") or {})

    env_items = sorted("%s=%s" % (name, value) for name, value in env.items()
                       if name.startswith(("DEX_", "DX_", "CLAUDE_")))
    return {"hooks": sorted(hooks), "skills": sorted(skills), "plugins": sorted(plugins),
            "mcp": sorted(mcp), "settings": sorted(settings), "env": env_items}


def _normalise(value, replacements):
    if isinstance(value, list):
        return [_normalise(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: _normalise(item, replacements) for key, item in value.items()}
    for old, new in replacements:
        if old:
            value = value.replace(old, new)
    return value


def load_launches(filename):
    """Launch records keyed by step label, with sandbox paths normalised."""
    launches = {}
    with open(filename, encoding="utf-8") as handle:
        for line in handle:
            record = json.loads(line)
            replacements = [(record.get("dex_dir", ""), "$DEX_DIR"),
                            (record.get("home", ""), "~")]
            config = _normalise(record["config"], replacements)
            launches.setdefault(record["step"], []).append(config)
    return launches


def parity(installed_file, isolated_file, allow_file):
    allow = [(_glob(fields[0], ".*"), fields[1], fields[2], _glob(fields[3], ".*"))
             for _, fields in _read_tsv(allow_file) if len(fields) >= 4]
    installed, isolated = load_launches(installed_file), load_launches(isolated_file)
    failures = 0
    for label in sorted(set(installed) | set(isolated)):
        left, right = installed.get(label, []), isolated.get(label, [])
        if len(left) != len(right):
            print("PARITY %-10s launch count: installed %d, isolated %d"
                  % (label, len(left), len(right)))
            failures += 1
            continue
        for index, (a, b) in enumerate(zip(left, right)):
            for field in sorted(set(a) | set(b)):
                for side, items in (("installed-only", set(a.get(field, [])) - set(b.get(field, []))),
                                    ("isolated-only", set(b.get(field, [])) - set(a.get(field, [])))):
                    for item in sorted(items):
                        if any(step.match(label) and rule_field == field
                               and rule_side in (side, "*") and item_re.match(item)
                               for step, rule_field, rule_side, item_re in allow):
                            continue
                        print("PARITY %-10s #%d %-9s %-14s %s" % (label, index, field, side, item))
                        failures += 1
    return 1 if failures else 0


# ── The representative user, seeded and checked from one place ──────────

USER_HOOK = {"matcher": "", "hooks": [{"type": "command", "command": "echo user-pre-compact"}]}
USER_FILES = {
    ".claude/settings.json": {"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]},
                              "hooks": {"PreCompact": [USER_HOOK]}},
    ".claude.json": {"numStartups": 3, "mcpServers": {"userServer": {"command": "user-mcp"}}},
}
USER_TEXT = {
    ".zshrc": "# user zshrc\nexport EDITOR=vi\n",
    ".codex/config.toml": 'model = "gpt-5"\n\n[mcp_servers.userServer]\ncommand = "user-mcp"\n',
    ".claude/skills/my-skill/SKILL.md": "---\nname: my-skill\ndescription: the user's own skill\n---\nMine.\n",
}


def seed(home, skills):
    for rel, value in USER_FILES.items():
        os.makedirs(os.path.dirname(os.path.join(home, rel)), exist_ok=True)
        with open(os.path.join(home, rel), "w", encoding="utf-8") as handle:
            json.dump(value, handle)
    for rel, text in USER_TEXT.items():
        if rel.startswith(".claude/skills/") and not skills:
            continue
        os.makedirs(os.path.dirname(os.path.join(home, rel)), exist_ok=True)
        with open(os.path.join(home, rel), "w", encoding="utf-8") as handle:
            handle.write(text)
    return 0


def seeded(home, skills):
    problems = []
    settings = _load_json(os.path.join(home, ".claude/settings.json"))
    for key in ("model", "permissions"):
        if settings.get(key) != USER_FILES[".claude/settings.json"][key]:
            problems.append("~/.claude/settings.json %s changed: %r" % (key, settings.get(key)))
    if USER_HOOK not in ((settings.get("hooks") or {}).get("PreCompact") or []):
        problems.append("~/.claude/settings.json lost the user's PreCompact hook")
    state = _load_json(os.path.join(home, ".claude.json"))
    if (state.get("mcpServers") or {}).get("userServer") != {"command": "user-mcp"}:
        problems.append("~/.claude.json lost mcpServers.userServer")
    if state.get("numStartups") != 3:
        problems.append("~/.claude.json numStartups changed")
    for rel, text in USER_TEXT.items():
        if rel.startswith(".claude/skills/") and not skills:
            continue
        try:
            with open(os.path.join(home, rel), encoding="utf-8") as handle:
                current = handle.read()
        except OSError:
            current = ""
        # Dex may append to these; the user's own text must stay first and whole.
        if not current.startswith(text):
            problems.append("~/%s lost the user's content" % rel)
    for problem in problems:
        print("USER DATA  " + problem)
    return 1 if problems else 0


def hooks_ok(files):
    bad = 0
    for filename in files:
        if not os.path.exists(filename):
            continue
        with open(filename, encoding="utf-8") as handle:
            for line in handle:
                record = json.loads(line)
                if record["exit"] not in (0, 2):
                    print("HOOK %s %s exited %s: %s" % (record["step"], record["event"],
                                                        record["exit"], record["command"]))
                    bad = 1
    return bad


def dex_hooks(home, dex_dir, step):
    """expected.tsv folds the hook events Dex adds whole, so their content is
    checked here: every hook in ~/.claude/settings.json is the user's own or
    runs something from $DEX_DIR."""
    user = {hook["command"] for hook in USER_HOOK["hooks"]}
    settings = _load_json(os.path.join(home, ".claude/settings.json"))
    bad = 0
    for event, groups in (settings.get("hooks") or {}).items():
        for group in groups if isinstance(groups, list) else []:
            for hook in (group.get("hooks") or []) if isinstance(group, dict) else []:
                command = hook.get("command", "") if isinstance(hook, dict) else repr(hook)
                if command not in user and not _runs_from(command, dex_dir):
                    print("FOREIGN HOOK      step=%-12s %s: %s" % (step, event, command))
                    bad = 1
    return bad


def _runs_from(command, dex_dir):
    """Does this hook's script, and any DEX_DIR default it sets, resolve under
    dex_dir? Dex renders `export DEX_DIR="${DEX_DIR:-<checkout>}"; bash
    "$DEX_DIR/hooks/<hook>"`; `$DEX_DIR/../x` and a link out both fail."""
    root = os.path.realpath(dex_dir)

    def inside(path):
        path = os.path.realpath(path)
        return os.path.commonpath([root, path]) == root

    default = re.search(r"\$\{DEX_DIR:-([^}]*)\}", command)
    value = default.group(1) if default else dex_dir
    if default and not inside(value):
        return False
    expanded = re.sub(r"\$\{DEX_DIR(:-[^}]*)?\}|\$DEX_DIR\b", lambda _: value, command)
    lexer = shlex.shlex(expanded, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        return False
    for token in tokens:
        if token in ("export", "bash", "sh", "python3", "env") or re.match(r"^\w+=", token) \
                or not token.strip(";&|()"):
            continue
        return "/" in token and inside(token)
    return False


def _ancestors():
    pids, pid = set(), os.getpid()
    while pid > 1 and pid not in pids:
        pids.add(pid)
        try:
            out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                                 capture_output=True, text=True).stdout.strip()
            pid = int(out or 0)
        except (OSError, ValueError):
            break
    return pids


def leftovers(box, wait, kill):
    """Processes still running for this sandbox after up to `wait` seconds:
    its path on their command line, or (Linux, where /proc shows it) its HOME
    in their environment. A detached process with neither is invisible here."""
    skip = _ancestors()
    deadline = time.monotonic() + wait
    while True:
        found = _sandbox_processes(box, skip)
        if not found or time.monotonic() >= deadline:
            break
        time.sleep(0.2)
    for pid, command in found:
        print("LEFTOVER PROCESS  %d %s" % (pid, command[:200]))
        if kill and pid > 0:
            # Its whole group, so a child it started goes too, but never ours.
            try:
                group = os.getpgid(pid)
                if group != os.getpgrp():
                    os.killpg(group, 9)
                else:
                    os.kill(pid, 9)
            except OSError:
                pass
    return 1 if found else 0


def _sandbox_processes(box, skip):
    result = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True,
                            text=True)
    if result.returncode != 0 or not result.stdout.strip():
        # A scan that cannot see processes must not pass for one that found none.
        return [(0, "ps failed (%s): %s" % (result.returncode, result.stderr.strip()))]
    listing = result.stdout
    box = box.rstrip("/") + "/"
    found = []
    for line in listing.splitlines():
        pid_text, _, command = line.strip().partition(" ")
        if not pid_text.isdigit() or int(pid_text) in skip:
            continue
        environment = b""
        try:
            with open("/proc/%s/environ" % pid_text, "rb") as handle:
                environment = handle.read()
        except OSError:
            pass
        if box in command or ("\0HOME=%shome\0" % box).encode() in b"\0" + environment + b"\0":
            found.append((int(pid_text), command))
    return found


def selftest(dex_dir):
    """Regressions in the matching logic itself, run before any sandbox."""
    rows = diff({".zshrc": "file 644 a"},
                {".zshrc": "file 644 b", ".zshrc.bak": "file 644 c"}, "s")
    assert rows == ["s\tmodified\t.zshrc\tfile", "s\tadded\t.zshrc.bak\tfile"], rows
    rows = diff({"f.json": "file 644 a", "f.json#k": "x"},
                {"f.json": "file 644 b", "f.json#k": "y", "f.json#k.sub": "z"}, "s")
    assert rows == ["s\tadded\tf.json#k.sub\tkey"], rows
    good = 'export DEX_DIR="${DEX_DIR:-%s}"; bash "$DEX_DIR/hooks/stop-sound.sh"' % dex_dir
    assert _runs_from(good, dex_dir), good
    for bad in ('bash "$DEX_DIR/../evil.sh"', "echo foreign",
                'export DEX_DIR="${DEX_DIR:-/tmp}"; bash "$DEX_DIR/hooks/stop-sound.sh"'):
        assert not _runs_from(bad, dex_dir), bad
    return 0


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    command, args = argv[1], argv[2:]
    if command == "snapshot" and len(args) >= 2:
        excludes = [args[i + 1] for i in range(2, len(args) - 1, 2) if args[i] == "--exclude"]
        with open(args[1], "w", encoding="utf-8") as handle:
            json.dump(snapshot(args[0], excludes), handle, indent=0, sort_keys=True)
        return 0
    if command == "diff" and len(args) == 3:
        rows = diff(_load_json(args[0]), _load_json(args[1]), args[2])
        if rows:
            print("\n".join(rows))
        return 0
    if command == "check" and len(args) == 3:
        return check(*args)
    if command == "parity" and len(args) == 3:
        return parity(*args)
    if command in ("seed", "seeded") and args:
        return (seed if command == "seed" else seeded)(args[0], "--no-skills" not in args)
    if command == "hooks-ok":
        return hooks_ok(args)
    if command == "dex-hooks" and len(args) == 3:
        return dex_hooks(*args)
    if command == "selftest":
        return selftest(args[0] if args else os.getcwd())
    if command == "leftovers" and len(args) == 2:
        return leftovers(args[0], float(args[1]), kill=True)
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
