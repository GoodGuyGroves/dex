'use strict';
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// The selection itself is scripts/mcp-scope.py, which every Dex launch path
// shares, so `dx context scope` and a project's `## MCP` phases read the same
// layers and disabled lists. This module keeps the router's interface.
const SCRIPT = path.join(__dirname, '..', 'mcp-scope.py');

// registry: the --mcp-config file dx_provider_claude built from Dex's MCP
// registry. It is the lowest layer, so the user's own servers of the same name
// win, and the scope's include list applies to it like any other.
function scope(policy, { home = os.homedir(), cwd = process.cwd(), root, env = process.env, registry } = {}) {
  if (!policy?.enabled) return null;
  // Only the names of set variables cross over: a server's ${VAR} references
  // are checked against them, and no value leaves this process.
  const request = { policy, home, cwd, root, registry, config_dir: env.CLAUDE_CONFIG_DIR || null,
    env_names: Object.keys(env).filter(name => env[name]) };
  const result = spawnSync('python3', [SCRIPT, 'scope-json'], { input: JSON.stringify(request), encoding: 'utf8', timeout: 10000, maxBuffer: 8 * 1024 * 1024 });
  let reply;
  try { reply = JSON.parse(result.stdout); } catch { reply = null; }
  if (result.status !== 0 || !reply) throw new Error(`Could not resolve the MCP scope: ${(result.stderr || result.error?.message || 'python3 failed').trim()}`);
  if (reply.error) throw new Error(reply.error);
  return reply;
}
module.exports = { scope };
