'use strict';
// OpenCode loads every module in its plugins directory. Native routing installs
// a small module there that calls dexRouter with the helper to run. Each time
// OpenCode starts, the plugin reads the gateway address, the models to offer
// and a capability for the OpenCode process from the live route, so nothing
// is copied into OpenCode's config.
const { execFile } = require('node:child_process');

// A capability belongs to the gateway that issued it, and a router restart
// issues new ones. A long-running OpenCode asks again at this interval instead
// of failing every request until it is relaunched.
const REFRESH_MS = 60000;

function helper({ node, script, root }, args) {
  return new Promise((resolve, reject) => {
    execFile(node, [script, ...args, root], { encoding: 'utf8', timeout: 45000 }, (error, stdout, stderr) => {
      if (error) reject(new Error(String(stderr || '').trim() || error.message));
      else resolve(stdout.trim());
    });
  });
}

function dexRouter(options) {
  return async () => {
    let token = null, issued = 0;
    async function capability() {
      if (token && Date.now() - issued < REFRESH_MS) return token;
      // A failed refresh keeps the capability it has: it is still valid unless
      // the router restarted, and waiting a full interval avoids re-running a
      // helper that is failing on every request.
      try { token = await helper(options, ['auth', 'opencode']); }
      catch (error) { if (!token) throw error; }
      finally { issued = Date.now(); }
      return token;
    }
    return {
      // When this throws, OpenCode logs a failed config hook and starts with
      // its own providers only.
      async config(config) {
        const setup = JSON.parse(await helper(options, ['provider', 'opencode']));
        token = setup.token; issued = Date.now();
        config.provider = { ...config.provider, dex: setup.provider };
        // A model named in the user's own OpenCode config stays their choice.
        config.model ??= setup.model;
      },
      async 'chat.headers'(input, output) {
        if (input.model?.providerID !== 'dex') return;
        output.headers['x-api-key'] = await capability();
      }
    };
  };
}

module.exports = { dexRouter, REFRESH_MS };
