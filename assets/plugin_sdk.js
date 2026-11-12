// TideBot SDK v1. Bundled host infrastructure, not a business plugin.
(() => {
  'use strict';
  const tools = new Map(), events = new Map(), pending = new Map();
  let sequence = 0;
  const send = (channel, data) => sendMessage(channel, JSON.stringify(data));
  const rpc = (method, args = {}) => new Promise((resolve, reject) => {
    if (pending.size >= 64) return reject(new Error('Too many pending host calls'));
    const id = ++sequence;
    pending.set(id, {resolve, reject});
    try {
      send('tide.host', {id, method, args});
    } catch (error) {
      pending.delete(id);
      reject(error);
    }
  });
  globalThis.__tideResolve = (id, value, error) => {
    const callback = pending.get(id);
    if (!callback) return;
    pending.delete(id);
    error ? callback.reject(new Error(error)) : callback.resolve(value);
  };
  globalThis.tide = Object.freeze({
    apiVersion: 1,
    config: Object.freeze(globalThis.__tideConfig || {}),
    registerTool(name, handler) {
      if (typeof handler !== 'function' || tools.has(name)) throw new Error('Invalid/duplicate tool: ' + name);
      tools.set(name, handler);
    },
    on(event, handler) {
      if (typeof handler !== 'function') throw new Error('Event handler must be a function');
      if (!events.has(event)) events.set(event, []);
      events.get(event).push(handler);
    },
    storage: Object.freeze({
      get: key => rpc('storage.get', {key}),
      set: (key, value) => rpc('storage.set', {key, value}),
      delete: key => rpc('storage.delete', {key}),
      compareAndSet: (key, expected, value) => rpc('storage.compareAndSet', {key, expected, value}),
      async update(key, updater) {
        if (typeof updater !== 'function') throw new Error('Storage updater must be a function');
        for (let attempt = 0; attempt < 16; attempt++) {
          const expected = await rpc('storage.get', {key});
          const value = await updater(JSON.parse(JSON.stringify(expected)));
          if (value === undefined) throw new Error('Storage updater must return a JSON value');
          if (await rpc('storage.compareAndSet', {key, expected, value})) return value;
        }
        throw new Error('Storage update contention exceeded retry limit');
      },
    }),
    request: options => rpc('http.request', options),
    log: message => rpc('log', {message: String(message)}),
  });
  globalThis.__tideDispatch = (id, kind, name, payload) => {
    Promise.resolve().then(async () => {
      if (kind === 'validate') {
        for (const tool of payload) if (!tools.has(tool)) throw new Error('Unregistered tool: ' + tool);
        for (const tool of tools.keys()) if (!payload.includes(tool)) throw new Error('Undeclared tool: ' + tool);
        return null;
      }
      if (kind === 'tool') {
        const handler = tools.get(name);
        if (!handler) throw new Error('Tool not registered: ' + name);
        return await handler(payload);
      }
      let result = payload;
      for (const handler of events.get(name) || []) {
        const next = await handler(result);
        if (next !== undefined) result = next;
      }
      return result;
    }).then(value => {
      const data = {id, value: value === undefined ? null : value};
      if (JSON.stringify(data).length > 1048576) throw new Error('Plugin result exceeds 1 MB');
      send('tide.result', data);
    }).catch(error => send('tide.result', {id, error: String(error && error.stack || error)}));
  };
})();
