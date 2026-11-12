import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'plugin_transport.dart';

abstract interface class PluginProcessBridge {
  Future<void> send(String method, String payload);
  void setReceiver(void Function(String payload) receiver);
}

/// A host-side session. Android owns process allocation; JS never runs here.
class PluginProcessTransport {
  PluginProcessTransport(
    this.host, {
    required this.bridge,
    this.pluginId = '',
    this.onClosed,
  });
  final PluginProcessBridge bridge;
  final String pluginId;
  final PluginHostCall host;
  final void Function()? onClosed;
  static final _sessions = <String, PluginProcessTransport>{};
  static final _listening = Expando<bool>('plugin process receiver');
  final String _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _ready = Completer<void>();
  final _pending = <int, Completer<dynamic>>{};
  bool _closed = false;
  bool _started = false;
  int _sequence = 0;
  int _hostCalls = 0;
  bool get closed => _closed;

  Future<void> start(
    String sdk,
    String script,
    Map<String, dynamic> config,
  ) async {
    if (_started || _closed) throw StateError('插件运行环境不可重复启动');
    _started = true;
    if (_listening[bridge] != true) {
      _listening[bridge] = true;
      bridge.setReceiver((payload) {
        final event = jsonDecode(payload) as Map;
        _sessions[event['token']]?._event(event);
      });
    }
    _sessions[_token] = this;
    // Listen before the platform can report a startup failure.
    final ready = _ready.future.timeout(const Duration(seconds: 15));
    try {
      await Future.wait<void>([
        _invoke('open', {
          'op': 'start',
          'pluginId': pluginId,
          'sdk': sdk,
          'script': script,
          'config': config,
        }),
        ready,
      ], eagerError: true);
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<void> _invoke(String method, Map<String, dynamic> message) async {
    final encoded = jsonEncode({...message, 'token': _token});
    if (encoded.length > 8 * 1024 * 1024) throw StateError('插件 IPC 消息过大');
    await bridge.send(method, encoded);
  }

  void _event(Map event) {
    if (_closed) return;
    switch (event['type']) {
      case 'ready':
        if (!_ready.isCompleted) _ready.complete();
      case 'fatal':
        _fail(StateError(event['error'].toString()));
      case 'result':
        final pending = _pending.remove(event['id']);
        if (event['error'] != null) {
          pending?.completeError(StateError(event['error'].toString()));
        } else {
          pending?.complete(event['value']);
        }
      case 'host':
        unawaited(_host(event));
    }
  }

  Future<void> _host(Map event) async {
    if (++_hostCalls > 64) {
      _hostCalls--;
      _fail(StateError('插件并发宿主请求超过 64'));
      return;
    }
    try {
      dynamic value;
      String? error;
      try {
        value = await host(
          event['method'] as String,
          Map<String, dynamic>.from(event['args'] as Map),
        );
        if (jsonEncode(value).length > 1024 * 1024) {
          throw StateError('宿主响应超过 1 MB');
        }
      } catch (e) {
        value = null;
        error = e.toString();
      }
      if (!_closed) {
        await _invoke('send', {
          'op': 'resolve',
          'id': event['id'],
          'value': value,
          'error': error,
        });
      }
    } catch (error) {
      _fail(error);
    } finally {
      _hostCalls--;
    }
  }

  Future<dynamic> call(String kind, String name, dynamic payload) async {
    if (_closed || !_ready.isCompleted) throw StateError('插件未运行');
    if (_pending.length >= 32) throw StateError('插件调用过多');
    final id = ++_sequence;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    // Attach before send: disconnect may reject pending while send is in flight.
    final response = completer.future.timeout(const Duration(seconds: 15));
    try {
      final values = await Future.wait<dynamic>([
        _invoke('send', {
          'op': 'call',
          'id': id,
          'kind': kind,
          'name': name,
          'payload': payload,
        }),
        response,
      ], eagerError: true);
      return values[1];
    } on TimeoutException {
      close();
      rethrow;
    } catch (error) {
      if (!completer.isCompleted) completer.completeError(error);
      if (error is! JsonUnsupportedObjectError) _fail(error);
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    if (!_ready.isCompleted) _ready.completeError(error);
    close();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_started && !_ready.isCompleted) {
      _ready.completeError(StateError('插件启动已取消'));
    }
    _sessions.remove(_token);
    for (final pending in _pending.values) {
      pending.completeError(StateError('插件独立进程已停止'));
    }
    _pending.clear();
    unawaited(_invoke('close', {}).catchError((Object _) {}));
    onClosed?.call();
  }
}
