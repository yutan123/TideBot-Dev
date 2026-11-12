import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_log_service.dart';
import 'plugin_contract.dart';
import 'plugin_coordinator.dart';
import 'plugin_runtime.dart';
import 'plugin_system.dart';

class PluginService {
  PluginService._() {
    PluginCoordinator.listen(_invalidateLocal);
  }
  final _epochs = <String, int>{};
  void _invalidateLocal(String id, int epoch) {
    if ((_epochs[id] ?? -1) >= epoch) return;
    _epochs[id] = epoch;
    _stopping.add(id);
    final runtime = _running.remove(id);
    runtime?.close();
    _packages.remove(id);
    _configSnapshots.remove(id);
    for (final client in _clients.remove(id) ?? <http.Client>{}) {
      client.close();
    }
    errors.remove(id);
  }

  static final instance = PluginService._();
  final _running = <String, PluginRuntime>{};
  final _packages = <String, TidePluginPackage>{};
  final _configSnapshots = <String, String>{};
  final errors = <String, String>{};
  Future<void> _queue = Future.value();
  static const _secure = FlutterSecureStorage();
  final _clients = <String, Set<http.Client>>{};
  final _stopping = <String>{};
  final _storageQueues = <String, Future<void>>{};

  Future<T> _exclusive<T>(Future<T> Function() work) {
    final next = _queue.then(
      (_) => PluginCoordinator.locked('lifecycle', work),
    );
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<void> initialize() => _exclusive(() async {
    final rows = await PluginSystem.instance.list();
    final enabled = rows.where((row) => row['enabled'] == 1).toList();
    final ids = enabled.map((row) => row['id']).toSet();
    for (final id in _running.keys.toList()) {
      if (!ids.contains(id)) await _stop(id);
    }
    for (final row in enabled) {
      final id = row['id'] as String;
      try {
        final epoch = await PluginCoordinator.epoch(id);
        if (_epochs[id] != epoch) _invalidateLocal(id, epoch);
        if (_running[id]?.closed == true) {
          errors[id] = '插件运行已停止，请关闭后重新启用';
          await _stop(id);
        }
        if (_running.containsKey(id)) {
          // Compare against the saved snapshot. Only stop if the plugin is
          // actually running (snapshot was set at startup) and config changed.
          final config = await PluginSystem.instance.loadConfig(id);
          final snap = _configSnapshots[id];
          if (snap != null && snap != jsonEncode(config)) {
            await _stop(id);
            errors.remove(id);
          }
        }
        if (!_running.containsKey(id) && !errors.containsKey(id)) {
          await _start(await PluginSystem.instance.packageFor(row));
        }
      } catch (error) {
        errors[id] = error.toString();
        _log(id, '启动或配置同步失败：$error');
      }
    }
  });

  Future<void> setEnabled(String id, bool enabled) => _exclusive(() async {
    errors.remove(id);
    if (!enabled) {
      await PluginSystem.instance.setEnabled(id, false);
      await _stop(id);
      return;
    }
    final row = (await PluginSystem.instance.list()).firstWhere(
      (row) => row['id'] == id,
    );
    try {
      await _start(await PluginSystem.instance.packageFor(row));
      await PluginSystem.instance.setEnabled(id, true);
    } catch (error) {
      await _stop(id);
      await PluginSystem.instance.setEnabled(id, false);
      errors[id] = error.toString();
      rethrow;
    }
  });

  Future<void> _start(TidePluginPackage pack) async {
    if (_running.containsKey(pack.id)) return;
    await _storageQueues.remove(pack.id);
    _stopping.remove(pack.id);
    _epochs[pack.id] = await PluginCoordinator.epoch(pack.id);
    final config = await PluginSystem.instance.loadConfig(pack.id);
    final values = PluginContract.values(
      pack.manifest['config'] as Map? ?? {'type': 'object', 'properties': {}},
      config,
    );
    late final PluginRuntime runtime;
    runtime = PluginRuntime(
      (method, args) => _host(pack, method, args),
      pluginId: pack.id,
      onClosed: () {
        if (!identical(_running[pack.id], runtime)) return;
        _stopping.add(pack.id);
        _running.remove(pack.id);
        _packages.remove(pack.id);
        _configSnapshots.remove(pack.id);
        for (final client in _clients.remove(pack.id) ?? <http.Client>{}) {
          client.close();
        }
        errors[pack.id] = '插件运行已停止，请关闭后重新启用';
        _log(pack.id, errors[pack.id]!);
      },
    );
    _packages[pack.id] = pack;
    try {
      final sdk = await rootBundle.loadString('assets/plugin_sdk.js');
      final source = await File(
        p.join(pack.directory.path, pack.entry),
      ).readAsString();
      await runtime.start(sdk, source, values);
      await runtime.call(
        'validate',
        '',
        (pack.manifest['tools'] as List? ?? [])
            .map((tool) => tool['name'])
            .toList(),
      );
      await runtime.call('event', 'activate', {});
      _running[pack.id] = runtime;
      _configSnapshots[pack.id] = jsonEncode(config);
      if ((pack.manifest['hooks'] as List? ?? []).contains('app.ready')) {
        await runtime.call('event', 'app.ready', {'apiVersion': 1});
      }
    } catch (_) {
      // Mark stopping so any in-flight host callbacks do not proceed, then
      // clean up. The id is removed from _stopping once the entry is gone so a
      // subsequent fresh start is not accidentally blocked.
      _stopping.add(pack.id);
      runtime.close();
      _running.remove(pack.id);
      _packages.remove(pack.id);
      _configSnapshots.remove(pack.id);
      for (final client in _clients.remove(pack.id) ?? <http.Client>{}) {
        client.close();
      }
      await _storageQueues.remove(pack.id);
      _stopping.remove(pack.id);
      rethrow;
    }
  }

  Future<void> _stop(String id) async {
    _stopping.add(id);
    final runtime = _running.remove(id);
    // Cancel network work before invoking teardown; a plugin may be awaiting it.
    for (final client in _clients.remove(id) ?? <http.Client>{}) {
      client.close();
    }
    if (runtime != null && !runtime.closed) {
      try {
        await runtime
            .call('event', 'deactivate', {})
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // Teardown is best effort; resources are always released below.
      } finally {
        runtime.close();
      }
    }
    await _storageQueues.remove(id);
    _packages.remove(id);
    _configSnapshots.remove(id);
  }

  Future<void> delete(String id) => _exclusive(() async {
    await PluginSystem.instance.setEnabled(id, false);
    await _stop(id);
    await PluginSystem.instance.delete(id);
    errors.remove(id);
  });

  /// Replaces the installed package files with a new ZIP while preserving
  /// private storage.  Stops the plugin first so the files are not in use,
  /// then re-enables it only if its persisted state was enabled.
  Future<void> updateZip(String id, String zipPath) => _exclusive(() async {
    final previous = (await PluginSystem.instance.list()).firstWhere(
      (row) => row['id'] == id,
    );
    final wasEnabled = previous['enabled'] == 1;
    await PluginCoordinator.invalidate(id);
    await _stop(id);
    errors.remove(id);
    try {
      await PluginSystem.instance.installZip(
        zipPath,
        update: true,
        expectedId: id,
      );
    } catch (error) {
      if (wasEnabled) {
        try {
          final recovered = (await PluginSystem.instance.list()).firstWhere(
            (row) => row['id'] == id,
          );
          await _start(await PluginSystem.instance.packageFor(recovered));
        } catch (restartError) {
          await PluginSystem.instance.setEnabled(id, false);
          errors[id] = '更新失败，旧版恢复失败：$restartError';
        }
      }
      rethrow;
    }
    if (wasEnabled) {
      final rows = await PluginSystem.instance.list();
      final row = rows.firstWhere((r) => r['id'] == id);
      try {
        await _start(await PluginSystem.instance.packageFor(row));
        await PluginSystem.instance.setEnabled(id, true);
      } catch (error) {
        errors[id] = error.toString();
        await PluginSystem.instance.setEnabled(id, false);
        rethrow;
      }
    }
  });

  Future<void> saveConfig(String id, Map<String, dynamic> input) => _exclusive(
    () async {
      final row = (await PluginSystem.instance.list()).firstWhere(
        (row) => row['id'] == id,
      );
      final pack = await PluginSystem.instance.packageFor(row);
      final values = PluginContract.values(
        pack.manifest['config'] as Map? ?? {'type': 'object', 'properties': {}},
        input,
      );
      await PluginSystem.instance.saveConfig(id, values);
      if (row['enabled'] == 1) {
        await _stop(id);
        errors.remove(id);
        try {
          await _start(pack);
        } catch (error) {
          errors[id] = error.toString();
          await PluginSystem.instance.setEnabled(id, false);
          rethrow;
        }
      }
    },
  );

  static String toolName(String id, String name) =>
      'tp_${sha256.convert(utf8.encode(id)).toString().substring(0, 16)}_$name';

  Future<List<Map<String, dynamic>>> schemas() async {
    await initialize();
    return [
      for (final pack in _packages.values)
        if (_running[pack.id]?.closed == false)
          for (final tool in pack.manifest['tools'] as List? ?? [])
            {
              'type': 'function',
              'function': {
                'name': toolName(pack.id, tool['name'] as String),
                'description': '${pack.name}: ${tool['description']}',
                'parameters': tool['parameters'],
              },
            },
    ];
  }

  Future<Map<String, dynamic>> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    await initialize();
    for (final pack in _packages.values.toList()) {
      for (final tool in pack.manifest['tools'] as List? ?? []) {
        if (toolName(pack.id, tool['name'] as String) != name) continue;
        final runtime = _running[pack.id];
        if (runtime == null || runtime.closed) break;
        try {
          final checked = PluginContract.values(
            tool['parameters'] as Map,
            args,
          );
          final value = await runtime.call(
            'tool',
            tool['name'] as String,
            checked,
          );
          await _assertCurrent(pack);
          return {
            'result': {'ok': true, 'data': value},
          };
        } catch (error) {
          return {
            'result': {'ok': false, 'error': error.toString()},
          };
        }
      }
    }
    return {
      'result': {'ok': false, 'error': '插件工具不存在或已停用'},
    };
  }

  /// A failing hook cannot prevent other plugins or the host from progressing.
  Future<Map<String, dynamic>> hook(
    String name,
    Map<String, dynamic> payload,
  ) async {
    await initialize();
    var current = payload;
    for (final pack in _packages.values.toList()) {
      if (!(pack.manifest['hooks'] as List? ?? []).contains(name)) continue;
      final runtime = _running[pack.id];
      if (runtime == null || runtime.closed) continue;
      try {
        final result = await runtime.call('event', name, current);
        await _assertCurrent(pack);
        if (result is Map) current = Map<String, dynamic>.from(result);
      } catch (error) {
        errors[pack.id] = 'Hook $name：$error';
        _log(pack.id, errors[pack.id]!);
      }
    }
    return current;
  }

  Future<dynamic> uiAction(
    String id,
    String action,
    Map<String, dynamic> values,
  ) async {
    await initialize();
    final runtime = _running[id];
    if (runtime == null || runtime.closed) throw StateError('请先启用插件');
    final pack = _packages[id]!;
    final result = await runtime.call('event', 'ui.action', {
      'action': action,
      'values': values,
    });
    await _assertCurrent(pack);
    return result;
  }

  void _log(String id, String message) =>
      AppLogService.instance.add('PLUGIN', '[$id] $message');

  Future<void> _assertCurrent(TidePluginPackage pack) async {
    final epoch = await PluginCoordinator.epoch(pack.id);
    if (_stopping.contains(pack.id) ||
        !identical(_packages[pack.id], pack) ||
        _epochs[pack.id] != epoch) {
      throw StateError('插件实例已失效');
    }
  }

  Future<dynamic> _host(
    TidePluginPackage pack,
    String method,
    Map<String, dynamic> args,
  ) async {
    if (_stopping.contains(pack.id) || !identical(_packages[pack.id], pack))
      throw StateError('插件已停止');
    await _assertCurrent(pack);
    final permissions = pack.manifest['permissions'] as List? ?? [];
    if (method == 'log') {
      _log(
        pack.id,
        args['message'].toString().substring(
          0,
          args['message'].toString().length.clamp(0, 2000),
        ),
      );
      return null;
    }
    if (method.startsWith('storage.')) {
      if (!permissions.contains('storage')) throw StateError('未声明 storage 权限');
      final key = args['key'];
      if (key is! String || key.isEmpty || key.length > 128)
        throw const FormatException('存储键无效');
      final previous = _storageQueues[pack.id] ?? Future<void>.value();
      final epoch = _epochs[pack.id];
      final operation = previous.then(
        (_) => PluginCoordinator.locked('storage:${pack.id}', () async {
          if (_stopping.contains(pack.id) ||
              !identical(_packages[pack.id], pack) ||
              epoch != await PluginCoordinator.epoch(pack.id)) {
            throw StateError('插件实例已失效');
          }
          final storageKey = 'plugin_data_${pack.id}';
          final raw = await _secure.read(key: storageKey);
          final data = raw == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(raw) as Map);
          if (method == 'storage.get') return data[key];
          if (method == 'storage.compareAndSet') {
            if (jsonEncode(data[key]) != jsonEncode(args['expected']))
              return false;
            data[key] = args['value'];
          } else if (method == 'storage.set') {
            data[key] = args['value'];
          } else if (method == 'storage.delete') {
            data.remove(key);
          } else {
            throw StateError('未知存储 API');
          }
          final encoded = jsonEncode(data);
          if (utf8.encode(encoded).length > 256 * 1024)
            throw StateError('插件存储超过 256 KB');
          await _secure.write(key: storageKey, value: encoded);
          return method == 'storage.compareAndSet' ? true : null;
        }),
      );
      _storageQueues[pack.id] = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      );
      return operation;
    }
    if (method == 'http.request') {
      if (!permissions.contains('network')) throw StateError('未声明 network 权限');
      final uri = Uri.parse(args['url'] as String);
      final origins = pack.manifest['networkOrigins'] as List? ?? [];
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          !origins.contains(uri.origin)) {
        throw StateError('请求地址不在声明的 HTTPS origin 中');
      }
      final verb = (args['method'] as String? ?? 'GET').toUpperCase();
      if (!{'GET', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(verb))
        throw StateError('HTTP 方法不支持');
      final request = http.Request(verb, uri)..followRedirects = false;
      if (args['headers'] is Map)
        request.headers.addAll(
          Map<String, String>.from(args['headers'] as Map),
        );
      request.body = args['body'] as String? ?? '';
      if (request.bodyBytes.length > 1024 * 1024)
        throw StateError('请求体超过 1 MB');
      final client = http.Client();
      _clients.putIfAbsent(pack.id, () => <http.Client>{}).add(client);
      try {
        return await (() async {
          final response = await client.send(request);
          final bytes = <int>[];
          await for (final chunk in response.stream) {
            bytes.addAll(chunk);
            if (bytes.length > 1024 * 1024) throw StateError('响应超过 1 MB');
          }
          return {
            'status': response.statusCode,
            'headers': response.headers,
            'body': utf8.decode(bytes, allowMalformed: true),
          };
        })().timeout(const Duration(seconds: 10));
      } finally {
        client.close();
        _clients[pack.id]?.remove(client);
      }
    }
    throw StateError('未知宿主 API：$method');
  }
}
