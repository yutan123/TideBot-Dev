import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

typedef PluginHostCall =
    Future<dynamic> Function(String method, Map<String, dynamic> args);

/// One engine and Dart isolate per enabled plugin. Only JSON crosses the bridge.
class PluginTransport {
  final PluginHostCall host;
  final void Function()? onClosed;
  final void Function(List<dynamic>) workerEntry;
  PluginTransport(this.host, {required this.workerEntry, this.onClosed});
  final _pending = <int, Completer<dynamic>>{};
  final _port = ReceivePort();
  final _ready = Completer<void>();
  Isolate? _isolate;
  SendPort? _worker;
  int _sequence = 0;
  int _hostCalls = 0;
  bool _closed = false;

  Future<void> start(
    String sdk,
    String script,
    Map<String, dynamic> config,
  ) async {
    _port.listen((dynamic message) {
      if (message is SendPort) {
        _worker = message;
        return;
      }
      if (message is! Map) return;
      if (message['type'] == 'ready') {
        if (!_ready.isCompleted) _ready.complete();
      } else if (message['type'] == 'fatal') {
        _fail(StateError(message['error'].toString()));
      } else if (message['type'] == 'result') {
        final data = message['data'] as Map;
        final completer = _pending.remove(data['id']);
        if (data['error'] != null) {
          completer?.completeError(StateError(data['error'].toString()));
        } else {
          completer?.complete(data['value']);
        }
      } else if (message['type'] == 'host') {
        unawaited(_host(message['data'] as Map));
      }
    });
    // Attach an error listener before startup so even a native-loader Dart error
    // completes the startup future instead of leaving a hanging enabled plugin.
    final errors = ReceivePort();
    _errors = errors;
    errors.listen((dynamic error) => _fail(StateError('插件运行环境异常：$error')));
    final exits = ReceivePort();
    _exits = exits;
    exits.listen((_) {
      if (!_closed) _fail(StateError('插件运行环境意外退出'));
    });
    try {
      await Future.wait<void>([
        Isolate.spawn(
          workerEntry,
          [_port.sendPort, sdk, script, config],
          onError: errors.sendPort,
          onExit: exits.sendPort,
          errorsAreFatal: true,
        ).then((isolate) {
          _isolate = isolate;
          if (_closed) isolate.kill(priority: Isolate.immediate);
        }),
        _ready.future,
      ], eagerError: true).timeout(const Duration(seconds: 8));
    } catch (_) {
      close();
      rethrow;
    }
  }

  ReceivePort? _errors;
  ReceivePort? _exits;

  Future<void> _host(Map data) async {
    if (_closed) return;
    if (_hostCalls >= 64) {
      _fail(StateError('插件并发宿主请求超过 64'));
      return;
    }
    _hostCalls++;
    try {
      final value = await host(
        data['method'] as String,
        Map<String, dynamic>.from(data['args'] as Map),
      );
      final encoded = jsonEncode(value);
      if (encoded.length > 1024 * 1024) {
        throw StateError('宿主响应超过 1 MB');
      }
      final result = jsonDecode(encoded);
      if (!_closed) _worker?.send({'resolve': data['id'], 'value': result});
    } catch (error) {
      if (!_closed)
        _worker?.send({'resolve': data['id'], 'error': error.toString()});
    } finally {
      _hostCalls--;
    }
  }

  Future<dynamic> call(String kind, String name, dynamic payload) async {
    if (_closed || _worker == null) throw StateError('插件未运行');
    if (_pending.length >= 32) throw StateError('插件调用过多');
    final id = ++_sequence;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      _worker!.send({'id': id, 'kind': kind, 'name': name, 'payload': payload});
    } catch (e) {
      // SendPort.send throws synchronously for unsendable types. Remove the
      // pending entry immediately so the slot is not held until a 15s timeout.
      _pending.remove(id);
      rethrow;
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      close();
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  bool get closed => _closed;

  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    close();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _worker?.send({'close': true});
    // Give dispose a turn, then terminate a worker even if JS never yields.
    final isolate = _isolate;
    Timer(
      const Duration(seconds: 2),
      () => isolate?.kill(priority: Isolate.immediate),
    );
    _port.close();
    _errors?.close();
    _exits?.close();
    for (final completer in _pending.values) {
      completer.completeError(StateError('插件已停止'));
    }
    _pending.clear();
    onClosed?.call();
  }
}
