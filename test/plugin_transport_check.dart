import 'dart:async';
import 'dart:isolate';

import 'package:tide_bot/plugin_transport.dart';

void worker(List<dynamic> initial) {
  final parent = initial[0] as SendPort;
  if (initial[2] == 'crash') throw StateError('startup crash');
  if (initial[2] == 'exit') return;
  final commands = ReceivePort();
  parent.send(commands.sendPort);
  parent.send({'type': 'ready'});
  commands.listen((dynamic message) {
    if (message['close'] == true) {
      commands.close();
    } else if (message.containsKey('resolve')) {
      parent.send({
        'type': 'result',
        'data': {
          'id': message['resolve'],
          'value': message['value'],
          'error': message['error'],
        },
      });
    } else if (message['name'] == 'exit') {
      commands.close();
    } else if (message['name'] == 'wait') {
      // Keep the port alive without answering, like an unfinished async task.
    } else if (message['name'] == 'host') {
      parent.send({
        'type': 'host',
        'data': {
          'id': message['id'],
          'method': 'echo',
          'args': message['payload'],
        },
      });
    } else {
      parent.send({
        'type': 'result',
        'data': {'id': message['id'], 'value': message['payload']},
      });
    }
  });
}

Future<void> rejected(Future<dynamic> future, String text) async {
  try {
    await future;
  } catch (error) {
    if (!error.toString().contains(text)) rethrow;
    return;
  }
  throw StateError('Expected rejection containing $text');
}

Future<void> main() async {
  var checks = 0;
  void expect(bool condition) {
    if (!condition) throw StateError('Check ${checks + 1} failed');
    checks++;
  }

  for (final scenario in ['crash', 'exit']) {
    var closed = 0;
    final runtime = PluginTransport(
      (_, args) async => args,
      workerEntry: worker,
      onClosed: () => closed++,
    );
    await rejected(runtime.start('', scenario, {}), '插件运行环境');
    expect(runtime.closed && closed == 1);
    runtime.close();
    expect(closed == 1);
  }

  var closed = 0;
  final runtime = PluginTransport(
    (_, args) async {
      if (args['fail'] == true) throw StateError('host rejected');
      if (args['invalid'] == true) return Object();
      if (args['large'] == true) return 'x' * (1024 * 1024);
      return args;
    },
    workerEntry: worker,
    onClosed: () => closed++,
  );
  await runtime.start('', '', {});
  final results = await Future.wait([
    for (var i = 0; i < 16; i++) runtime.call('tool', 'echo', i),
  ]);
  expect(
    results.length == 16 &&
        results.every((value) => value == results.indexOf(value)),
  );
  final host = await runtime.call('tool', 'host', {'value': 42});
  expect(host['value'] == 42);
  await rejected(runtime.call('tool', 'host', {'fail': true}), 'host rejected');
  expect(!runtime.closed);

  await rejected(
    runtime.call('tool', 'host', {'invalid': true}),
    'Converting object',
  );
  await rejected(runtime.call('tool', 'host', {'large': true}), '宿主响应超过');
  expect((await runtime.call('tool', 'host', {'value': 7}))['value'] == 7);

  final healthy = PluginTransport((_, args) async => args, workerEntry: worker);
  await healthy.start('', '', {});
  final broken = PluginTransport((_, args) async => args, workerEntry: worker);
  await broken.start('', '', {});
  await rejected(broken.call('tool', 'exit', null), '意外退出');
  expect(broken.closed && !healthy.closed);
  expect(await healthy.call('tool', 'echo', 'still alive') == 'still alive');
  healthy.close();

  // An unsendable payload must not consume one of the 32 pending slots.
  final unsendable = ReceivePort();
  for (var i = 0; i < 40; i++) {
    await rejected(runtime.call('tool', 'echo', unsendable), 'unsendable');
  }
  unsendable.close();
  expect(await runtime.call('tool', 'echo', 42) == 42);

  final pending = [
    for (var i = 0; i < 32; i++)
      rejected(runtime.call('tool', 'wait', null), '插件已停止'),
  ];
  await rejected(runtime.call('tool', 'echo', null), '插件调用过多');
  expect(!runtime.closed);
  runtime.close();
  await Future.wait(pending);
  expect(runtime.closed && closed == 1);
  await rejected(runtime.call('tool', 'echo', null), '插件未运行');
  runtime.close();
  expect(closed == 1);

  final exiting = PluginTransport((_, args) async => args, workerEntry: worker);
  await exiting.start('', '', {});
  await rejected(exiting.call('tool', 'exit', null), '意外退出');
  expect(exiting.closed);

  // Exercise timeout cleanup with a real unresponsive isolate and a short test budget.
  final timeout = PluginTransport(
    (_, args) async => args,
    workerEntry: worker,
    callTimeout: const Duration(milliseconds: 100),
  );
  await timeout.start('', '', {});
  try {
    await timeout.call('tool', 'wait', null);
    throw StateError('Expected timeout');
  } on TimeoutException {
    expect(timeout.closed);
  }
  print('Plugin transport: $checks checks passed');
}
