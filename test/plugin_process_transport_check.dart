import 'dart:async';
import 'dart:convert';
import 'package:tide_bot/plugin_process_transport.dart';

// Exercises the production session/RPC state machine with an injected IPC edge.
// Does not execute Kotlin, Binder, FlutterEngine or QuickJS.
class Bridge implements PluginProcessBridge {
  late void Function(String) receive;
  final messages = <Map<String, dynamic>>[];
  bool failOpen = false;
  bool autoReady = true;
  @override
  void setReceiver(void Function(String) receiver) => receive = receiver;
  @override
  Future<void> send(String method, String payload) async {
    final value = Map<String, dynamic>.from(jsonDecode(payload) as Map);
    messages.add({...value, 'methodName': method});
    if (method == 'open') {
      if (failOpen) throw StateError('bind failed');
      if (autoReady) event(value['token'] as String, {'type': 'ready'});
    }
  }

  void event(String token, Map<String, dynamic> value) =>
      receive(jsonEncode({...value, 'token': token}));
  List<Map<String, dynamic>> get opens =>
      messages.where((m) => m['methodName'] == 'open').toList();
  List<Map<String, dynamic>> get calls =>
      messages.where((m) => m['op'] == 'call').toList();
}

int checks = 0;
void check(bool value) {
  if (!value) throw StateError('Check ${checks + 1} failed');
  checks++;
}

Future<void> rejected(Future<dynamic> future) async {
  try {
    await future;
  } catch (_) {
    checks++;
    return;
  }
  throw StateError('Expected rejection');
}

Future<void> turn() => Future<void>.delayed(Duration.zero);

Future<void> main() async {
  final bridge = Bridge();
  var closed = 0;
  final a = PluginProcessTransport(
    (_, args) async {
      if (args['invalid'] == true) return Object();
      if (args['large'] == true) return 'x' * (1024 * 1024);
      return args;
    },
    bridge: bridge,
    onClosed: () => closed++,
  );
  final b = PluginProcessTransport((_, args) async => args, bridge: bridge);
  await a.start('sdk', 'script', {});
  await b.start('sdk', 'script', {});
  final ta = bridge.opens[0]['token'] as String;
  final tb = bridge.opens[1]['token'] as String;
  check(ta != tb && !a.closed && !b.closed);
  await rejected(a.start('', '', {}));
  final pending = List.generate(32, (i) => a.call('tool', 'echo', i));
  await rejected(a.call('tool', 'overflow', {}));
  for (final request in bridge.calls.reversed) {
    bridge.event(ta, {
      'type': 'result',
      'id': request['id'],
      'value': request['payload'],
    });
  }
  check(
    (await Future.wait(pending)).join(',') ==
        List.generate(32, (i) => i).join(','),
  );
  for (var i = 0; i < 40; i++) {
    await rejected(a.call('tool', 'bad', Object()));
  }
  check(!a.closed);
  for (final args in [
    {},
    {'invalid': true},
    {'large': true},
  ]) {
    bridge.event(ta, {
      'type': 'host',
      'id': 80 + args.length,
      'method': 'test',
      'args': args,
    });
    await turn();
    final reply = bridge.messages.lastWhere((m) => m['op'] == 'resolve');
    check(args.isEmpty ? reply['error'] == null : reply['error'] != null);
  }
  final dying = a.call('tool', 'waiting', {});
  final failure = rejected(dying);
  bridge.event(ta, {'type': 'fatal', 'error': 'native process exited'});
  await failure;
  check(a.closed && closed == 1 && !b.closed);
  a.close();
  check(closed == 1);
  final live = b.call('tool', 'alive', {});
  final request = bridge.calls.last;
  bridge.event(tb, {'type': 'result', 'id': request['id'], 'value': 'ok'});
  check(await live == 'ok');
  bridge.event(ta, {'type': 'ready'});
  check(a.closed);
  final toClose = b.call('tool', 'pending', {});
  final stopped = rejected(toClose);
  b.close();
  await stopped;
  await rejected(b.call('tool', 'closed', {}));
  final failingBridge = Bridge()..failOpen = true;
  final failing = PluginProcessTransport(
    (_, _) async => null,
    bridge: failingBridge,
  );
  await rejected(failing.start('', '', {}));
  check(failing.closed);
  final slowBridge = Bridge()..autoReady = false;
  final slow = PluginProcessTransport((_, _) async => null, bridge: slowBridge);
  final starting = rejected(slow.start('', '', {}));
  slow.close();
  await starting;
  check(slow.closed);
  await turn();
  print('Plugin process transport: $checks checks passed');
}
