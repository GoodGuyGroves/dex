"""Dex state paths, resolved the way lib/common.sh resolves them.

Hooks run straight from settings.json, without common.sh, so in a session Dex
did not launch they see only what the environment holds. This is the Python
reading of the same table: an explicit variable wins, then DEX_HOME/<sub>,
then the legacy location under HOME. Empty counts as unset everywhere.
scripts/dex-paths.cjs is the Node copy; tests/dex-home-paths-test.sh keeps
all three in step.

`python3 hooks/dex_paths.py` prints NAME=value for every entry, and
`python3 hooks/dex_paths.py NAME` just that one value.
"""
import os

# name: (path under DEX_HOME, legacy path under HOME)
PATHS = {
    'DX_STATE_DIR': ('state', '.claude/.dex-phases'),
    'DX_LOOP_DIR': ('loops', '.claude/.dex-loops'),
    'DX_ARTIFACT_DIR': ('artifacts', '.claude/.dex-artifacts'),
    'DX_TOOL_DIR': ('tools', '.claude/.dex-tools'),
    'DX_RUN_ROOT': ('runs', '.dex/runs'),
    'DX_MAINTENANCE_DIR': ('maintenance', '.claude/.dex-maintenance'),
    'DX_LOG_DIR': ('logs', '.dex/logs'),
    'DX_RESCUE_DIR': ('rescue', '.dex/rescue'),
    'DEX_ROUTER_HOME': ('router', '.dex/router'),
    'DX_PROVIDER_GLOBAL_CONFIG': ('providers.json', '.dex/providers.json'),
    'DX_SETUP_FILE': ('setup.json', '.dex/setup.json'),
    'DX_INSTALL_STATE_FILE': ('install-state.json', '.claude/.dex-install-state.json'),
}


def dex_home(env=None):
    """DEX_HOME without a trailing /, or '' when unset or not absolute."""
    env = os.environ if env is None else env
    root = env.get('DEX_HOME') or ''
    while len(root) > 1 and root.endswith('/'):
        root = root[:-1]
    return root if root.startswith('/') else ''


def dex_path(name, env=None):
    env = os.environ if env is None else env
    if env.get(name):
        return env[name]
    sub, legacy = PATHS[name]
    root = dex_home(env)
    if root:
        return root + '/' + sub
    return (env.get('HOME') or os.path.expanduser('~')) + '/' + legacy


if __name__ == '__main__':
    import sys
    if len(sys.argv) > 1:
        print(dex_path(sys.argv[1]))
    else:
        for key in PATHS:
            print('%s=%s' % (key, dex_path(key)))
