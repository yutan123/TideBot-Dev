import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_bot/plugin_chat_session.dart';
import 'package:tide_bot/plugin_media_contract.dart';

int checks = 0;
void check(bool value, String label) {
  if (!value) throw StateError(label);
  checks++;
}

Future<void> rejects(Future<dynamic> Function() work, String label) async {
  try {
    await work();
  } catch (_) {
    checks++;
    return;
  }
  throw StateError('Expected rejection: $label');
}

class Host implements PluginChatHost {
  Host(this.root);
  final Directory root;
  final rows = <String, Map<String, dynamic>>{};
  final queues = <String, Future<void>>{};
  Future<http.Response> Function(http.Request) respond = (_) async =>
      http.Response.bytes([137, 80, 78, 71, 13, 10, 26, 10, 0], 200);
  bool botExists = true, failInsert = false, failAfterInsert = false;
  int inserts = 0;
  @override
  Future<bool> hasBot(String id) async => botExists;
  @override
  Future<Map<String, dynamic>?> findMessage(String id, String botId) async {
    final row = rows[id];
    return row?['bot_id'] == botId ? row : null;
  }

  @override
  Future<void> insert(Map<String, dynamic> row) async {
    if (failInsert) throw StateError('db unavailable');
    inserts++;
    rows[row['id'] as String] = Map.from(row);
    if (failAfterInsert) throw StateError('notification failed');
  }

  @override
  Future<Directory> documents() async => root;
  @override
  Future<Directory> temporary() async => root;
  @override
  http.Client createClient() => MockClient((r) => respond(r));
  @override
  Future<T> locked<T>(String key, Future<T> Function() work) async {
    final previous = queues[key] ?? Future<void>.value();
    final done = Completer<void>();
    queues[key] = done.future;
    await previous;
    try {
      return await work();
    } finally {
      done.complete();
    }
  }
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('tide-chat-test-');
  final host = Host(root);
  bool current = true;
  PluginChatSession session({
    String bot = 'a',
    String plugin = 'author.plugin',
    Duration timeout = const Duration(seconds: 10),
  }) => PluginChatSession(
    pluginId: plugin,
    botId: bot,
    host: host,
    downloadTimeout: timeout,
    assertCurrent: () async {
      if (!current) throw StateError('stale');
    },
  );
  const all = ['chat.send', 'media.download', 'network'];
  const origins = ['https://cdn.example.com'];
  final sessions = <PluginChatSession>[];
  PluginChatSession make({
    String bot = 'a',
    String plugin = 'author.plugin',
    Duration timeout = const Duration(seconds: 10),
  }) {
    final s = session(bot: bot, plugin: plugin, timeout: timeout);
    sessions.add(s);
    return s;
  }

  Future<dynamic> call(
    PluginChatSession s,
    String m,
    Map<String, dynamic> a, {
    List permissions = all,
  }) => s.call(m, a, permissions, origins);
  try {
    final a = make(), b = make(bot: 'b'), same = make();
    check(
      (await call(a, 'chat.context', {}))['botId'] == 'a',
      'context binding',
    );
    await rejects(
      () => call(a, 'chat.sendText', {
        'text': 'hi',
        'requestId': 'denied',
      }, permissions: []),
      'permission',
    );
    await rejects(
      () => call(a, 'chat.sendText', {'text': 'hi'}),
      'request id required',
    );
    await rejects(
      () => call(a, 'chat.sendText', {'text': ' ', 'requestId': 'empty'}),
      'empty text',
    );
    final receipts = await Future.wait([
      call(a, 'chat.sendText', {'text': 'hello', 'requestId': 'once'}),
      call(same, 'chat.sendText', {'text': 'hello', 'requestId': 'once'}),
    ]);
    check(host.inserts == 1, 'cross-session deduplication');
    check(receipts.any((r) => r['duplicate'] == true), 'duplicate receipt');
    await call(b, 'chat.sendText', {'text': 'other', 'requestId': 'once'});
    check(host.inserts == 2, 'different conversation namespace');
    check(
      (await call(a, 'chat.status', {'requestId': 'once'}))['status'] == 'sent',
      'persisted status',
    );
    check(
      (await call(make(plugin: 'other.plugin'), 'chat.status', {
            'requestId': 'once',
          }))['status'] ==
          'not_found',
      'plugin status isolation',
    );
    await rejects(
      () => call(a, 'media.download', {
        'url': 'https://evil.example/image',
        'kind': 'image',
      }),
      'origin denied',
    );
    await rejects(
      () => call(
        a,
        'media.download',
        {'url': 'https://cdn.example.com/image', 'kind': 'image'},
        permissions: ['media.download'],
      ),
      'network permission',
    );
    final resource = await call(a, 'media.download', {
      'url': 'https://cdn.example.com/a',
      'kind': 'image',
    });
    check(!resource.containsKey('path'), 'no filesystem path exposure');
    await rejects(
      () => call(b, 'chat.sendImage', {
        'resourceId': resource['resourceId'],
        'requestId': 'steal',
      }),
      'resource call isolation',
    );
    final image = await call(a, 'chat.sendImage', {
      'resourceId': resource['resourceId'],
      'caption': 'image',
      'requestId': 'image',
    });
    final imagePath = host.rows[image['messageId']]!['file_path'] as String;
    check(await File(imagePath).exists(), 'image persisted');
    check(
      await call(a, 'media.release', {'resourceId': resource['resourceId']}) ==
          true,
      'release resource',
    );
    check(
      await File(imagePath).exists(),
      'release does not delete delivered file',
    );
    host.respond = (_) async => http.Response.bytes([
      0,
      0,
      0,
      20,
      102,
      116,
      121,
      112,
      105,
      115,
      111,
      109,
      0,
    ], 200);
    final video = await call(a, 'chat.sendVideo', {
      'url': 'https://cdn.example.com/v',
      'requestId': 'video',
    });
    check(video['type'] == 'video', 'video delivery');
    host.respond = (_) async => http.Response.bytes([
      82,
      73,
      70,
      70,
      0,
      0,
      0,
      0,
      87,
      65,
      86,
      69,
      0,
    ], 200);
    final audio = await call(a, 'chat.sendAudio', {
      'url': 'https://cdn.example.com/a',
      'requestId': 'audio',
      'duration': 3,
    });
    check(
      audio['type'] == 'audio' &&
          host.rows[audio['messageId']]!['duration'] == 3,
      'audio delivery',
    );
    host.respond = (_) async => http.Response('<html>not an image</html>', 200);
    await rejects(
      () => call(a, 'chat.sendImage', {
        'url': 'https://cdn.example.com/html',
        'requestId': 'html',
      }),
      'HTML rejected',
    );
    host.respond = (_) async =>
        http.Response('', 302, headers: {'location': 'https://evil.example/a'});
    await rejects(
      () => call(a, 'media.download', {
        'url': 'https://cdn.example.com/redirect',
        'kind': 'image',
      }),
      'redirect origin validation',
    );
    final timeout = make(timeout: const Duration(milliseconds: 5));
    host.respond = (_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response.bytes([137, 80, 78, 71, 13, 10, 26, 10], 200);
    };
    await rejects(
      () => call(timeout, 'media.download', {
        'url': 'https://cdn.example.com/slow',
        'kind': 'image',
      }),
      'timeout',
    );
    host.failAfterInsert = true;
    check(
      (await call(a, 'chat.sendText', {
            'text': 'committed',
            'requestId': 'notify-fail',
          }))['status'] ==
          'sent',
      'notification failure after commit',
    );
    host.failAfterInsert = false;
    host.failInsert = true;
    await rejects(
      () => call(a, 'chat.sendText', {
        'text': 'not committed',
        'requestId': 'db-fail',
      }),
      'db failure',
    );
    host.failInsert = false;
    host.botExists = false;
    await rejects(
      () =>
          call(a, 'chat.sendText', {'text': 'missing', 'requestId': 'missing'}),
      'deleted bot',
    );
    host.botExists = true;
    current = false;
    await rejects(
      () => call(a, 'chat.sendText', {'text': 'stale', 'requestId': 'stale'}),
      'invalidation',
    );
    current = true;
    final closed = make();
    await closed.close();
    await rejects(() => call(closed, 'chat.context', {}), 'expired context');
    for (final kind in ['image', 'video', 'audio']) {
      await rejects(
        () async =>
            PluginMediaContract.extension([60, 104, 116, 109, 108], kind),
        'invalid signature $kind',
      );
    }
    final quota = make();
    for (var i = 0; i < 10; i++) {
      await call(quota, 'chat.sendText', {'text': 'q', 'requestId': 'quota$i'});
    }
    await rejects(
      () => call(quota, 'chat.sendText', {'text': 'q', 'requestId': 'quota10'}),
      'message quota',
    );
    await a.close();
    check(await File(imagePath).exists(), 'session cleanup keeps sent media');
    print('Plugin chat/media: $checks checks passed');
  } finally {
    for (final s in sessions) {
      await s.close();
    }
    await root.delete(recursive: true);
  }
}
