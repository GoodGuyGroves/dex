'use strict';
// Sandbox the router home before any scripts/ccr module can resolve it.
// This suite does not reach live state today; tests/ccr-test-isolation.py
// does not depend on that staying true. An outer sandbox wins.
process.env.DEX_ROUTER_HOME ||= require('node:path').join(require('node:os').tmpdir(), 'dex-ccr-unused-state');
const test = require('node:test');
const assert = require('node:assert/strict');
const ipc = require('../scripts/ccr/ipc.cjs');
const { createGatewayPlugin } = require('../scripts/ccr/core-plugin.cjs');

async function authenticate(t, body, sourceAdapterKey = 'anthropic_messages', provider = 'openai', clientHeaders = {}) {
  t.mock.method(ipc, 'call', async () => ({ headers: { authorization: 'Bearer synthetic' } }));
  const plugin = createGatewayPlugin().providerHooks.find(hook => hook.providerName === `dex-${provider}`);
  return plugin.authenticate({ sourceAdapterKey, request: { headers: { 'x-ccr-dex-account-ticket': 'synthetic-ticket', ...clientHeaders } },
    upstreamRequest: { headers: {}, body } });
}

test('a converted Claude session carries a stable OpenAI prompt cache key', async t => {
  const session = { 'x-claude-code-session-id': '9b2a4e1c-0000-4000-8000-000000000001' };
  const first = (await authenticate(t, { input: [] }, 'anthropic_messages', 'openai', session)).value.body.prompt_cache_key;
  const again = (await authenticate(t, { input: [] }, 'anthropic_messages', 'openai', session)).value.body.prompt_cache_key;
  assert.match(first, /^dex-[0-9a-f]{40}$/);
  assert.equal(again, first, 'every turn of one conversation shares the key');
  assert.ok(!first.includes('9b2a4e1c'), 'the client session id does not leave the host');
  const subagent = (await authenticate(t, { input: [] }, 'anthropic_messages', 'openai',
    { ...session, 'x-claude-code-agent-id': 'agent-1' })).value.body.prompt_cache_key;
  assert.notEqual(subagent, first, 'a subagent has its own prompt, so its own key');
  const other = (await authenticate(t, { input: [] }, 'anthropic_messages', 'openai',
    { 'x-claude-code-session-id': '9b2a4e1c-0000-4000-8000-000000000002' })).value.body.prompt_cache_key;
  assert.notEqual(other, first);
});

test('the cache key never overrides a client key or reaches other providers', async t => {
  const session = { 'x-claude-code-session-id': 'session-a' };
  assert.equal((await authenticate(t, { input: [], prompt_cache_key: 'client-key' }, 'anthropic_messages', 'openai', session)).value.body.prompt_cache_key, 'client-key');
  assert.equal((await authenticate(t, { input: [] }, 'openai_responses', 'openai', session)).value.body.prompt_cache_key, undefined);
  assert.equal((await authenticate(t, { input: [] })).value.body.prompt_cache_key, undefined, 'no session header, no key');
  assert.equal((await authenticate(t, { messages: [] }, 'anthropic_messages', 'anthropic', session)).value.body.prompt_cache_key, undefined);
});

test('Claude thinking becomes stateless reasoning summaries without losing text or tool history', async t => {
  const body = { input: [
    { type: 'reasoning', id: 'rs_generated', summary: [{ type: 'summary_text', text: 'Existing summary' }], content: [
      { type: 'reasoning_text', text: 'First thought' }, { type: 'reasoning_text', text: 'Second thought' }
    ] },
    { type: 'function_call', call_id: 'call_test', name: 'Bash', arguments: '{}' },
    { type: 'function_call_output', call_id: 'call_test', output: 'done' }
  ] };
  const original = structuredClone(body);
  const result = await authenticate(t, body);
  assert.equal(result.ok, true);
  assert.deepEqual(result.value.body.input, [
    { type: 'reasoning', summary: ['Existing summary', 'First thought', 'Second thought'].map(text => ({ type: 'summary_text', text })) },
    ...body.input.slice(1)
  ]);
  assert.deepEqual(body, original);
});

test('native OpenAI reasoning and encrypted history retain their original fields', async t => {
  const input = [
    { type: 'reasoning', id: 'rs_native', summary: [], encrypted_content: 'synthetic-encrypted', content: [{ type: 'reasoning_text', text: 'Native thought' }] },
    { type: 'reasoning', id: 'rs_empty', summary: [], content: [] }
  ];
  assert.deepEqual((await authenticate(t, { input }, 'openai_responses')).value.body.input, input);
  assert.deepEqual((await authenticate(t, { input })).value.body.input, input);
});

test('Anthropic requests retain their thinking blocks and signatures', async t => {
  const body = { messages: [{ role: 'assistant', content: [{ type: 'thinking', thinking: 'A thought', signature: 'synthetic-signature' }] }] };
  assert.deepEqual((await authenticate(t, body, 'anthropic_messages', 'anthropic')).value.body, body);
});

test('Responses conversion includes the subscription prelude without replacing client instructions', async t => {
  const prelude = "You are Claude Code, Anthropic's official CLI for Claude.";
  for (const system of [undefined, 'Original Codex instructions', [{ type: 'text', text: 'Original Codex instructions', cache_control: { type: 'ephemeral' } }]]) {
    const body = { model: 'test', system, messages: [{ role: 'user', content: 'hello' }] };
    const original = structuredClone(body);
    const result = await authenticate(t, body, 'openai_responses', 'anthropic');
    assert.equal(result.ok, true);
    assert.equal(result.value.body.system[0].text, prelude);
    assert.deepEqual(result.value.body.system.slice(1), typeof system === 'string' ? [{ type: 'text', text: system }] : system || []);
    assert.deepEqual(result.value.body.messages, original.messages);
    assert.deepEqual(body, original);
    assert.deepEqual(new Set(result.value.headers['anthropic-beta'].split(',')), new Set(['oauth-2025-04-20', 'claude-code-20250219']));
    const again = await authenticate(t, result.value.body, 'openai_responses', 'anthropic');
    assert.deepEqual(again.value.body, result.value.body, 'repeated conversion must not duplicate the prelude');
  }
  const native = { system: 'Native Claude instructions', messages: [] };
  assert.deepEqual((await authenticate(t, native, 'anthropic_messages', 'anthropic')).value.body, native);
  assert.equal((await authenticate(t, { system: {} }, 'openai_responses', 'anthropic')).ok, false);
});

test('OpenCode Messages traffic to a subscription carries the prelude Claude Code would send', async t => {
  const prelude = "You are Claude Code, Anthropic's official CLI for Claude.";
  const body = { system: [{ type: 'text', text: 'You are opencode.' }], messages: [{ role: 'user', content: 'hello' }] };
  const original = structuredClone(body);
  const result = await authenticate(t, body, 'anthropic_messages', 'anthropic', { 'x-dex-client': 'opencode' });
  assert.equal(result.ok, true);
  assert.equal(result.value.body.system[0].text, prelude);
  assert.deepEqual(result.value.body.system.slice(1), original.system);
  assert.deepEqual(body, original);
  assert.deepEqual(new Set(result.value.headers['anthropic-beta'].split(',')), new Set(['oauth-2025-04-20', 'claude-code-20250219']));
  const again = await authenticate(t, result.value.body, 'anthropic_messages', 'anthropic', { 'x-dex-client': 'opencode' });
  assert.deepEqual(again.value.body, result.value.body, 'a repeated attempt must not duplicate the prelude');
  // Claude Code sends its own identity, so its requests pass through untouched.
  const claude = await authenticate(t, structuredClone(original), 'anthropic_messages', 'anthropic', { 'x-dex-client': 'claude' });
  assert.deepEqual(claude.value.body, original);
  assert.equal(claude.value.headers['anthropic-beta'], 'oauth-2025-04-20');
  // Other providers need no prelude.
  assert.deepEqual((await authenticate(t, structuredClone(original), 'anthropic_messages', 'openrouter', { 'x-dex-client': 'opencode' })).value.body.system, original.system);
});

test('the native client name stays on the host', async t => {
  t.mock.method(ipc, 'call', async () => ({ headers: { authorization: 'Bearer synthetic' } }));
  const plugin = createGatewayPlugin().providerHooks.find(hook => hook.providerName === 'dex-openrouter');
  const result = await plugin.authenticate({ sourceAdapterKey: 'anthropic_messages',
    request: { headers: { 'x-ccr-dex-account-ticket': 'synthetic-ticket', 'x-dex-client': 'opencode' } },
    upstreamRequest: { headers: { 'x-dex-client': 'opencode', 'X-Dex-Client': 'opencode' }, body: { messages: [] } } });
  assert.deepEqual(Object.keys(result.value.headers).filter(name => name.toLowerCase() === 'x-dex-client'), []);
});

test('Responses conversion preserves signature-only Claude thinking before CCR drops it', () => {
  const payload = { content: [{ type: 'thinking', thinking: '', signature: 'synthetic-signature' },
    { type: 'tool_use', id: 'tool_one', name: 'Read', input: {} }] };
  const hook = createGatewayPlugin().providerHooks.find(item => item.providerName === 'dex-anthropic');
  assert.deepEqual(hook.transformResponse({ sourceAdapterKey: 'anthropic_messages', upstreamPayload: payload }).value, payload);
  const converted = hook.transformResponse({ sourceAdapterKey: 'openai_responses', upstreamPayload: payload }).value;
  assert.equal(converted.content[0].type, 'redacted_thinking');
  const restored = { messages: [{ role: 'assistant', content: converted.content }] };
  require('../scripts/ccr/history.cjs').restoreAnthropic(restored);
  assert.deepEqual(restored.messages[0].content, payload.content);
  assert.equal(payload.content[0].type, 'thinking');
});

// A chat-completions provider is reached through conversion, which drops the
// client's own reasoning dialect. These cover the translation that replaces it.
async function chatAuthenticate(t, clientBody, upstreamBody = { model: 'z-ai/glm-5.3', messages: [] }) {
  t.mock.method(ipc, 'call', async () => ({ headers: { authorization: 'Bearer synthetic-key' } }));
  const plugin = createGatewayPlugin().providerHooks.find(hook => hook.providerName === 'dex-openrouter');
  return plugin.authenticate({ sourceAdapterKey: 'anthropic_messages',
    request: { headers: { 'x-ccr-dex-account-ticket': 'synthetic-ticket' }, body: clientBody },
    upstreamRequest: { headers: { authorization: 'Bearer client-key', 'x-ccr-dex-account-ticket': 'synthetic-ticket' }, body: upstreamBody } });
}

test('reasoning effort survives conversion to a chat-completions provider', async t => {
  const messages = await chatAuthenticate(t, { output_config: { effort: 'high' }, messages: [] });
  assert.deepEqual(messages.value.body.reasoning, { effort: 'high' });
  // The Responses dialect carries the same request.
  const responses = await chatAuthenticate(t, { reasoning: { effort: 'medium' }, input: [] });
  assert.deepEqual(responses.value.body.reasoning, { effort: 'medium' });
  // Dex has levels above what the wire format names; asking for more reasoning
  // must never quietly yield less than 'high'.
  for (const level of ['xhigh', 'max']) {
    const clamped = await chatAuthenticate(t, { output_config: { effort: level }, messages: [] });
    assert.deepEqual(clamped.value.body.reasoning, { effort: 'high' }, `${level} clamps to high`);
  }
});

test('a chat-completions provider adds no reasoning field when none was requested', async t => {
  const none = await chatAuthenticate(t, { messages: [] });
  assert.equal('reasoning' in none.value.body, false);
  const junk = await chatAuthenticate(t, { output_config: { effort: 'not-a-level' }, messages: [] });
  assert.equal('reasoning' in junk.value.body, false);
});

test('a metered provider gets its account credential and none of the client key', async t => {
  const result = await chatAuthenticate(t, { output_config: { effort: 'high' }, messages: [] });
  assert.equal(result.ok, true);
  assert.equal(result.value.headers.authorization, 'Bearer synthetic-key');
  assert.equal(result.value.headers['x-ccr-dex-account-ticket'], undefined, 'the ticket never reaches the provider');
  // Anthropic's OAuth beta belongs to Anthropic requests only.
  assert.equal(result.value.headers['anthropic-beta'], undefined);
  assert.equal(result.value.body.model, 'z-ai/glm-5.3', 'the upstream ID is what the provider is called');
});

test('the helpers are loaded again when the extension reports a new source revision', async t => {
  const file = require.resolve('../scripts/ccr/history.cjs');
  let revision = 'first';
  t.mock.method(ipc, 'call', async () => ({ headers: { authorization: 'Bearer synthetic' }, source_revision: revision }));
  const hook = createGatewayPlugin().providerHooks.find(item => item.providerName === 'dex-anthropic');
  const call = () => hook.authenticate({ sourceAdapterKey: 'anthropic_messages', request: { headers: { 'x-ccr-dex-account-ticket': 'synthetic-ticket' } }, upstreamRequest: { headers: {}, body: { messages: [] } } });
  assert.equal((await call()).ok, true);
  const loaded = require.cache[file];
  assert.ok(loaded);
  assert.equal((await call()).ok, true);
  assert.equal(require.cache[file], loaded, 'an unchanged revision keeps the loaded helpers');
  revision = 'second';
  assert.equal((await call()).ok, true);
  assert.notEqual(require.cache[file], loaded, 'a new revision loads them again');
});
