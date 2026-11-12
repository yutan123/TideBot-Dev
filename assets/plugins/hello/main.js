// TideBot 示例插件 — tide.example.hello
// 仅作开发参考，不随应用功能发布。
// 展示：工具注册、配置读取、存储读写、生命周期、声明式 UI、Hook。

tide.on('activate', async () => {
  await tide.log('hello 插件已启动，greeting = ' + tide.config.greeting);
});

tide.on('deactivate', async () => {
  await tide.log('hello 插件已停止');
});

// 工具：用配置中的问候语拼一句话
tide.registerTool('greet', async ({ name }) => {
  const greeting = tide.config.greeting || 'Hello';
  const count = (await tide.storage.get('call_count') || 0) + 1;
  await tide.storage.set('call_count', count);
  return { message: `${greeting}, ${name}! (第 ${count} 次调用)` };
});

// 工具：读取本地存储
tide.registerTool('get_stats', async () => {
  const count = await tide.storage.get('call_count') || 0;
  return { call_count: count, greeting: tide.config.greeting };
});

// UI 动作处理：点击按钮后更新界面
tide.on('ui.action', async ({ action, values }) => {
  if (action === 'greet') {
    const name = values.name || '世界';
    const greeting = tide.config.greeting || 'Hello';
    const count = (await tide.storage.get('call_count') || 0) + 1;
    await tide.storage.set('call_count', count);
    return {
      ui: {
        type: 'column',
        children: [
          { type: 'text', style: 'title', text: 'Hello 插件' },
          { type: 'input', id: 'name', label: '你的名字', value: name },
          { type: 'button', label: '问候', action: 'greet' },
          { type: 'divider' },
          { type: 'text', text: `${greeting}, ${name}！（第 ${count} 次）` },
        ],
      },
    };
  }
});

// Hook 示例：在所有工具调用前记录日志（tool.before 需在 manifest 中声明）
tide.on('tool.before', async (payload) => {
  const name = payload?.call?.function?.name || '(unknown)';
  if (name.startsWith('tp_')) return; // 忽略插件自身工具，避免循环
  await tide.log('tool.before: ' + name);
  return payload; // 不修改，透传
});
