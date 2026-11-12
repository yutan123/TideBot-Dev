import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'plugin_runtime.dart' show pluginWorker;
import 'plugin_transport.dart';

/// Invoked only by PluginProcessService in a dedicated Android process.
@pragma('vm:entry-point')
Future<void> pluginProcessMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tidebot.plugin.worker');
  final hosts = <int, Completer<dynamic>>{};
  var sequence = 0;
  Future<void> emit(Map<String, dynamic> event) =>
      channel.invokeMethod<void>('event', jsonEncode(event));
  final runtime = PluginTransport(
    (method, args) async {
      if (hosts.length >= 64) throw StateError('插件宿主请求过多');
      final id = ++sequence;
      final pending = Completer<dynamic>();
      hosts[id] = pending;
      final response = pending.future.timeout(const Duration(seconds: 12));
      try {
        final values = await Future.wait<dynamic>([
          emit({'type': 'host', 'id': id, 'method': method, 'args': args}),
          response,
        ], eagerError: true);
        return values[1];
      } finally {
        hosts.remove(id);
      }
    },
    workerEntry: pluginWorker,
    onClosed: () {
      unawaited(emit({'type': 'fatal', 'error': '插件执行环境已退出'}));
    },
  );
  channel.setMethodCallHandler((call) async {
    if (call.method != 'command') return;
    final message = jsonDecode(call.arguments as String) as Map;
    if (message['op'] == 'resolve') {
      final pending = hosts.remove(message['id']);
      if (message['error'] != null) {
        pending?.completeError(StateError(message['error'].toString()));
      } else {
        pending?.complete(message['value']);
      }
    } else if (message['op'] == 'call') {
      try {
        final value = await runtime.call(
          message['kind'] as String,
          message['name'] as String,
          message['payload'],
        );
        await emit({'type': 'result', 'id': message['id'], 'value': value});
      } catch (error) {
        await emit({
          'type': 'result',
          'id': message['id'],
          'error': error.toString(),
        });
      }
    }
  });
  try {
    final boot =
        jsonDecode((await channel.invokeMethod<String>('boot'))!) as Map;
    await runtime.start(
      boot['sdk'] as String,
      boot['script'] as String,
      Map<String, dynamic>.from(boot['config'] as Map),
    );
    await emit({'type': 'ready'});
  } catch (error) {
    await emit({'type': 'fatal', 'error': error.toString()});
    runtime.close();
  }
}
