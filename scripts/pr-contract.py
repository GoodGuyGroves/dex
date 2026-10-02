#!/usr/bin/env python3
"""Check the `## Pull Requests` declarations in `.dex/dex.md`.

project-contract.py reads the raw values; this checks what they mean. A
project may name its PR template and map changed paths to labels:

    ## Pull Requests

    ```yaml
    template: docs/pr-template.md
    labels_when:
      - ".github/** => skip-ci"
    ```

    pr-contract.py template <repo-dir> <declared-path>
    pr-contract.py rules <rule>...
    pr-contract.py match <rule>...    (NUL-separated paths on stdin)

`template` prints the template's real path. It must be relative, resolve
inside the repository (a symlink may point elsewhere in the repository, not
out of it), and be a readable, non-empty regular file.

`rules` prints each rule as `glob<TAB>label`. A rule is split on its first
` => ` and both sides are trimmed. A label with a comma is refused, because
`gh pr edit --add-label` splits its value on commas.

`match` prints each label whose glob matches at least one path, once, in rule
order. Globs are fnmatch patterns matched case-sensitively, and a leading
`**/` also matches at the top level, as for `review_sensitive_paths`.

Exit 0 on success and 2 when a declaration is unusable, with the reason on
stderr. One bad rule makes the whole set unusable, so a typo never applies
half the labels.
"""

import fnmatch
import os
import sys
from pathlib import Path

UNUSABLE = 2
ARROW = " => "
USAGE = "Usage: pr-contract.py template <repo-dir> <path> | rules <rule>... | match <rule>..."


def template(repo_dir, declared):
    if Path(declared).is_absolute():
        return f"PR template '{declared}' must be relative to the repository root"
    root = Path(repo_dir).resolve()
    target = (root / declared).resolve()
    if target != root and root not in target.parents:
        return f"PR template '{declared}' resolves outside the repository"
    if not target.is_file():
        return f"PR template '{declared}' is not a regular file"
    try:
        if target.stat().st_size == 0:
            return f"PR template '{declared}' is empty"
        with target.open("rb"):
            pass
    except OSError as error:
        return f"PR template '{declared}' is not readable: {error.strerror}"
    print(target)
    return None


def parse_rules(raw_rules):
    rules = []
    for raw in raw_rules:
        glob, arrow, label = raw.partition(ARROW)
        glob, label = glob.strip(), label.strip()
        if not arrow:
            return None, f"label rule '{raw}' is not '<glob> => <label>'"
        if not glob or not label:
            return None, f"label rule '{raw}' has an empty glob or label"
        if "," in label:
            return None, f"label rule '{raw}' has a comma in its label"
        if any(ord(char) < 32 or ord(char) == 127 for char in glob + label):
            return None, f"label rule '{raw}' has a control character"
        rules.append((glob, label))
    return rules, None


def matches(glob, path):
    if fnmatch.fnmatchcase(path, glob):
        return True
    return glob.startswith("**/") and fnmatch.fnmatchcase(path, glob[3:])


def main(argv):
    if len(argv) < 2:
        print(USAGE, file=sys.stderr)
        return UNUSABLE
    command, args = argv[1], argv[2:]
    if command == "template" and len(args) == 2:
        problem = template(*args)
        if problem:
            print(problem, file=sys.stderr)
            return UNUSABLE
        return 0
    if command not in ("rules", "match"):
        print(f"pr-contract.py: unknown command '{command}'", file=sys.stderr)
        return UNUSABLE
    rules, problem = parse_rules(args)
    if rules is None:
        print(problem, file=sys.stderr)
        return UNUSABLE
    if command == "rules":
        for glob, label in rules:
            print(f"{glob}\t{label}")
        return 0
    paths = [
        os.fsdecode(item).replace("\\", "/")
        for item in sys.stdin.buffer.read().split(b"\0")
        if item
    ]
    seen = set()
    for glob, label in rules:
        if label in seen:
            continue
        if any(matches(glob, path) for path in paths):
            seen.add(label)
            print(label)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
