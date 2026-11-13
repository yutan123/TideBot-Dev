import 'plugin_operation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'plugin_media_contract.dart';

abstract class PluginChatHost {
  Future<bool> hasBot(String botId);
  Future<Map<String, dynamic>?> findMessage(String id, String botId);
  Future<void> insert(Map<String, dynamic> message);
  Future<Directory> documents();
  Future<Directory> temporary();
  Future<T> locked<T>(String key, Future<T> Function() work);
  http.Client createClient();
}

/// An explicit capability for one tool invocation; never shared as global JS state.
class PluginChatSession {
  PluginChatSession({
    required this.pluginId,
    required this.botId,
    required this.assertCurrent,
    required this.host,
    this.downloadTimeout = PluginTimeouts.media,
  });
  final PluginChatHost host;
  final Duration downloadTimeout;
  final String pluginId, botId;
  final Future<void> Function() assertCurrent;
  final token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _resources = <String, Map<String, dynamic>>{};
  final _clients = <http.Client>{};
  Future<void> _queue = Future.value();
  bool _active = true;
  int _sent = 0;

  Future<void> check() async {
    if (!_active) throw StateError('调用上下文已结束');
    await assertCurrent();
    if (!_active) throw StateError('调用上下文已结束');
  }

  Future<dynamic> call(
    String method,
    Map<String, dynamic> args,
    List permissions,
    List origins,
  ) {
    // Serialize effects inside a call; native locks serialize between engines.
    final result = _queue.then((_) async {
      await check();
      if (method == 'chat.context')
        return {'botId': botId, 'conversationId': botId, 'pluginId': pluginId};
      if (method.startsWith('chat.') && !permissions.contains('chat.send'))
        throw StateError('未声明 chat.send 权限');
      if (method == 'chat.status') return _status(args);
      if (method.startsWith('media.') &&
          !permissions.contains('media.download'))
        throw StateError('未声明 media.download 权限');
      if (method == 'media.download')
        return _download(args, permissions, origins);
      if (method == 'media.release') {
        final resource = _resources.remove(args['resourceId']);
        if (resource == null) return false;
        await File(resource['path'] as String).delete();
        return true;
      }
      if (!{
        'chat.sendText',
        'chat.sendImage',
        'chat.sendVideo',
        'chat.sendAudio',
      }.contains(method))
        throw StateError('未知聊天 API');
      final requestId = PluginMediaContract.text(
        args['requestId'],
        'requestId',
        128,
        required: true,
      );
      final id = _messageId(requestId);
      return host.locked('chat:$id', () async {
        await check();
        final existing = await _row(id);
        if (existing != null) return _receipt(existing, duplicate: true);
        if (_sent >= 10) throw StateError('单次工具调用最多发送 10 条消息');
        if (!await host.hasBot(botId)) throw StateError('会话已不存在');
        final kind = method.substring('chat.send'.length).toLowerCase();
        final content = PluginMediaContract.text(
          kind == 'text' ? args['text'] : args['caption'],
          kind == 'text' ? 'text' : 'caption',
          kind == 'text' ? 16000 : 2000,
          required: kind == 'text',
        );
        Map<String, dynamic>? resource;
        if (kind != 'text') {
          if (args['resourceId'] != null && args['url'] != null)
            throw const FormatException('url 与 resourceId 不能同时提供');
          if (args['resourceId'] == null) {
            final downloaded = await _download(
              {...args, 'kind': kind},
              permissions,
              origins,
            );
            resource = _resources[downloaded['resourceId']];
          } else {
            resource = _resources[args['resourceId']];
          }
          if (resource == null || resource['kind'] != kind)
            throw StateError('媒体引用不存在或类型不匹配');
        }
        final duration = args['duration'] ?? 0;
        if (duration is! int || duration < 0 || duration > 86400)
          throw const FormatException('duration 必须为 0～86400 的秒数');
        File? delivered;
        final row = <String, dynamic>{
          'id': id,
          'bot_id': botId,
          'role': 'assistant',
          'type': kind,
          'content': content,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'duration': duration,
        };
        try {
          if (resource != null) {
            final docs = await host.documents();
            final folder = Directory(
              p.join(docs.path, 'chat_media', 'plugins'),
            );
            await folder.create(recursive: true);
            delivered = await File(
              resource['path'] as String,
            ).copy(p.join(folder.path, '$id.${resource['extension']}'));
            row['file_path'] = delivered.path;
          }
          // Lifecycle lock makes invalidation and the final commit mutually exclusive.
          await host.locked('lifecycle', () async {
            await check();
            await host.insert(row);
          });
          _sent++;
          return _receipt(row);
        } catch (_) {
          // Notifications may fail after persistence; never remove committed media.
          final committed = await _row(id);
          if (committed != null) {
            _sent++;
            return _receipt(committed);
          }
          if (delivered != null && await delivered.exists())
            await delivered.delete();
          rethrow;
        }
      });
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  String _messageId(String key) =>
      'plugin_${sha256.convert(utf8.encode(jsonEncode([pluginId, botId, key])))}';
  Future<Map<String, dynamic>?> _row(String id) async {
    return host.findMessage(id, botId);
  }

  Map<String, dynamic> _receipt(Map row, {bool duplicate = false}) => {
    'messageId': row['id'],
    'botId': botId,
    'type': row['type'],
    'status': 'sent',
    'duplicate': duplicate,
    'timestamp': row['timestamp'],
  };
  Future<Map<String, dynamic>> _status(Map<String, dynamic> args) async {
    final key = PluginMediaContract.text(
      args['requestId'],
      'requestId',
      128,
      required: true,
    );
    final row = await _row(_messageId(key));
    return row == null ? {'status': 'not_found'} : _receipt(row);
  }

  Future<Map<String, dynamic>> _download(
    Map<String, dynamic> args,
    List permissions,
    List origins,
  ) async {
    if (!permissions.contains('media.download') ||
        !permissions.contains('network'))
      throw StateError('下载需要 network 和 media.download 权限');
    final kind = args['kind'];
    final max = PluginMediaContract.limits[kind];
    if (max == null) throw const FormatException('kind 必须为 image/video/audio');
    if (_resources.length >= 4) throw StateError('单次调用最多保留 4 个媒体资源，请先释放');
    var uri = PluginMediaContract.uri(args['url'], origins);
    final client = host.createClient();
    _clients.add(client);
    File? partial;
    RandomAccessFile? handle;
    var expired = false;
    Future<void> downloadCheck() async {
      if (expired) throw TimeoutException('媒体下载超时');
      await check();
      if (expired) throw TimeoutException('媒体下载超时');
    }

    Future<Map<String, dynamic>>? operation;
    try {
      operation = (() async {
        http.StreamedResponse? response;
        for (var redirects = 0; redirects <= 3; redirects++) {
          await downloadCheck();
          response = await client.send(
            http.Request('GET', uri)..followRedirects = false,
          );
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers['location'];
            if (location == null || redirects == 3)
              throw StateError('媒体重定向过多或缺少地址');
            uri = PluginMediaContract.uri(
              uri.resolve(location).toString(),
              origins,
            );
            await response.stream.drain<void>();
            continue;
          }
          break;
        }
        if (response == null || response.statusCode != 200)
          throw StateError('媒体下载 HTTP ${response?.statusCode}');
        if ((response.contentLength ?? 0) > max) throw StateError('媒体超过大小限制');
        final temp = await host.temporary();
        final folder = Directory(p.join(temp.path, 'tide_plugin_media', token));
        await folder.create(recursive: true);
        final resourceId =
            'r${_resources.length}_${Random.secure().nextInt(1 << 32)}';
        partial = File(p.join(folder.path, resourceId));
        handle = await partial!.open(mode: FileMode.write);
        final head = <int>[];
        var size = 0;
        await for (final chunk in response.stream) {
          await downloadCheck();
          size += chunk.length;
          if (size > max) throw StateError('媒体超过大小限制');
          if (head.length < 64) head.addAll(chunk.take(64 - head.length));
          await handle!.writeFrom(chunk);
        }
        await handle!.close();
        handle = null;
        final extension = PluginMediaContract.extension(head, kind as String);
        await downloadCheck();
        final resource = {
          'resourceId': resourceId,
          'kind': kind,
          'size': size,
          'extension': extension,
          'path': partial!.path,
        };
        _resources[resourceId] = resource;
        partial = null;
        return Map<String, dynamic>.from(resource)..remove('path');
      })();
      return await operation.timeout(
        downloadTimeout,
        onTimeout: () async {
          expired = true;
          client.close();
          // Wait for the cancelled stream to unwind before touching its file.
          try {
            await operation;
          } catch (_) {}
          throw TimeoutException('媒体下载超时');
        },
      );
    } finally {
      client.close();
      _clients.remove(client);
      await handle?.close();
      if (partial != null && await partial!.exists()) await partial!.delete();
    }
  }

  void cancel() {
    _active = false;
    for (final client in _clients.toList()) {
      client.close();
    }
  }

  Future<void> close() async {
    cancel();
    await _queue;
    final temp = await host.temporary();
    final folder = Directory(p.join(temp.path, 'tide_plugin_media', token));
    if (await folder.exists()) await folder.delete(recursive: true);
    _resources.clear();
  }
}
