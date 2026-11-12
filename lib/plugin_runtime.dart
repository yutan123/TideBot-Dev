import 'dart:convert';
import 'dart:isolate';
import 'dart:ffi';
import 'dart:io';

import 'package:quickjs_engine/quickjs_engine.dart';
import 'package:quickjs_engine/quickjs/ffi.dart' as qjs;

import 'plugin_transport.dart';
import 'plugin_process_transport.dart';
import 'plugin_process_channel.dart';
export 'plugin_transport.dart' show PluginHostCall;

class PluginRuntime {
  PluginRuntime(
    PluginHostCall host, {
    String pluginId = '',
    void Function()? onClosed,
  }) {
    if (Platform.isAndroid) {
      _process = PluginProcessTransport(
        host,
        bridge: pluginProcessBridge,
        pluginId: pluginId,
        onClosed: onClosed,
      );
    } else {
      _local = PluginTransport(
        host,
        workerEntry: pluginWorker,
        onClosed: onClosed,
      );
    }
  }
  PluginProcessTransport? _process;
  PluginTransport? _local;
  bool get closed => _process?.closed ?? _local!.closed;
  Future<void> start(String sdk, String script, Map<String, dynamic> config) =>
      _process?.start(sdk, script, config) ??
      _local!.start(sdk, script, config);
  Future<dynamic> call(String kind, String name, dynamic payload) =>
      _process?.call(kind, name, payload) ?? _local!.call(kind, name, payload);
  void close() {
    if (_process != null) {
      _process!.close();
    } else {
      _local!.close();
    }
  }
}

void pluginWorker(List<dynamic> initial) {
  final parent = initial[0] as SendPort;
  final commands = ReceivePort();
  QuickJsRuntime2? engine;

  void fatal(Object error) {
    commands.close();
    parent.send({'type': 'fatal', 'error': error.toString()});
    final failed = engine;
    engine = null;
    failed?.dispose();
  }

  try {
    // Install a real native interrupt: the package timeout constructor argument
    // is not implemented by its C++ bridge in the pinned version.
    final runtime = QuickJsRuntime2(memoryLimit: 32 * 1024 * 1024);
    engine = runtime;
    runtime.port.close();
    JavascriptRuntime.channelFunctionsRegistered[runtime.getEngineInstanceId()]!
        .clear();
    parent.send(commands.sendPort);
    // The pinned bridge exposes its runtime registry. This isolate owns exactly
    // one engine; no private pointer offsets or ABI-dependent JSValue layout.
    final nativeRuntime = qjs.runtimeOpaques.keys.single;
    final library = Platform.isAndroid || Platform.isLinux
        ? DynamicLibrary.open('libquickjs_c_bridge_plugin.so')
        : DynamicLibrary.process();
    final setInterrupt = library
        .lookupFunction<
          Void Function(
            Pointer<Void>,
            Pointer<NativeFunction<_Interrupt>>,
            Pointer<Void>,
          ),
          void Function(
            Pointer<Void>,
            Pointer<NativeFunction<_Interrupt>>,
            Pointer<Void>,
          )
        >('JS_SetInterruptHandler');
    setInterrupt(
      nativeRuntime.cast(),
      Pointer.fromFunction<_Interrupt>(_interrupt, 1),
      nullptr,
    );
    void jobs() {
      _deadline = _clock.elapsedMilliseconds + 1000;
      for (var i = 0; i < 1000; i++) {
        if (_clock.elapsedMilliseconds > _deadline)
          throw StateError('插件任务执行超时');
        final status = qjs.jsExecutePendingJob(nativeRuntime);
        if (status < 0) throw StateError('插件异步任务执行失败');
        if (status == 0) return;
      }
      throw StateError('插件微任务队列超过限制');
    }

    void evaluate(String code) {
      _deadline = _clock.elapsedMilliseconds + 1000;
      final result = runtime.evaluate(code);
      if (result.isError) throw StateError(result.stringResult);
    }

    runtime.onMessage('tide.host', (dynamic data) {
      if (data is! Map ||
          data['id'] is! int ||
          data['method'] is! String ||
          data['args'] is! Map)
        throw const FormatException('宿主请求格式无效');
      if (jsonEncode(data).length > 1024 * 1024) throw StateError('宿主请求过大');
      parent.send({'type': 'host', 'data': data});
      return null;
    });
    runtime.onMessage('tide.result', (dynamic data) {
      if (data is! Map ||
          data['id'] is! int ||
          (data['error'] != null && data['error'] is! String))
        throw const FormatException('插件结果格式无效');
      if (jsonEncode(data).length > 1024 * 1024) throw StateError('插件结果过大');
      parent.send({'type': 'result', 'data': data});
      return null;
    });
    // Avoid the engine's untracked native timers and console bridge. SDK logs
    // are handled by the host, and asynchronous work uses Promise-based RPC.
    evaluate(
      'globalThis.setTimeout = undefined; globalThis.console = Object.freeze({log(){},warn(){},error(){}});',
    );
    evaluate('globalThis.__tideConfig = ${jsonEncode(initial[3])};');
    evaluate(initial[1] as String);
    evaluate(initial[2] as String);
    jobs();
    parent.send({'type': 'ready'});
    commands.listen((dynamic message) {
      try {
        if (message['close'] == true) {
          commands.close();
          engine = null;
          runtime.dispose();
          return;
        }
        if (message.containsKey('resolve')) {
          evaluate(
            '__tideResolve(${jsonEncode(message['resolve'])}, ${jsonEncode(message['value'])}, ${jsonEncode(message['error'])});',
          );
        } else {
          evaluate(
            '__tideDispatch(${jsonEncode(message['id'])}, ${jsonEncode(message['kind'])}, ${jsonEncode(message['name'])}, ${jsonEncode(message['payload'])});',
          );
        }
        jobs();
      } catch (error) {
        fatal(error);
      }
    });
  } catch (error) {
    fatal(error);
  }
}

typedef _Interrupt = Int32 Function(Pointer<Void>, Pointer<Void>);
final _clock = Stopwatch()..start();
int _deadline = 0;
int _interrupt(Pointer<Void> runtime, Pointer<Void> opaque) =>
    _clock.elapsedMilliseconds >= _deadline ? 1 : 0;
