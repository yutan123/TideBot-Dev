# TideBot 插件开发指南（SDK v1）

本文面向 TideBot 插件开发者，介绍运行架构、插件包格式、权限、JavaScript SDK 与开发流程。插件可通过「侧边栏 → 插件 → 导入」安装。

## 1. 架构与运行方式

| 层 | 实现 | 职责 |
| --- | --- | --- |
| 包管理 | `lib/plugin_system.dart`、`lib/plugin_archive.dart` | ZIP 校验、临时目录安装、数据库元信息、配置安全存储 |
| 生命周期与宿主 | `lib/plugin_service.dart` | 启停、配置重载、工具 schema/调用、Hook、权限和资源清理 |
| JavaScript | `lib/plugin_runtime.dart`、`lib/plugin_transport.dart` | Android 每个运行实例一个独立服务进程，进程内使用 Dart isolate 和独立 QuickJS-NG 引擎，通过受控 JSON IPC 通信 |
| SDK | `assets/plugin_sdk.js` | `tide` 全局对象、Promise RPC、工具/事件注册 |
| 消息与媒体 | `plugin_chat_session.dart`、`plugin_chat_host.dart`、`plugin_media_contract.dart` | 调用上下文、消息投递、媒体下载与资源管理 |
| UI | `lib/plugin_ui_page.dart` | 用 Flutter 组件渲染声明式 JSON，按钮事件进入插件运行时 |
| 配置 | `lib/plugin_config_dialog.dart`、`lib/plugin_contract.dart` | 类型化配置表单与共同校验规则 |
| 接入 | `lib/ai.dart`、`lib/main.dart` | 启动恢复、AI 工具注册/分发及工具调用前后 Hook |

运行时固定依赖 `quickjs_engine 0.1.7`，要求 Dart ≥3.8、Flutter ≥3.32。业务逻辑使用 QuickJS，网页界面按需使用系统 WebView。未启用的插件不创建 JavaScript isolate；每个启用插件会增加独立引擎的内存占用。

启动时恢复数据库中已启用的插件。启用操作会加载配置、执行入口、核对工具声明与注册、等待 `activate`，成功后才写入启用状态。关闭会撤下工具/Hook、取消网络请求、调用 `deactivate` 并释放运行时。保存配置时，已启用的插件会停止后使用新配置重启；重启失败时关闭插件。卸载会删除包文件、元信息、安全配置和私有存储。

后台 Dart isolate 拥有自己的服务实例，按工具请求惰性恢复启用插件；插件不能把进程内变量当成跨 isolate 或跨启动持久状态。持久化使用 `tide.storage`。Android 主应用进程中的前台/后台 Flutter 引擎通过原生协调器共享生命周期锁、存储锁和插件代次。停用、更新、卸载和保存配置会递增代次，广播撤下旧实例并终止对应插件服务进程；工具、Hook、UI 和宿主 API 拒绝旧代次的迟到请求与结果。运行时异常退出时撤下本地工具并关闭网络请求；引擎分离时释放其持有的锁并移除等待者。

## 2. 包结构

ZIP 根目录直接放这些文件，不能额外套一个顶级目录。扩展名支持 `.zip` 和 `.tideplugin`。

```text
manifest.json          必需：身份、版本、入口及能力声明
main.js                必需：manifest.entry 指向的 JavaScript 入口，文件名可改
config.schema.json     可选：未提供内联 manifest.config 时读取
icon.png               可选：manifest.icon 指向的本地图标
ui.json                可选：manifest.ui.entry 指向的 Flutter 声明式布局
其他模块与资源         可选：通过 modules/resources 声明；网页文件按相对 URL 加载
```

入口采用 JavaScript，使用全局 `tide`。支持普通脚本入口与 CommonJS 包内模块；多文件组织见第 11 节。TypeScript 和 npm 依赖需在开发环境编译或打包；宿主提供包内相对路径 `require`，不提供 Node 内置模块或运行时 npm 安装。不要依赖 DOM、浏览器 `window`、原生定时器、`fetch` 或 XHR；异步工作使用 SDK 的 Promise API。入口阶段同步注册工具和事件，异步初始化放入 `activate`。

## 3. manifest.json

以下清单展示可用字段，开发时仅声明实际需要的能力：

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

`entry/icon/ui.entry` 必须是包内安全相对路径且文件存在。入口必须以 `.js` 结尾、最大 2 MiB。`ui.entry` 按 ui.type 指向声明式 JSON 或 HTML；网页界面见第 12 节。

## 4. 配置和参数 Schema

SDK v1 实现的是明确限定的 JSON Schema 子集：根节点必须为 `type: object` 和 `properties`；字段支持 `string/boolean/integer/number`，支持 `default`、`enum`、`required`、数字 `minimum/maximum`、字符串 `maxLength`。不提供嵌套对象、数组、`$ref`、联合类型、正则或完整 JSON Schema 解释器。未知输入键会被拒绝，即使清单省略 `additionalProperties`。

设置表单中，字符串使用文本框，`format: password` 隐藏输入，布尔使用开关，数字使用数字输入，枚举使用下拉。保存保留 JSON 类型；插件启动及工具调用前重复校验，避免绕过界面的非法值。`required` 检查字段存在；若需要拒绝空字符串，应在插件逻辑中明确检查。默认值用于缺省字段，不会自动写入所有持久配置。

内联 `manifest.config` 优先于 `config.schema.json`。安装时将独立文件内容规范化进保存的清单。配置使用 Flutter Secure Storage，不向插件暴露其他插件的配置。`tide.config` 在每次启动时取得快照，修改设置后重启生效。

## 5. 宿主 JavaScript API

| API | 返回 | 行为 |
| --- | --- | --- |
| `tide.apiVersion` | `1` | SDK 版本 |
| `tide.config` | 对象 | 当前配置，顶层只读 |
| `tide.registerTool(name, handler)` | 无 | 注册清单声明的工具，handler 接收 (args, context)，可返回 Promise |
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

HTTP 不自动跟随重定向，不允许 URL 用户信息。请求体与响应分别最多 1 MB，整个请求最多 10 秒，结束/超时/插件关闭时释放客户端。非 2xx 状态也返回响应，由插件判断；地址越权、网络错误和资源超限以 Promise rejection 返回。媒体下载与聊天发送使用第 10 节的专用接口。SDK 不开放任意文件、Shell、Android Intent、应用数据库或原生平台通道访问。

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

Hook 在工具分发前后执行，适用于宿主工具与插件工具。异常 Hook 会写日志并保留其执行前的 payload，继续其他插件与宿主；超时或致命运行错误会停止对应运行时，需关闭后重新启用。

## 7. 声明式 Flutter UI

当 `ui.type` 为 `declarative`（默认）时，`ui.entry` 指向一个根组件 JSON 对象。管理卡片仅在清单提供 UI 时显示“打开界面”，打开独立全屏页面。声明式组件由 Flutter 渲染并继承宿主主题；网页渲染方式见第 12 节。

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

界面更新保留相同 ID 且类型兼容的现有表单值；移除的字段不再提交，同 ID 切换组件类型时使用新类型默认值。文本输入由独立 controller 管理，布局移动后仍保留编辑值。默认值用于首次出现的字段。操作期间禁用交互并显示等待状态。插件未启用时可查看静态布局，但执行按钮操作会提示先启用。组件类型与字段以本节定义为准。

## 8. 安装与资源约束

压缩包最大 256 MiB，累计解压声明大小最大 512 MiB，最多 10000 个条目（含目录）。安装在独立 Dart isolate 中逐条检查 ZIP 中央目录与本地条目，显式核对解压后长度及 CRC，并检查非法/越界路径、重复归一化路径、符号链接和文件目录冲突。仅支持未加密的 stored/deflate ZIP；解压写入受声明大小限制，超过上限即失败。清单和独立配置 Schema 各最多 1 MB。先写随机后缀的 `.installing-` 临时目录，完成后重命名并保存数据库；失败只清理本次创建的文件，卸载在文件与配置清理成功后删除数据库记录以便失败重试。安装请求通过跨引擎生命周期锁串行化。普通安装拒绝重复 ID；管理页“更新”校验包 ID，暂存新文件并备份旧目录，保留配置与私有数据。安装失败尝试恢复旧实例；新版启用失败会停用并报告错误。安装、更新和卸载使用写前事务日志：日志先 flush 并原子更名，再替换目录并提交数据库 marker；恢复时根据 marker 与 manifest 确认提交或回滚旧目录。卸载始终向前恢复，重复清理数据、配置、目录和数据库；任何清理失败均保留日志以供下次重试。每次生命周期事务开始前执行恢复。

每个引擎 JS heap 上限 32 MB，单次同步 JS 和微任务批次预算约 1 秒，一批最多 1000 个微任务，完整异步调用上限 15 秒，启动握手上限 8 秒，退出回调最多等待 2 秒。最多 32 个并发插件调用、64 个并发宿主 RPC。JSON 返回值不能包含循环引用、函数或原生对象；SDK 限制结果序列化长度为 1 MiB 字符。不要把这些阈值当成精确的整个进程内存限额。

Android 使用独立服务进程运行插件，每个实例包含一个 FlutterEngine 和 QuickJS 引擎；最多同时运行 8 个实例。实例启动、调用超时或绑定断开时，宿主关闭该实例。非 Android 平台使用进程内 isolate。32 MB 为 JS heap 上限，不包含 FlutterEngine 等原生内存。Android 插件进程与应用使用同一 UID，进程分离提供崩溃隔离。

## 9. 开发与调试

1. 定义唯一插件 ID，声明工具、权限、配置和实际需要的 Hook。
2. 用 JS 模块编写逻辑，或在开发环境编译 TypeScript 和第三方依赖。
3. 可选编写声明式 `ui.json` 或网页入口，以及独立 `config.schema.json`。
4. 从文件内容直接打 ZIP，确保 `manifest.json` 位于根目录。
5. 在插件页导入，先设置必要参数，再启用；缺配置或入口/注册错误会显示在卡片上。
6. 在实际宿主环境检查 AI 工具、设置重载、按钮事件、关闭和卸载的行为，日志查看 PLUGIN 分类。

在仓库根目录执行 SDK 与插件契约检查：

```sh
node --test test/plugin_sdk_test.cjs
dart test/plugin_package_files_check.dart
dart test/plugin_chat_session_check.dart
dart test/plugin_contract_check.dart
dart test/plugin_archive_check.dart
dart test/plugin_transport_check.dart
dart test/plugin_install_journal_check.dart
dart test/plugin_process_transport_check.dart
dart analyze lib/plugin_chat_session.dart lib/plugin_chat_host.dart lib/plugin_media_contract.dart lib/plugin_transport.dart lib/plugin_archive.dart lib/plugin_system.dart lib/plugin_runtime.dart lib/plugin_service.dart lib/plugin_contract.dart lib/plugin_manager_page.dart lib/plugin_config_dialog.dart lib/plugin_ui_page.dart
```

调试日志位于应用日志的 `PLUGIN` 分类。开发时检查工具注册、参数校验、异常处理、插件停用以及资源释放。涉及媒体消息的插件还应检查实际文件格式、消息显示与播放行为。

示例源码：

- `assets/plugins/hello/`：工具注册与声明式 UI。
- `assets/plugins/media_sender/`：文本、图片、视频与音频消息发送。

打包工具为 `tool/pack_plugin.py`。生成的包应将 `manifest.json` 放在压缩包根目录。

## 10. 会话与消息 SDK

消息接口使用工具处理函数的第二个参数 `context`。上下文由宿主绑定当前机器人会话，不接受插件指定其他机器人 ID。旧插件的单参数处理函数保持兼容。`activate`、Hook 和 UI 事件没有聊天发送上下文。

```js
tide.registerTool('reply', async (args, context) => {
  const conversation = await context.chat.getContext();
  const receipt = await context.chat.sendText({
    text: '你好',
    requestId: args.requestId
  });
  return receipt;
});
```

也可使用 `tide.chat.sendText(context, options)`，其他方法同样以 `context` 为第一个参数。推荐在处理函数内使用 `context.chat` 与 `context.media`。不要保存上下文供调用结束后使用；所有发送、下载操作都必须 `await`。上下文中的令牌由 SDK 管理，不作为工具参数或返回值暴露。

### 10.1 能力与权限

`apiVersion` 保持 1。`tide.capabilities` 是只读数组，包含 `chat.send`、`media.download`、`invocation.context`、`modules.commonjs`、`resources.read`、`ui.web`。使用新接口前可检查对应能力；旧宿主没有此字段时按不支持处理。

| 权限 | 用途 |
| --- | --- |
| `chat.send` | 发送消息、查询本插件发送状态 |
| `media.download` | 下载、引用和释放媒体 |
| `network` | 访问已声明的 HTTPS origin，媒体下载同样需要 |

发送远程媒体需要同时声明以上三项。发送纯文本只需要 `chat.send`。会话上下文不包含聊天历史、联系人或敏感配置，也不提供读取这些数据的权限。

### 10.2 接口

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `context.chat.getContext()` | 无 | `{botId, conversationId, pluginId}` |
| `context.chat.sendText(options)` | `{text, requestId}` | 消息回执 |
| `context.chat.sendImage(options)` | `{url 或 resourceId, caption?, requestId}` | 消息回执 |
| `context.chat.sendVideo(options)` | `{url 或 resourceId, caption?, duration?, requestId}` | 消息回执 |
| `context.chat.sendAudio(options)` | `{url 或 resourceId, caption?, duration?, requestId}` | 消息回执 |
| `context.chat.getStatus(requestId)` | 请求标识 | 消息回执或 `{status: "not_found"}` |
| `context.media.download(options)` | `{url, kind}`，kind 为 image/video/audio | `{resourceId, kind, size, extension}` |
| `context.media.release(resourceId)` | 资源标识 | 是否存在并释放 |

消息回执格式：

```json
{"messageId":"plugin_…","botId":"…","type":"image","status":"sent","duplicate":false,"timestamp":1700000000000}
```

`sent` 表示消息已持久化并进入应用聊天投递流程，不代表用户已读或音视频已播放。消息经过应用统一的聊天事件、后台消息同步及通知流程；通知仍遵循应用设置。不会触发新一轮机器人回复。

每次工具调用最多新增 10 条消息。文本最多 16000 字符且不能为空白；caption 最多 2000 字符；duration 为 0～86400 的整数秒，省略时为 0，不表示宿主已探测时长。音频接口发送已有音频文件，不执行文字转语音。视频与音频能否播放还取决于设备解码能力。

### 10.3 重试与状态

`requestId` 必填，非空白字符串，最多 128 字符。它在「插件 ID + 当前机器人会话」范围内唯一，消息 ID 由这三项派生。同一 requestId 重试会返回原消息，`duplicate: true`，不会覆盖内容或重复发送。使用新的 requestId 表示新增消息；不要为所有调用固定写同一个值。重试时应复用原值，即使插件重启或前后台引擎发生切换也适用。删除原消息后状态为 not_found，同一标识可重新发送。

发送出现超时或调用中断时，消息可能已经提交。重新调用工具后可先通过相同 requestId 查询状态再决定是否重试。查询仅返回本插件、当前会话中的匹配消息，不开放通用消息读取。

### 10.4 媒体下载与资源生命周期

支持直接提供 url，也可先下载，再传 resourceId。二者不能同时提供。resourceId 只在产生它的这次工具调用中有效，不可跨插件、跨调用或跨会话使用。资源返回值不包含本地文件路径。

所有媒体地址必须为 `networkOrigins` 中声明的精确 HTTPS origin；最多跟随 3 次重定向，每个跳转目标仍需在声明范围内。图片原站与搜索站是不同 origin，开发者必须为实际下载站点分别声明权限，不支持通配域名。普通 `tide.request` 仍不自动跟随重定向。

| 类型 | 单文件上限 | 接受的文件签名 |
| --- | --- | --- |
| image | 10 MiB | PNG、JPEG、GIF、WebP |
| video | 40 MiB | ISO BMFF（以 MP4 保存）、WebM |
| audio | 20 MiB | WAV、Ogg、FLAC、AMR、ISO BMFF（以 M4A 保存）、MP3/AAC 帧头 |

宿主使用流式下载并限制实际字节数，同时检查文件头，不仅依据扩展名或 Content-Type。文件头检查不是完整解码或内容审核。拒绝 HTML 等不匹配内容。媒体下载不经过 1 MiB 文本响应通道；单次下载超时 10 秒，仍受整个工具调用 15 秒预算约束。不要在一次调用里串行执行多个慢请求。

每次调用最多同时保留 4 个临时资源，可用 release 提前释放。发送时复制为聊天持久媒体，之后释放临时资源不会删除已经发送的文件。工具调用结束时关闭下载连接并清理该调用的临时资源；插件停用、更新或实例失效时取消未完成操作，提交前再次检查生命周期。异常退出遗留的缓存遵循系统临时目录清理规则。

### 10.5 完整示例

以下 manifest 注册一个媒体发送工具。示例域名应替换为实际媒体服务；requestId 应由调用方为每个逻辑消息生成并在重试时复用。

```json
{
  "apiVersion": 1,
  "id": "author.media_sender",
  "name": "媒体发送示例",
  "version": "1.0.0",
  "author": "author",
  "entry": "main.js",
  "permissions": ["chat.send", "media.download", "network"],
  "networkOrigins": ["https://cdn.example.com"],
  "tools": [{
    "name": "send_media",
    "description": "将指定类型的消息发送到当前会话；成功后不得重复发送同一内容。",
    "parameters": {
      "type": "object",
      "properties": {
        "kind": {"type":"string", "enum":["text","image","video","audio"]},
        "text": {"type":"string", "maxLength":16000},
        "url": {"type":"string", "maxLength":2048},
        "requestId": {"type":"string", "maxLength":128}
      },
      "required": ["kind","requestId"],
      "additionalProperties": false
    }
  }]
}
```

```js
tide.registerTool('send_media', async (args, context) => {
  const previous = await context.chat.getStatus(args.requestId);
  if (previous.status === 'sent') return previous;
  if (args.kind === 'text') {
    return await context.chat.sendText({text: args.text, requestId: args.requestId});
  }
  const resource = await context.media.download({url: args.url, kind: args.kind});
  try {
    const options = {resourceId: resource.resourceId, requestId: args.requestId};
    if (args.kind === 'image') return await context.chat.sendImage(options);
    if (args.kind === 'video') return await context.chat.sendVideo(options);
    return await context.chat.sendAudio(options);
  } finally {
    await context.media.release(resource.resourceId);
  }
});
```

可直接参考 `assets/plugins/media_sender/` 的清单与入口。发送异常会拒绝 Promise，应在工具中处理或交由宿主转换为工具错误；已经成功发送的消息不会因处理函数之后发生异常而回滚。

## 11. 多文件模块与包内资源

入口文件负责注册工具和事件，业务逻辑可通过 CommonJS 模块拆分，无需先合并成一个 bundle。目录名称由插件作者决定。

```text
my-plugin/
├── manifest.json
├── main.js
├── tools/
│   └── search.js
├── services/
│   └── provider.js
├── resources/
│   └── messages.json
└── web/
    ├── index.html
    ├── app.js
    └── style.css
```

### 11.1 清单声明

```json
{
  "apiVersion": 1,
  "id": "author.modular_example",
  "name": "模块化示例",
  "version": "1.0.0",
  "entry": "main.js",
  "entryFormat": "commonjs",
  "modules": ["tools/search.js", "services/provider.js"],
  "resources": ["resources/messages.json"],
  "ui": {"type": "web", "entry": "web/index.html"}
}
```

`entryFormat` 可选，默认 `script`，保留旧入口的脚本作用域；新项目建议使用 `commonjs`。`modules` 声明入口之外可加载的 `.js`、`.json` 模块，不自动扫描目录。每个模块最多 2 MiB，入口与模块累计最多 3 MiB，最多 255 个附加模块。网页脚本属于浏览器环境，不要放进 modules。

### 11.2 导入与导出

```js
// main.js
const { search } = require('./tools/search');
tide.registerTool('search', async (args, context) => search(args, context));
```

```js
// tools/search.js
const provider = require('../services/provider');
exports.search = async (args, context) => {
  const messages = await tide.resources.readJson('resources/messages.json');
  return provider.search(args.keyword, messages);
};
```

模块内可使用 `module.exports`、`exports` 和相对于当前模块的 `require()`。解析顺序为精确路径、`.js`、`.json`、`/index.js`。JSON 模块会解析成对象；需要通过 require 加载的 JSON 文件应声明在 modules 中。

同一运行实例中模块只求值一次，后续加载复用 exports。循环依赖返回尚未初始化完成的 exports，应避免让初始化依赖循环执行顺序。模块加载失败会清除该模块的缓存，异常传递给调用方。

只解析包内相对路径。Node 内置模块、裸 npm 包名以及运行时 ES Module import 不参与解析。采用 TypeScript、ES Module 或第三方库的项目，可用构建工具转换为 CommonJS 文件或单个 JS bundle 后打包。模块顶层同步注册工具，异步初始化放在 activate 中。

### 11.3 只读资源

| API | 返回 |
| --- | --- |
| `tide.resources.readText(path)` | Promise<string>，严格 UTF-8 解码 |
| `tide.resources.readJson(path)` | Promise<JSON>，读取并解析 JSON |

path 是相对插件包根目录的路径，必须在 manifest.resources 中声明。单次读取最多 1 MiB，读取过程检查实际路径和符号链接，拒绝越界。资源只读，不需要额外权限。运行期间产生的数据使用 tide.storage，插件更新不会保留包内文件修改。

resources 不会自动创建媒体 resourceId；它用于文本、词库、模板和 JSON。网页图片、字体和样式以相对 URL 从网页目录加载。

## 12. 网页界面

插件可以在声明式 Flutter UI 与网页 UI 中选择一种。省略 ui.type 时使用声明式布局；设置为 web 时使用应用内 WebView。简单配置和列表适合声明式 UI；自定义排版、图表和交互可使用 HTML、CSS、JavaScript。

### 12.1 页面入口与静态资源

```json
{
  "ui": {
    "type": "web",
    "entry": "web/index.html"
  }
}
```

HTML 入口最多 1 MiB。将 CSS、浏览器 JS、图片、字体放在入口所在目录或其子目录，通过相对 URL 引用；每个静态文件最多 4 MiB。支持 HTML、JS、CSS、JSON、PNG、JPEG、GIF、WebP、SVG、WOFF、WOFF2 和 TTF。

点击插件的打开界面按钮后，宿主绑定 127.0.0.1 的随机端口，创建带随机路径标识的临时静态站点，并在应用内打开入口。页面关闭后停止服务。开发者只需提供静态文件，不需要编写服务器、固定端口或启动命令。

页面运行在 WebView，业务工具运行在 QuickJS，两者的全局变量和模块系统相互独立。网页可使用浏览器 DOM 和计时器；业务脚本继续使用 tide SDK。可以采用前端框架构建的静态产物，构建时使用相对资源路径，并关闭依赖外部服务器的功能。页面路由可在当前文档内自行管理。

### 12.2 调用业务逻辑

宿主在页面脚本运行前注入 `window.tideUI`：

```js
const result = await window.tideUI.call('lookup', { keyword: 'hello' });
```

call 返回 Promise，映射到业务入口注册的 ui.action 事件：

```js
tide.on('ui.action', async ({ action, values }) => {
  if (action === 'lookup') {
    const messages = await tide.resources.readJson('resources/messages.json');
    return { text: messages[values.keyword] || '没有匹配结果' };
  }
  throw new Error('未知操作');
});
```

action 使用 `[a-zA-Z][a-zA-Z0-9_]{0,39}`，values 为 JSON 对象。请求与响应分别最多 64 Ki 字符，每页最多 8 个并发请求；页面等待响应最多 16 秒，业务调用仍受运行时 15 秒预算限制。错误拒绝 Promise，由页面捕获并展示。插件应处于启用状态；停用、更新或修改配置后旧页面失效，需要重新打开。

UI 事件没有聊天调用上下文，不能凭空选择机器人发送消息。涉及当前聊天的消息发送由机器人调用工具完成。

### 12.3 网页访问规则

网页只加载当前临时站点的静态资源。CSP 禁止外部网络连接、嵌入框架、表单提交和外部脚本；图片额外允许 data URL。链接导航只允许原入口，弹出页面不属于导航接口。需要联网时通过 tideUI.call 进入业务逻辑，再使用已声明 networkOrigins 的 tide.request。

网页不直接获得 tide.config、存储、宿主文件路径或聊天 SDK。通过 ui.action 返回页面实际需要的数据，避免将密钥作为页面数据返回。远程网站 URL 不能作为 ui.entry；入口始终是插件包内 HTML。

完整可运行示例位于 `assets/plugins/modular_web/`，包含模块、JSON 资源及独立 HTML/CSS/JS 文件。
