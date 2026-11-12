import 'package:flutter/services.dart';
import 'plugin_process_transport.dart';

final pluginProcessBridge = _PlatformPluginProcessBridge();

class _PlatformPluginProcessBridge implements PluginProcessBridge {
  static const _channel = MethodChannel('tidebot.plugin.process');
  @override
  Future<void> send(String method, String payload) =>
      _channel.invokeMethod<void>(method, payload);
  @override
  void setReceiver(void Function(String) receiver) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event') receiver(call.arguments as String);
    });
  }
}
