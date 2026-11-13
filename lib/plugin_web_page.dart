import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'plugin_coordinator.dart';
import 'plugin_package_files.dart';
import 'plugin_service.dart';
import 'plugin_system.dart';
import 'plugin_web_server.dart';
import 'theme.dart';

class PluginWebPage extends StatefulWidget {
  const PluginWebPage({super.key, required this.package});
  final TidePluginPackage package;
  @override
  State<PluginWebPage> createState() => _PluginWebPageState();
}

class _PluginWebPageState extends State<PluginWebPage> {
  PluginWebServer? _server;
  WebViewController? _controller;
  String? _error;
  int? _epoch;
  final _pending = <int>{};
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _check() async {
    if (!mounted || _epoch != await PluginCoordinator.epoch(widget.package.id))
      throw StateError('插件界面已失效，请重新打开');
  }

  Future<void> _load() async {
    try {
      _epoch = await PluginCoordinator.epoch(widget.package.id);
      final server = PluginWebServer(
        PluginPackageFiles(widget.package.directory),
        widget.package.manifest['ui']['entry'] as String,
        _check,
      );
      _server = server;
      await server.start();
      if (!mounted) {
        await server.close();
        return;
      }
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.addJavaScriptChannel(
        'TidePluginUI',
        onMessageReceived: (message) => unawaited(_action(message.message)),
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return request.isMainFrame && uri == server.url
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _ready = true);
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true)
              setState(() => _error = error.description);
          },
        ),
      );
      await controller.setBackgroundColor(Colors.transparent);
      await controller.loadRequest(server.url);
      if (mounted) setState(() {});
    } catch (error) {
      await _server?.close();
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _action(String raw) async {
    int? id;
    bool accepted = false;
    try {
      await _check();
      if (raw.length > 65536) throw const FormatException('网页请求超过 64 Ki 字符');
      final data = jsonDecode(raw);
      if (data is! Map || data['id'] is! int)
        throw const FormatException('网页请求格式错误');
      id = data['id'] as int;
      if (_pending.contains(id)) return;
      if (_pending.length >= 8) throw StateError('网页并发操作超过 8 个');
      final action = data['action'];
      if (action is! String ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$').hasMatch(action) ||
          data['values'] is! Map)
        throw const FormatException('action 或 values 无效');
      _pending.add(id);
      accepted = true;
      final value = await PluginService.instance.uiAction(
        widget.package.id,
        action,
        Map<String, dynamic>.from(data['values'] as Map),
      );
      await _check();
      final encoded = jsonEncode(value);
      if (encoded.length > 65536) throw StateError('网页响应超过 64 Ki 字符');
      if (mounted)
        await _controller?.runJavaScript('__tideUIResolve($id,$encoded,null);');
    } catch (error) {
      if (id != null && mounted) {
        try {
          await _controller?.runJavaScript(
            '__tideUIResolve($id,null,${jsonEncode(error.toString())});',
          );
        } catch (_) {}
      }
    } finally {
      if (accepted) _pending.remove(id);
    }
  }

  @override
  void dispose() {
    unawaited(_server?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: TideTheme.of(context).pageBackground,
    appBar: AppBar(title: Text(widget.package.name)),
    body: _error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!),
            ),
          )
        : Stack(
            children: [
              if (_controller != null) WebViewWidget(controller: _controller!),
              if (!_ready) const Center(child: CircularProgressIndicator()),
            ],
          ),
  );
}
