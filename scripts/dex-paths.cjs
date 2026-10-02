'use strict';
// Dex state paths, resolved the way lib/common.sh resolves them: an explicit
// variable wins, then DEX_HOME/<sub>, then the legacy location under HOME.
// Empty counts as unset. hooks/dex_paths.py is the Python copy;
// tests/dex-home-paths-test.sh keeps all three in step.
// `node scripts/dex-paths.cjs` prints NAME=value for every entry.
const os = require('node:os');

// name: [path under DEX_HOME, legacy path under HOME]
const PATHS = {
  DX_STATE_DIR: ['state', '.claude/.dex-phases'],
  DX_LOOP_DIR: ['loops', '.claude/.dex-loops'],
  DX_ARTIFACT_DIR: ['artifacts', '.claude/.dex-artifacts'],
  DX_TOOL_DIR: ['tools', '.claude/.dex-tools'],
  DX_RUN_ROOT: ['runs', '.dex/runs'],
  DX_MAINTENANCE_DIR: ['maintenance', '.claude/.dex-maintenance'],
  DX_LOG_DIR: ['logs', '.dex/logs'],
  DX_RESCUE_DIR: ['rescue', '.dex/rescue'],
  DEX_ROUTER_HOME: ['router', '.dex/router'],
  DX_PROVIDER_GLOBAL_CONFIG: ['providers.json', '.dex/providers.json'],
  DX_SETUP_FILE: ['setup.json', '.dex/setup.json'],
  DX_INSTALL_STATE_FILE: ['install-state.json', '.claude/.dex-install-state.json']
};

// DEX_HOME without a trailing /, or '' when unset or not absolute.
function dexHome(env = process.env) {
  let root = env.DEX_HOME || '';
  while (root.length > 1 && root.endsWith('/')) root = root.slice(0, -1);
  return root.startsWith('/') ? root : '';
}
// Plain concatenation, as the shell does, so the readers agree byte for byte.
function dexPath(name, env = process.env) {
  if (env[name]) return env[name];
  const [sub, legacy] = PATHS[name];
  const root = dexHome(env);
  return root ? `${root}/${sub}` : `${env.HOME || os.homedir()}/${legacy}`;
}

if (require.main === module) {
  for (const name of Object.keys(PATHS)) console.log(`${name}=${dexPath(name)}`);
}
module.exports = { PATHS, dexHome, dexPath };
