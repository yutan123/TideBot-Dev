// End-to-end integration test for the plugin service layer.
// Uses PluginTransport with a fake JS worker so no QuickJS or Flutter runtime
// is needed.  Covers: install → validate → enable → tool call → hook → UI
// action → save config → disable → update → delete.
//
// Run with: dart test/plugin_e2e_check.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:tide_bot/plugin_archive.dart';
import 'package:tide_bot/plugin_contract.dart';
import 'package:tide_bot/plugin_transport.dart';

// ---------------------------------------------------------------------------
// Fake JS worker that handles the same message protocol as _pluginWorker.
// ---------------------------------------------------------------------------
void _fakeWorker(List<dynamic> initial) {
  final parent = initial[0] as SendPort;
  final config = initial[3] as Map<String, dynamic>;
  final commands = ReceivePort();
  parent.send(commands.sendPort);

  final tools = <String>{};

  // Parse SDK inject to extract registered tools and hooks from the config.
  // We skip the actual JS and hard-code the protocol.

  parent.send({'type': 'ready'});

  commands.listen((dynamic message) {
    if (message is! Map) return;
    if (message['close'] == true) {
      commands.close();
      return;
    }
    if (message.containsKey('resolve')) {
      // No pending host calls in this fake worker.
      return;
    }
    final id = message['id'];
    final kind = message['kind'];
    final name = message['name'];
    final payload = message['payload'];

    if (kind == 'validate') {
      // payload is a List of tool names declared in manifest.
      final declared = List<String>.from(payload as List);
      for (final t in declared) {
        tools.add(t);
      }
      parent.send({
        'type': 'result',
        'data': {'id': id, 'value': null},
      });
      return;
    }
    if (kind == 'event') {
      if (name == 'activate' || name == 'deactivate' || name == 'app.ready') {
        parent.send({
          'type': 'result',
          'data': {'id': id, 'value': null},
        });
        return;
      }
      if (name == 'tool.before') {
        // Pass through without modification.
        parent.send({
          'type': 'result',
          'data': {'id': id, 'value': payload},
        });
        return;
      }
      if (name == 'tool.after') {
        // Return modified result.
        final modified = Map<String, dynamic>.from(payload as Map);
        modified['result'] = {
          ...Map<String, dynamic>.from(modified['result'] as Map),
          '_hooked': true,
        };
        parent.send({
          'type': 'result',
          'data': {'id': id, 'value': modified},
        });
        return;
      }
      if (name == 'ui.action') {
        final action = (payload as Map)['action'];
        parent.send({
          'type': 'result',
          'data': {
            'id': id,
            'value': {
              'ui': {'type': 'text', 'text': 'action=$action'},
            },
          },
        });
        return;
      }
      parent.send({
        'type': 'result',
        'data': {'id': id, 'value': null},
      });
      return;
    }
    if (kind == 'tool') {
      if (!tools.contains(name)) {
        parent.send({
          'type': 'result',
          'data': {'id': id, 'error': 'Tool not found: $name'},
        });
        return;
      }
      parent.send({
        'type': 'result',
        'data': {
          'id': id,
          'value': {'tool': name, 'config_greeting': config['greeting']},
        },
      });
      return;
    }
    parent.send({
      'type': 'result',
      'data': {'id': id, 'error': 'Unknown kind: $kind'},
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal in-process PluginSystem replacement.
// ---------------------------------------------------------------------------
class _FakeSystem {
  final _plugins = <String, Map<String, dynamic>>{};
  final _configs = <String, Map<String, dynamic>>{};

  List<Map<String, dynamic>> list() => _plugins.values.toList();

  Future<void> install(Map<String, dynamic> manifest) async {
    final id = manifest['id'] as String;
    _plugins[id] = {
      'id': id,
      'name': manifest['name'],
      'version': manifest['version'],
      'description': manifest['description'] ?? '',
      'author': manifest['author'] ?? '',
      'manifest_json': jsonEncode(manifest),
      'enabled': 0,
    };
  }

  Future<void> update(Map<String, dynamic> manifest) async {
    final id = manifest['id'] as String;
    if (!_plugins.containsKey(id)) throw StateError('Not installed');
    _plugins[id] = {
      ..._plugins[id]!,
      'version': manifest['version'],
      'manifest_json': jsonEncode(manifest),
    };
  }

  void setEnabled(String id, bool v) => _plugins[id]!['enabled'] = v ? 1 : 0;
  void delete(String id) {
    _plugins.remove(id);
    _configs.remove(id);
  }

  Map<String, dynamic> loadConfig(String id) => Map.of(_configs[id] ?? {});
  void saveConfig(String id, Map<String, dynamic> values) =>
      _configs[id] = values;
}

// ---------------------------------------------------------------------------
// Thin service that wires PluginTransport with _FakeSystem.
// ---------------------------------------------------------------------------
class _FakeService {
  final _sys = _FakeSystem();
  final _running = <String, PluginTransport>{};
  final _configs = <String, String>{};
  final errors = <String, String>{};
  Future<void> _queue = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() fn) {
    final next = _queue.then((_) => fn());
    _queue = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  Future<void> install(Map<String, dynamic> manifest) =>
      _exclusive(() => _sys.install(manifest));

  Future<void> setEnabled(String id, bool v) => _exclusive(() async {
    errors.remove(id);
    if (!v) {
      _sys.setEnabled(id, false);
      await _stop(id);
      return;
    }
    final row = _sys.list().firstWhere((r) => r['id'] == id);
    final manifest =
        jsonDecode(row['manifest_json'] as String) as Map<String, dynamic>;
    try {
      await _start(id, manifest);
      _sys.setEnabled(id, true);
    } catch (e) {
      await _stop(id);
      _sys.setEnabled(id, false);
      errors[id] = e.toString();
      rethrow;
    }
  });

  Future<Map<String, dynamic>> execute(String toolName) => _exclusive(() async {
    for (final row in _sys.list()) {
      final id = row['id'] as String;
      final m = jsonDecode(row['manifest_json'] as String) as Map;
      for (final t in m['tools'] as List? ?? []) {
        if ('tp_${id}_${t['name']}' == toolName || t['name'] == toolName) {
          final rt = _running[id];
          if (rt == null || rt.closed) {
            return {
              'result': {'ok': false, 'error': 'not running'},
            };
          }
          final v = await rt.call('tool', t['name'] as String, {});
          return {
            'result': {'ok': true, 'data': v},
          };
        }
      }
    }
    return {
      'result': {'ok': false, 'error': 'not found'},
    };
  });

  Future<Map<String, dynamic>> hook(
    String name,
    Map<String, dynamic> payload,
  ) async {
    var current = payload;
    for (final row in _sys.list()) {
      final id = row['id'] as String;
      final m = jsonDecode(row['manifest_json'] as String) as Map;
      if (!(m['hooks'] as List? ?? []).contains(name)) continue;
      final rt = _running[id];
      if (rt == null || rt.closed) continue;
      final result = await rt.call('event', name, current);
      if (result is Map) current = Map<String, dynamic>.from(result);
    }
    return current;
  }

  Future<dynamic> uiAction(
    String id,
    String action,
    Map<String, dynamic> values,
  ) async {
    final rt = _running[id];
    if (rt == null || rt.closed) throw StateError('not running');
    return rt.call('event', 'ui.action', {'action': action, 'values': values});
  }

  Future<void> saveConfig(String id, Map<String, dynamic> values) => _exclusive(
    () async {
      _sys.saveConfig(id, values);
      if (_running.containsKey(id)) {
        await _stop(id);
        final row = _sys.list().firstWhere((r) => r['id'] == id);
        final manifest =
            jsonDecode(row['manifest_json'] as String) as Map<String, dynamic>;
        await _start(id, manifest);
      }
    },
  );

  Future<void> updateVersion(String id, Map<String, dynamic> newManifest) =>
      _exclusive(() async {
        final wasRunning = _running.containsKey(id);
        await _stop(id);
        await _sys.update(newManifest);
        if (wasRunning) {
          await _start(id, newManifest);
          _sys.setEnabled(id, true);
        }
      });

  Future<void> delete(String id) => _exclusive(() async {
    _sys.setEnabled(id, false);
    await _stop(id);
    _sys.delete(id);
  });

  bool isRunning(String id) =>
      _running.containsKey(id) && !_running[id]!.closed;

  Future<void> _start(String id, Map<String, dynamic> manifest) async {
    if (_running.containsKey(id)) return;
    final config = _sys.loadConfig(id);
    final configSchema =
        manifest['config'] as Map? ?? {'type': 'object', 'properties': {}};
    final values = PluginContract.values(configSchema, config);
    late final PluginTransport rt;
    rt = PluginTransport(
      (method, args) async => null,
      workerEntry: _fakeWorker,
      onClosed: () {
        if (!identical(_running[id], rt)) return;
        _running.remove(id);
        errors[id] = 'crashed';
      },
    );
    try {
      await rt.start('', '', values);
      await rt.call(
        'validate',
        '',
        (manifest['tools'] as List? ?? []).map((t) => t['name']).toList(),
      );
      await rt.call('event', 'activate', {});
      _running[id] = rt;
      _configs[id] = jsonEncode(config);
      if ((manifest['hooks'] as List? ?? []).contains('app.ready')) {
        await rt.call('event', 'app.ready', {'apiVersion': 1});
      }
    } catch (_) {
      rt.close();
      _running.remove(id);
      rethrow;
    }
  }

  Future<void> _stop(String id) async {
    final rt = _running.remove(id);
    if (rt != null && !rt.closed) {
      try {
        await rt
            .call('event', 'deactivate', {})
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      rt.close();
    }
    _configs.remove(id);
  }
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------
Future<void> main() async {
  var checks = 0;
  void expect(bool cond, [String? msg]) {
    if (!cond)
      throw StateError(
        'Check ${checks + 1} failed${msg != null ? ": $msg" : ""}',
      );
    checks++;
  }

  // 1. Validate the hello.tideplugin produced by pack_plugin.py
  {
    final bytes = File('assets/plugins/hello.tideplugin').readAsBytesSync();
    final archive = PluginArchive.decode(bytes);
    expect(archive.manifest['id'] == 'tide.example.hello', 'archive id');
    expect((archive.manifest['tools'] as List).length == 2, 'tool count');
    expect(archive.files.containsKey('ui.json'), 'ui.json present');
  }

  // 2. Full service lifecycle with fake worker
  final svc = _FakeService();
  final manifest = {
    'apiVersion': 1,
    'id': 'test.e2e',
    'name': 'E2E Test',
    'version': '1.0.0',
    'entry': 'main.js',
    'config': {
      'type': 'object',
      'properties': {
        'greeting': {'type': 'string', 'default': 'Hi'},
      },
    },
    'tools': [
      {
        'name': 'greet',
        'description': 'greet',
        'parameters': {
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        },
      },
    ],
    'hooks': ['tool.before', 'tool.after'],
    'ui': {'entry': 'ui.json'},
  };

  await svc.install(manifest);
  expect(!svc.isRunning('test.e2e'), 'not running after install');

  await svc.setEnabled('test.e2e', true);
  expect(svc.isRunning('test.e2e'), 'running after enable');

  // Tool call
  final result = await svc.execute('greet');
  expect(result['result']['ok'] == true, 'tool ok');
  expect(result['result']['data']['tool'] == 'greet', 'tool name in result');
  expect(
    result['result']['data']['config_greeting'] == 'Hi',
    'default config in result',
  );

  // Hook: tool.after adds _hooked
  final hookResult = await svc.hook('tool.after', {
    'botId': 'bot1',
    'call': {
      'function': {'name': 'greet', 'arguments': '{}'},
    },
    'result': {'ok': true, 'data': {}},
  });
  expect(hookResult['result']['_hooked'] == true, 'tool.after hook applied');

  // UI action
  final uiResult = await svc.uiAction('test.e2e', 'submit', {'name': 'world'});
  expect(
    uiResult is Map && uiResult['ui'] != null,
    'ui action returned layout',
  );

  // Save config → plugin restarts with new config
  await svc.saveConfig('test.e2e', {'greeting': 'Hola'});
  expect(svc.isRunning('test.e2e'), 'still running after config save');
  final result2 = await svc.execute('greet');
  expect(
    result2['result']['data']['config_greeting'] == 'Hola',
    'new config applied',
  );

  // Update to v2 (keeps running)
  final v2 = Map<String, dynamic>.from(manifest);
  v2['version'] = '2.0.0';
  await svc.updateVersion('test.e2e', v2);
  expect(svc.isRunning('test.e2e'), 'running after update');
  final row = svc._sys.list().firstWhere((r) => r['id'] == 'test.e2e');
  expect(row['version'] == '2.0.0', 'version updated in DB');

  // Disable
  await svc.setEnabled('test.e2e', false);
  expect(!svc.isRunning('test.e2e'), 'stopped after disable');
  final r2 = await svc.execute('greet');
  expect(r2['result']['ok'] == false, 'tool unavailable when disabled');

  // Re-enable
  await svc.setEnabled('test.e2e', true);
  expect(svc.isRunning('test.e2e'), 'running after re-enable');

  // Delete
  await svc.delete('test.e2e');
  expect(!svc.isRunning('test.e2e'), 'stopped after delete');
  expect(svc._sys.list().isEmpty, 'removed from db');

  // 3. Contract: schema validation
  PluginContract.schema({
    'type': 'object',
    'properties': {
      'key': {'type': 'string', 'maxLength': 50},
      'count': {'type': 'integer', 'minimum': 0, 'maximum': 100},
    },
    'required': ['key'],
  });
  final validated = PluginContract.values({
    'type': 'object',
    'properties': {
      'key': {'type': 'string', 'default': 'x'},
    },
  }, {});
  expect(validated['key'] == 'x', 'default applied');
  expect(checks > 0, 'at least one check ran');

  // 4. Layout validation
  PluginContract.layout({
    'type': 'column',
    'children': [
      {'type': 'input', 'id': 'name', 'label': 'Name', 'value': ''},
      {'type': 'button', 'label': 'Go', 'action': 'go'},
    ],
  });
  checks++;

  print('Plugin e2e: $checks checks passed');
}
