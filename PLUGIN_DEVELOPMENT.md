# TideBot 插件开发指南（SDK v1）

本文描述仓库中已接入的 Android 插件基础设施。插件市场暂未开放，安装入口为侧边栏 → 插件 → 右下角导入。本次没有附带业务插件，也没有扩展视频抽帧或分享链接解析。

## 1. 架构与运行方式

| 层 | 实现 | 职责 |
| --- | --- | --- |
| 包管理 | `lib/plugin_system.dart`、`lib/plugin_archive.dart` | ZIP 校验、临时目录安装、数据库元信息、配置安全存储 |
| 生命周期与宿主 | `lib/plugin_service.dart` | 启停、配置重载、工具 schema/调用、Hook、权限和资源清理 |
| JavaScript | `lib/plugin_runtime.dart`、`lib/plugin_transport.dart` | Android 每个运行实例一个独立服务进程，进程内使用 Dart isolate 和独立 QuickJS-NG 引擎，通过受控 JSON IPC 通信 |
| SDK | `assets/plugin_sdk.js` | `tide` 全局对象、Promise RPC、工具/事件注册 |
| UI | `lib/plugin_ui_page.dart` | 用 Flutter 组件渲染声明式 JSON，按钮事件进入插件运行时 |
| 配置 | `lib/plugin_config_dialog.dart`、`lib/plugin_contract.dart` | 类型化配置表单与共同校验规则 |
| 接入 | `lib/ai.dart`、`lib/main.dart` | 启动恢复、AI 工具注册/分发及工具调用前后 Hook |

运行时固定依赖 `quickjs_engine 0.1.7`，要求 Dart ≥3.8、Flutter ≥3.32。宿主没有引入 Node.js、Python、Linux 环境或插件专用 WebView。未启用的插件不创建 JavaScript isolate；每个启用插件会增加独立引擎的内存占用。

启动时恢复数据库中已启用的插件。启用操作会加载配置、执行入口、核对工具声明与注册、等待 `activate`，成功后才写入启用状态。关闭会撤下工具/Hook、取消网络请求、调用 `deactivate` 并释放运行时。保存配置时，已启用的插件会停止后使用新配置重启；重启失败时关闭插件。卸载会删除包文件、元信息、安全配置和私有存储。

后台 Dart isolate 拥有自己的服务实例，按工具请求惰性恢复启用插件；插件不能把进程内变量当成跨 isolate 或跨启动持久状态。持久化使用 `tide.storage`。Android 主应用进程中的前台/后台 Flutter 引擎通过原生协调器共享生命周期锁、存储锁和插件代次。停用、更新、卸载和保存配置会递增代次，广播撤下旧实例并终止对应插件服务进程；工具、Hook、UI 和宿主 API 拒绝旧代次的迟到请求与结果。运行时异常退出时撤下本地工具并关闭网络请求；引擎分离时释放其持有的锁并移除等待者。

## 2. 包结构

ZIP 根目录直接放这些文件，不能额外套一个顶级目录。扩展名支持 `.zip` 和 `.tideplugin`。

```text
manifest.json          必需：身份、版本、入口及能力声明
main.js                必需：manifest.entry 指向的 JavaScript bundle，文件名可改
config.schema.json     可选：未提供内联 manifest.config 时读取
icon.png               可选：manifest.icon 指向的本地图标
ui.json                可选：manifest.ui.entry 指向的 Flutter 声明式布局
其他构建资源           可选：会随包存储；不自动映射成文件访问 SDK
```

入口采用普通 JavaScript 脚本，使用全局 `tide`。TypeScript 或 npm 源码应由开发者在电脑上预先打成单个 JS bundle；宿主不提供 `require`、Node 内置模块、运行时 npm 安装或本地模块解析。不要依赖 DOM、浏览器 `window`、原生定时器、`fetch` 或 XHR；异步工作使用 SDK 的 Promise API。入口阶段同步注册工具和事件，异步初始化放入 `activate`。

## 3. manifest.json

下面是接口格式示意，不是随应用分发的业务插件：

```json
{
  "apiVersion": 1,
  "id": "author.package",
  "name": "插件名称",
  "version": "1.0.0",
  "description": "说明插件提供的功能",
  "author": "作者",
  "entry": "main.js",
  "icon": "icon.png",
  "permissions": ["storage", "network"],
  "networkOrigins": ["https://api.example.com"],
  "config": {
    "type": "object",
    "properties": {
      "apiKey": {"type": "string", "title": "API Key", "format": "password"},
      "enabledOption": {"type": "boolean", "default": false},
      "limit": {"type": "integer", "default": 3, "minimum": 1, "maximum": 10}
    },
    "required": ["apiKey"]
  },
  "tools": [
    {
      "name": "operation",
      "description": "工具用途及应调用的场景",
      "parameters": {
        "type": "object",
        "properties": {"input": {"type": "string"}},
        "required": ["input"],
        "additionalProperties": false
      }
    }
  ],
  "hooks": ["app.ready", "tool.before", "tool.after"],
  "ui": {"entry": "ui.json"}
}
```

必需字段为 `id/name/version/entry`。`id` 是 3～64 位，首字符为小写字母，之后仅小写字母、数字、下划线、点和连字符；名称最多 80 字符。版本接受三段数字及可选预发布/构建后缀，不能把其他文本接在三段版本后作为任意后缀。`apiVersion` 默认 1，其他版本拒绝安装。`icon`、`config`、`tools`、`hooks`、`permissions`、`networkOrigins`、`ui` 均可省略。

工具名须匹配 `[a-zA-Z][a-zA-Z0-9_]{0,39}`，同包内唯一，最多 32 个。AI 侧名称为 `tp_<插件ID的SHA256前16位>_<工具名>`，插件只用自己的原始工具名注册，无需计算宿主前缀。

`entry/icon/ui.entry` 必须是包内安全相对路径且文件存在。入口必须以 `.js` 结尾、最大 2 MB。`ui.entry` 必须为 JSON 布局，不再接受旧的静态 HTML 界面。

## 4. 配置和参数 Schema

SDK v1 实现的是明确限定的 JSON Schema 子集：根节点必须为 `type: object` 和 `properties`；字段支持 `string/boolean/integer/number`，支持 `default`、`enum`、`required`、数字 `minimum/maximum`、字符串 `maxLength`。不提供嵌套对象、数组、`$ref`、联合类型、正则或完整 JSON Schema 解释器。未知输入键会被拒绝，即使清单省略 `additionalProperties`。

设置表单中，字符串使用文本框，`format: password` 隐藏输入，布尔使用开关，数字使用数字输入，枚举使用下拉。保存保留 JSON 类型；插件启动及工具调用前重复校验，避免绕过界面的非法值。`required` 检查字段存在；若需要拒绝空字符串，应在插件逻辑中明确检查。默认值用于缺省字段，不会自动写入所有持久配置。

内联 `manifest.config` 优先于 `config.schema.json`。安装时将独立文件内容规范化进保存的清单。配置使用 Flutter Secure Storage，不向插件暴露其他插件的配置。`tide.config` 在每次启动时取得快照，修改设置后重启生效。

## 5. 宿主 JavaScript API

| API | 返回 | 行为 |
| --- | --- | --- |
| `tide.apiVersion` | `1` | SDK 版本 |
| `tide.config` | 对象 | 当前配置，顶层只读 |
| `tide.registerTool(name, handler)` | 无 | 注册清单声明的工具，handler 可返回 Promise |
| `tide.on(event, handler)` | 无 | 注册生命周期、Hook 或 UI 事件，允许同事件多个 handler |
| `tide.storage.get(key)` | Promise\<JSON 或 null\> | 读取本插件私有键 |
| `tide.storage.set(key, value)` | Promise\<null\> | 写入 JSON 值 |
| `tide.storage.compareAndSet(key, expected, value)` | Promise<boolean> | 原子比较并写入 |
| `tide.storage.update(key, updater)` | Promise<JSON> | 自动重试的原子读改写 |
| `tide.storage.delete(key)` | Promise\<null\> | 删除键 |
| `tide.request(options)` | Promise\<响应对象\> | 受权限和 origin 限制的 HTTPS 请求 |
| `tide.log(message)` | Promise\<null\> | 写入带插件 ID 的 PLUGIN 应用日志，单条截到 2000 字符 |

工具注册形式：

```js
tide.registerTool('operation', async (args) => {
  // args 已按 manifest 中的 parameters 校验。
  // 在这里实现插件自己的操作，返回可 JSON 序列化的数据。
  return {value: args.input};
});
```

工具声明与运行时注册必须一致。重复注册、漏注册或注册未声明的工具会导致启用失败。工具成功时宿主返回 `{"result":{"ok":true,"data":返回值}}`；异常转换成 `{"result":{"ok":false,"error":"..."}}`，不会把 JavaScript 异常直接抛进 AI 工具循环。

私有存储要求 `permissions` 包含 `storage`，每个插件最多 256 KB，键长 1～128。数据整体以 Secure Storage 保存；Android 前台/后台宿主通过原生共享锁串行化同一插件的读写。`await tide.storage.compareAndSet(key, expected, value)` 原子比较 JSON 值并写入，返回是否成功；缺失键按 null 比较。`await tide.storage.update(key, updater)` 基于独立旧值副本计算新值，竞争失败后重新读取并重试，最多 16 次；updater 可能执行多次，应避免外部副作用。普通 get 后 set 仍是两个操作，读改写应使用 update。它适合少量配置状态，不适合大量文件或媒体。

网络要求 `permissions` 包含 `network`，并在 `networkOrigins` 声明精确 HTTPS origin（不带路径或尾斜线）。请求格式：

```js
const response = await tide.request({
  url: 'https://api.example.com/v1/resource',
  method: 'POST', // 默认 GET；另支持 PUT/PATCH/DELETE
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({key: 'value'}) // 字符串，默认空
});
// response = {status: 200, headers: {...}, body: "响应正文"}
```

HTTP 不自动跟随重定向，不允许 URL 用户信息。请求体与响应分别最多 1 MB，整个请求最多 10 秒，结束/超时/插件关闭时释放客户端。非 2xx 状态也返回响应，由插件判断；地址越权、网络错误和资源超限以 Promise rejection 返回。没有任意文件、Shell、Android Intent、应用数据库或原生平台通道访问 API。

## 6. 生命周期与流程 Hook

`activate`、`deactivate` 和 `ui.action` 不需要加入 `manifest.hooks`。`app.ready/tool.before/tool.after` 必须声明后宿主才会分发。同一事件的 handler 按注册顺序运行；返回 `undefined` 保留前一个 payload，返回其他值替换 payload。多个插件按宿主查询顺序执行（最近更新优先），不要依赖其他插件存在。

```js
tide.on('activate', async () => {
  // 可等待必要的初始化；不要启动无限循环。
});
tide.on('deactivate', async () => {
  // 尽快清理插件自己的逻辑状态；关闭阶段不再接受新的宿主请求。
});
```

| 事件 | 输入 | 可返回的效果 |
| --- | --- | --- |
| `app.ready` | `{apiVersion: 1}` | 本插件启动完成通知，无返回控制效果 |
| `tool.before` | `{botId, call}` | 返回完整 payload 可改 `call`；`handled: true` 且 `result` 为对象时接管该次工具调用 |
| `tool.after` | `{botId, call, result}` | 返回带 `result` 的 payload 可替换宿主结果 |
| `ui.action` | `{action, values}` | 返回 `{ui: 布局对象}` 可刷新当前插件页面 |

`call` 使用 AI function-call 结构：`{id?, function: {name, arguments}}`，`arguments` 通常为 JSON 字符串。接管结果遵循宿主格式 `{result: {ok: true, ...}}`。修改前返回完整 payload，例如 `return {...payload, call: updatedCall}`；仅返回局部对象会丢失原字段。after 的 `call` 是最初进入宿主的调用。

Hook 覆盖当前 `ai.dart` 的原生工具分发入口，包括插件工具。它没有接入媒体预处理、视频抽帧、分享链接解析，也没有提供“替换应用任意方法”的能力。异常 Hook 会写日志并保留其执行前的 payload，继续其他插件与宿主；超时或致命运行错误会停止对应运行时，需关闭后重新启用。

## 7. 声明式 Flutter UI

`ui.entry` 指向一个根组件 JSON 对象。管理卡片仅在清单提供 UI 时显示“打开界面”，打开独立全屏页面。页面继承宿主主题，组件由 Flutter 渲染，不执行 HTML/DOM/WebView 代码。

| type | 字段 | 用途 |
| --- | --- | --- |
| `text` | `text`、可选 `style: title` | 文本或标题 |
| `column` | `children: []` | 垂直排列 |
| `row` | `children: []` | 等宽水平排列 |
| `card` | `children: []` | 宿主卡片 |
| `divider` | 无 | 分隔线 |
| `input` | 唯一 `id`、`label`、可选字符串 `value`、`secret: true` | 文本输入 |
| `toggle` | 唯一 `id`、`label`、可选布尔 `value` | 开关 |
| `button` | `label`、`action` | 调用 `ui.action` |

`id/action` 使用工具名同样的字符规则。最多 300 个节点、16 层嵌套、UI 文件最大 1 MB。所有表单组件 ID 在整棵树内必须唯一。初始布局格式：

```json
{
  "type": "column",
  "children": [
    {"type": "text", "style": "title", "text": "界面标题"},
    {"type": "input", "id": "content", "label": "内容", "value": ""},
    {"type": "button", "label": "执行", "action": "submit"}
  ]
}
```

点击按钮时，宿主发送全部当前表单值。插件可通过下列事件返回新布局：

```js
tide.on('ui.action', async ({action, values}) => {
  if (action !== 'submit') return;
  return {ui: {type: 'text', text: String(values.content || '')}};
});
```

界面更新保留相同 ID 且类型兼容的现有表单值；移除的字段不再提交，同 ID 切换组件类型时使用新类型默认值。文本输入由独立 controller 管理，布局移动后仍保留编辑值。默认值用于首次出现的字段。操作期间禁用交互并显示等待状态。插件未启用时可查看静态布局，但执行按钮操作会提示先启用。没有任意 Dart Widget 注入、自定义原生代码、路由劫持或页面外 UI 注入。

## 8. 安装与资源约束

压缩包最大 50 MB，累计解压声明大小最大 100 MB，最多 2000 个条目（含目录）。安装在独立 Dart isolate 中逐条检查 ZIP 中央目录与本地条目，显式核对解压后长度及 CRC，并检查非法/越界路径、重复归一化路径、符号链接和文件目录冲突。仅支持未加密的 stored/deflate ZIP；解压写入受声明大小限制，超过上限即失败。清单和独立配置 Schema 各最多 1 MB。先写随机后缀的 `.installing-` 临时目录，完成后重命名并保存数据库；失败只清理本次创建的文件，卸载在文件与配置清理成功后删除数据库记录以便失败重试。安装请求通过跨引擎生命周期锁串行化。普通安装拒绝重复 ID；管理页“更新”校验包 ID，暂存新文件并备份旧目录，保留配置与私有数据。安装失败尝试恢复旧实例；新版启用失败会停用并报告错误。安装、更新和卸载使用写前事务日志：日志先 flush 并原子更名，再替换目录并提交数据库 marker；恢复时根据 marker 与 manifest 确认提交或回滚旧目录。卸载始终向前恢复，重复清理数据、配置、目录和数据库；任何清理失败均保留日志以供下次重试。每次生命周期事务开始前执行恢复。

每个引擎 JS heap 上限 32 MB，单次同步 JS 和微任务批次预算约 1 秒，一批最多 1000 个微任务，完整异步调用上限 15 秒，启动握手上限 8 秒，退出回调最多等待 2 秒。最多 32 个并发插件调用、64 个并发宿主 RPC。JSON 返回值不能包含循环引用、函数或原生对象；SDK 限制结果序列化长度为 1 MiB 字符。不要把这些阈值当成精确的整个进程内存限额。

固定版本的引擎 C++ 桥接没有实现 Dart 构造函数的 `timeout` 参数。因此宿主直接安装导出的 `JS_SetInterruptHandler`，用单调时钟检查预算，并自己限制微任务执行，避免依赖无效的超时参数。运行时适配器使用该固定包的 FFI runtime registry；升级引擎必须重新检查这些接口及 Android ABI。Android 运行入口改为本地 tide_plugin_process 插件分配的独立服务进程，最多同时 8 个运行实例（包含不同宿主引擎的实例）。绑定断开、启动或调用超时会关闭该实例；原生进程退出通过 Binder 通知宿主。服务不自动注册宿主平台插件。IPC 通过匿名管道传输 JSON，Binder 仅传文件描述符，单条消息限制 8 Mi 字符。进程使用应用同一 UID，属于崩溃隔离，不是抵御原生漏洞的独立 UID 安全边界。非 Android 平台仍使用进程内 isolate。每个进程还包含 FlutterEngine，32 MB 仅为 JS heap 限额；总内存尚未测量。

安装校验与运行限额减少常见错误，但 ZIP 解码仍由 archive 库在内存中处理；真实 ZIP 检查覆盖 CRC 错误、重复路径、符号链接、截断与虚报解压大小等输入；这不等价于完整压力验证，也不能宣称可抵御所有资源耗尽输入。

## 9. 开发流程与验证边界

1. 定义唯一插件 ID，声明工具、权限、配置和实际需要的 Hook。
2. 用 JS 编写逻辑，或在开发者环境将 TypeScript/依赖预打包；对照 SDK v1 API，不使用未提供的平台能力。
3. 可选编写声明式 `ui.json` 和独立 `config.schema.json`。
4. 从文件内容直接打 ZIP，确保 `manifest.json` 位于根目录。
5. 在插件页导入，先设置必要参数，再启用；缺配置或入口/注册错误会显示在卡片上。
6. 在实际宿主环境检查 AI 工具、设置重载、按钮事件、关闭和卸载的行为，日志查看 PLUGIN 分类。

仓库提供不构建 Flutter 应用的检查：

```sh
node --test test/plugin_sdk_test.cjs
dart test/plugin_contract_check.dart
dart test/plugin_archive_check.dart
dart test/plugin_transport_check.dart
dart test/plugin_install_journal_check.dart
flutter analyze --no-pub lib/plugin_transport.dart lib/plugin_archive.dart lib/plugin_system.dart lib/plugin_runtime.dart lib/plugin_service.dart lib/plugin_contract.dart lib/plugin_manager_page.dart lib/plugin_config_dialog.dart lib/plugin_ui_page.dart
```

这些检查覆盖 SDK 工具/事件/RPC 契约、配置/UI 状态校验、真实 ZIP 包解析（含 isolate 结果传递）和真实 Dart isolate 传输生命周期。传输检查使用替代 worker，覆盖启动异常/提前退出、并发调用、宿主 RPC 拒绝、不可发送数据后的容量回收、关闭时拒绝未完成调用、意外退出及实际 15 秒超时；不加载 QuickJS，不等价于 Android 原生 QuickJS 桥接或真机验证。本轮按工作区限制未构建 APK、未在本机编译原生引擎、未运行真机，也未测量最终安装体积及运行内存；此前约 5 MB 的目标仅是预算，不是实测结论。数据库迁移、ZIP 压力输入、跨宿主 isolate 并发和原生引擎生命周期仍需在允许的目标环境补充端到端验证。

插件市场、在线更新、签名分发、跨 AstrBot/Harness/Operit 包格式兼容、完整 npm/Node API、任意应用流程 Hook 和任意原生 UI 均不属于 SDK v1 当前能力。扩展新能力时，应先在宿主定义稳定的版本化契约，再实现与测试，最后同步本文。

进程传输检查：`dart test/plugin_process_transport_check.dart`。它执行生产 Dart 会话状态机并注入 IPC 边界，覆盖并发、路由、关闭、失败与返回值校验；不执行 Kotlin、Binder、FlutterEngine 或 QuickJS，不能视作原生集成验证。
