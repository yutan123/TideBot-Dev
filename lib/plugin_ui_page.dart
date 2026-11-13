import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'plugin_contract.dart';
import 'plugin_service.dart';
import 'plugin_system.dart';
import 'plugin_web_page.dart';
import 'theme.dart';

/// Routes package UI to the declared renderer.
class PluginUiPage extends StatefulWidget {
  final TidePluginPackage package;
  const PluginUiPage({super.key, required this.package});
  @override
  State<PluginUiPage> createState() => _PluginUiPageState();
}

class _PluginUiPageState extends State<PluginUiPage> {
  Map<String, dynamic>? _layout;
  final _values = <String, dynamic>{};
  final _controllers = <String, TextEditingController>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final path = widget.package.manifest['ui']['entry'] as String;
      final file = File(p.join(widget.package.directory.path, path));
      if (await file.length() > 1024 * 1024)
        throw const FormatException('界面文件超过 1 MB');
      final layout = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      PluginContract.layout(layout);
      if (mounted)
        setState(() {
          _applyLayout(layout);
          _error = null;
        });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _action(String name) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await PluginService.instance.uiAction(
        widget.package.id,
        name,
        Map.of(_values),
      );
      if (result is Map && result['ui'] is Map) {
        final layout = Map<String, dynamic>.from(result['ui'] as Map);
        PluginContract.layout(layout);
        if (mounted) setState(() => _applyLayout(layout));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyLayout(Map<String, dynamic> layout) {
    final values = PluginContract.formValues(layout, _values);
    for (final id in _controllers.keys.toList()) {
      if (values[id] is! String) {
        final controller = _controllers.remove(id)!;
        // The previous TextField still owns this controller until rebuild.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => controller.dispose(),
        );
      }
    }
    for (final entry in values.entries) {
      if (entry.value is String) {
        _controllers.putIfAbsent(
          entry.key,
          () => TextEditingController(text: entry.value as String),
        );
      }
    }
    _values
      ..clear()
      ..addAll(values);
    _layout = layout;
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _node(Map node) {
    final children = node['children'] as List? ?? [];
    final id = node['id'] as String? ?? '';
    final label = node['label'] as String? ?? '';
    switch (node['type']) {
      case 'text':
        return Text(
          node['text'] as String? ?? '',
          style: node['style'] == 'title'
              ? Theme.of(context).textTheme.titleLarge
              : null,
        );
      case 'column':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _node(child as Map),
              ),
          ],
        );
      case 'row':
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final child in children)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _node(child as Map),
                ),
              ),
          ],
        );
      case 'card':
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final child in children) _node(child as Map)],
            ),
          ),
        );
      case 'divider':
        return const Divider();
      case 'input':
        return TextFormField(
          key: ValueKey(id),
          controller: _controllers[id],
          enabled: !_busy,
          obscureText: node['secret'] == true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          onChanged: (value) => _values[id] = value,
        );
      case 'toggle':
        return SwitchListTile(
          title: Text(label),
          value: _values[id] as bool,
          onChanged: _busy
              ? null
              : (value) => setState(() => _values[id] = value),
        );
      case 'button':
        return FilledButton(
          onPressed: _busy ? null : () => _action(node['action'] as String),
          child: Text(label),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.package.manifest['ui']['type'] == 'web'
      ? PluginWebPage(package: widget.package)
      : Scaffold(
          backgroundColor: TideTheme.of(context).pageBackground,
          appBar: AppBar(title: Text(widget.package.name)),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_layout != null)
                  _node(_layout!)
                else if (_error == null)
                  const Center(child: CircularProgressIndicator())
                else
                  TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        );
}
