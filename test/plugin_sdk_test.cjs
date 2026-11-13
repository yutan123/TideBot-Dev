// Exercises the shipped SDK in isolation; no plugin is installed or bundled.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../assets/plugin_sdk.js'), 'utf8');

function host() {
  const results = new Map(), requests = [];
  const context = vm.createContext({__tideConfig: {token: 'secret'}, sendMessage(channel, raw) {
    const data = JSON.parse(raw);
    if (channel === 'tide.result') results.set(data.id, data);
    else if (channel === 'tide.host') requests.push(data);
    else throw new Error('Unexpected bridge channel');
  }});
  vm.runInContext(source, context);
  let sequence = 0;
  const tick = () => new Promise(resolve => setImmediate(resolve));
  async function call(kind, name, payload) {
    const id = ++sequence;
    context.__tideDispatch(id, kind, name, payload);
    for (let i = 0; i < 100; i++) {
      await tick();
      if (results.has(id)) {
        const result = results.get(id);
        if (result.error) throw new Error(result.error);
        return result.value;
      }
    }
    throw new Error('Unresolved invocation');
  }
  return {context, call, requests, tick, run: code => vm.runInContext(code, context)};
}

test('declarations must match registered tools in both directions', async () => {
  const h = host();
  h.run("tide.registerTool('first', args => args)");
  await h.call('validate', '', ['first']);
  await assert.rejects(h.call('validate', '', ['missing']), /Unregistered/);
  await assert.rejects(h.call('validate', '', []), /Undeclared/);
  assert.throws(() => h.run("tide.registerTool('first', () => null)"), /duplicate/);
});

test('async tool JSON roundtrip and exception isolation', async () => {
  const h = host();
  h.run("tide.registerTool('echo', async args => args); tide.registerTool('bad', () => {throw new Error('broken')})");
  const payload = {text: '引号\'"\\\n ${literal}', array: [false, null, 1]};
  assert.deepEqual(await h.call('tool', 'echo', payload), payload);
  await assert.rejects(h.call('tool', 'bad', {}), /broken/);
  assert.deepEqual(await h.call('tool', 'echo', {alive: true}), {alive: true});
});

test('hook transformations run in registration order and allow takeover', async () => {
  const h = host();
  h.run("tide.on('tool.before', p => ({...p, order: [1]})); tide.on('tool.before', async p => ({...p, order: [...p.order, 2], handled: true, result: {result: {ok: true}}}))");
  const result = await h.call('event', 'tool.before', {call: {}});
  assert.deepEqual(result.order, [1, 2]);
  assert.equal(result.handled, true);
  assert.equal(result.result.result.ok, true);
});

test('storage RPC resolves concurrently and host rejection reaches handler', async () => {
  const h = host();
  h.run("tide.registerTool('read', async () => Promise.all([tide.storage.get('a'), tide.storage.get('b')])); tide.registerTool('write', () => tide.storage.set('a', 7))");
  const read = h.call('tool', 'read', {});
  await h.tick();
  assert.deepEqual(h.requests.map(r => r.args.key), ['a', 'b']);
  h.context.__tideResolve(h.requests[1].id, 'second', null);
  h.context.__tideResolve(h.requests[0].id, 'first', null);
  assert.deepEqual(await read, ['first', 'second']);
  const write = h.call('tool', 'write', {});
  await h.tick();
  h.context.__tideResolve(h.requests[2].id, null, 'permission denied');
  await assert.rejects(write, /permission denied/);
});

test('lifecycle, UI actions and immutable config are available', async () => {
  const h = host();
  h.run("let active = false; tide.on('activate', () => {active = true}); tide.on('deactivate', () => {active = false}); tide.on('ui.action', p => ({ui: {type: 'text', text: p.values.message}, active, token: tide.config.token}))");
  assert.equal(h.run('Object.isFrozen(tide) && Object.isFrozen(tide.config)'), true);
  await h.call('event', 'activate', {});
  assert.equal((await h.call('event', 'ui.action', {values: {message: 'updated'}})).ui.text, 'updated');
  assert.equal((await h.call('event', 'ui.action', {values: {}})).active, true);
  await h.call('event', 'deactivate', {});
  assert.equal((await h.call('event', 'ui.action', {values: {}})).active, false);
});

test('failed RPC serialization releases pending capacity', async () => {
  const h = host();
  h.run("tide.registerTool('failures', async () => {let failures = 0; const x = {}; x.self = x; for (let i = 0; i < 70; i++) {try {await tide.storage.set('x', x)} catch (error) {if (/circular|cyclic/i.test(String(error))) failures++}} return failures}); tide.registerTool('read', () => tide.storage.get('ok'))");
  assert.equal(await h.call('tool', 'failures', {}), 70);
  const read = h.call('tool', 'read', {});
  await h.tick();
  assert.equal(h.requests.length, 1);
  h.context.__tideResolve(h.requests[0].id, 'alive', null);
  assert.equal(await read, 'alive');
});

test('large or cyclic results return errors without hanging callers', async () => {
  const h = host();
  h.run("tide.registerTool('large', () => 'x'.repeat(1048577)); tide.registerTool('cycle', () => {const x = {}; x.x = x; return x})");
  await assert.rejects(h.call('tool', 'large', {}), /exceeds/);
  await assert.rejects(h.call('tool', 'cycle', {}), /circular|cyclic/i);
});

test('storage update preserves expected snapshot and retries competing writes', async () => {
  const h = host();
  h.run("tide.registerTool('increment', () => tide.storage.update('counter', value => {value.count++; return value}))");
  const result = h.call('tool', 'increment', {});
  await h.tick();
  h.context.__tideResolve(h.requests[0].id, {count: 1}, null);
  await h.tick();
  assert.deepEqual(h.requests[1].args, {key: 'counter', expected: {count: 1}, value: {count: 2}});
  h.context.__tideResolve(h.requests[1].id, false, null);
  await h.tick();
  h.context.__tideResolve(h.requests[2].id, {count: 4}, null);
  await h.tick();
  assert.deepEqual(h.requests[3].args, {key: 'counter', expected: {count: 4}, value: {count: 5}});
  h.context.__tideResolve(h.requests[3].id, true, null);
  assert.deepEqual(await result, {count: 5});
});

test('chat capabilities bind concurrent invocations without exposing the token', async () => {
  const h = host();
  h.run(`tide.registerTool('reply', async (args, context) => {
    const info = await tide.chat.getContext(context);
    return context.chat.sendText({text: args.text, requestId: args.key, contextToken: 'forged'});
  })`);
  const first = h.call('tool', 'reply', {__tideInvocation:true,args:{text:'a',key:'a'},contextToken:'token-a'});
  const second = h.call('tool', 'reply', {__tideInvocation:true,args:{text:'b',key:'b'},contextToken:'token-b'});
  await h.tick();
  const contexts = h.requests.splice(0);
  assert.equal(contexts.length,2);
  for (const request of contexts) h.context.__tideResolve(request.id,{botId:request.args.contextToken},null);
  await h.tick();
  const sends = h.requests.splice(0);
  assert.deepEqual(sends.map(r=>[r.args.text,r.args.contextToken]),[['a','token-a'],['b','token-b']]);
  for (const request of sends) h.context.__tideResolve(request.id,{status:'sent',messageId:request.args.requestId},null);
  assert.equal((await first).messageId,'a');
  assert.equal((await second).messageId,'b');
});
test('legacy handler input remains intact and missing context rejects chat APIs', async () => {
  const h = host();
  h.run(`tide.registerTool('legacy', args => args); tide.registerTool('send', (args,ctx)=>ctx.chat.sendText({text:'x',requestId:'x'}))`);
  assert.deepEqual(await h.call('tool','legacy',{hello:'world'}),{hello:'world'});
  await assert.rejects(h.call('tool','send',{}),/requires a tool invocation/);
});
