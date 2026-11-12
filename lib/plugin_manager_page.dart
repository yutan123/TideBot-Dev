import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'plugin_config_dialog.dart';
import 'plugin_service.dart';
import 'plugin_system.dart';
import 'plugin_ui_page.dart';
import 'theme.dart';
import 'ui_components.dart';

class PluginManagerPage extends StatefulWidget {
  const PluginManagerPage({super.key});
  @override
  State<PluginManagerPage> createState() => _PluginManagerPageState();
}

class _PluginManagerPageState extends State<PluginManagerPage> {
  var _tab = 0;
  var _loading = true;
  var _busy = false;

  @override
  void dispose() {
    _cleanTemp();
    super.dispose();
  }

  String? _error;
  List<Map<String, dynamic>> _plugins = [];
  final _packages = <String, TidePluginPackage>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      await PluginService.instance.initialize();
      final rows = await PluginSystem.instance.list();
      final packs = <String, TidePluginPackage>{};
      for (final row in rows) {
        try {
          packs[row['id'] as String] = await PluginSystem.instance.packageFor(
            row,
          );
        } catch (_) {
          /* Damaged packages can still be removed. */
        }
      }
      if (!mounted) return;
      setState(() {
        _plugins = rows;
        _packages
          ..clear()
          ..addAll(packs);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = error.toString();
        });
    }
  }

  void _notice(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _operate(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _notice('操作失败：$error');
    } finally {
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _pickZip() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip', 'tideplugin'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final item = picked.files.single;
    if (item.path != null) return item.path;
    if (item.bytes != null) {
      final tmp = await Directory.systemTemp.createTemp('tide-plugin-');
      _tempDirs.add(tmp);
      final path = p.join(tmp.path, 'package.zip');
      await File(path).writeAsBytes(item.bytes!);
      return path;
    }
    throw const FormatException('无法读取插件文件');
  }

  final _tempDirs = <Directory>[];

  Future<void> _cleanTemp() async {
    for (final dir in _tempDirs.toList()) {
      try {
        await dir.delete(recursive: true);
        _tempDirs.remove(dir);
      } catch (_) {}
    }
  }

  Future<void> _install() async {
    final path = await _pickZip();
    if (path == null) return;
    try {
      await PluginSystem.instance.installZip(path);
      if (mounted) _notice('插件已安装，默认关闭；配置完成后可启用');
    } finally {
      await _cleanTemp();
    }
  }

  Future<void> _update(Map<String, dynamic> row) async {
    final path = await _pickZip();
    if (path == null) return;
    try {
      await PluginService.instance.updateZip(row['id'] as String, path);
      if (mounted) _notice('插件已更新');
    } finally {
      await _cleanTemp();
    }
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final confirmed = await TideDialogs.show<bool>(
      context: context,
      builder: (context) => TideDialogs.glassContent(
        context: context,
        children: [
          Text('删除插件', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text('卸载“${row['name']}”并删除其文件、配置和私有数据？'),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed == true && mounted)
      await _operate(() => PluginService.instance.delete(row['id'] as String));
  }

  Future<void> _settings(TidePluginPackage pack) async {
    try {
      final schema = pack.manifest['config'] as Map?;
      if (schema == null || (schema['properties'] as Map).isEmpty) {
        _notice('此插件没有配置项');
        return;
      }
      final values = await PluginSystem.instance.loadConfig(pack.id);
      if (!mounted) return;
      final result = await TideDialogs.show<Map<String, dynamic>>(
        context: context,
        builder: (_) => PluginConfigDialog(
          title: '${pack.name} 设置',
          schema: schema,
          values: values,
        ),
      );
      if (result != null && mounted)
        await _operate(
          () => PluginService.instance.saveConfig(pack.id, result),
        );
    } catch (error) {
      if (mounted) _notice('设置失败：$error');
    }
  }

  Widget _logo() => Image.asset(
    'assets/images/logo.png',
    width: 48,
    height: 48,
    fit: BoxFit.cover,
  );

  Widget _card(Map<String, dynamic> row) {
    final id = row['id'] as String;
    final pack = _packages[id];
    final icon = pack?.manifest['icon'] as String?;
    final error = PluginService.instance.errors[id];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TideTheme.of(context).surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TideTheme.of(context).border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: icon == null || pack == null
                    ? _logo()
                    : Image.file(
                        File(p.join(pack.directory.path, icon)),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _logo(),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row['name']?.toString() ?? id,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      row['description']?.toString() ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${row['author'] == '' ? '未知作者' : row['author']} · v${row['version']}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Switch(
                value: row['enabled'] == 1,
                onChanged: _busy || pack == null
                    ? null
                    : (value) => _operate(
                        () => PluginService.instance.setEnabled(id, value),
                      ),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Divider(height: 24),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: _busy || pack == null ? null : () => _settings(pack),
                icon: const Icon(Icons.tune_rounded),
                label: const Text('设置'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => _operate(() => _update(row)),
                icon: const Icon(Icons.system_update_alt_rounded),
                label: const Text('更新'),
              ),
              if (pack?.hasUi == true)
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PluginUiPage(package: pack!),
                          ),
                        ),
                  icon: const Icon(Icons.open_in_full_rounded),
                  label: const Text('打开界面'),
                ),
              IconButton(
                tooltip: '删除插件',
                onPressed: _busy ? null : () => _remove(row),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return Scaffold(
      backgroundColor: theme.pageBackground,
      appBar: AppBar(
        title: const Text('插件'),
        backgroundColor: theme.pageBackground,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('插件列表'),
                  icon: Icon(Icons.extension_rounded),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('插件市场'),
                  icon: Icon(Icons.storefront_rounded),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (value) => setState(() => _tab = value.first),
            ),
          ),
        ),
      ),
      body: _tab == 1
          ? const Center(child: Text('插件市场暂未开放'))
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: TextButton(
                onPressed: _reload,
                child: Text('加载失败，点击重试：$_error'),
              ),
            )
          : Column(
              children: [
                if (_busy) const LinearProgressIndicator(),
                Expanded(
                  child: _plugins.isEmpty
                      ? const Center(child: Text('暂无已安装插件'))
                      : RefreshIndicator(
                          onRefresh: _reload,
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                            itemCount: _plugins.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 12),
                            itemBuilder: (_, index) => _card(_plugins[index]),
                          ),
                        ),
                ),
              ],
            ),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              onPressed: _busy ? null : () => _operate(_install),
              tooltip: '导入插件 ZIP',
              child: const Icon(Icons.add_rounded),
            )
          : null,
    );
  }
}
