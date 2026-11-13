import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'plugin_config_dialog.dart';
import 'plugin_service.dart';
import 'plugin_operation.dart';
import 'transfer_progress.dart';
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
  PluginOperation? _operation;

  @override
  void dispose() {
    _operation?.cancel();
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

  Future<void> _operate(
    Future<void> Function() action, {
    bool cancellable = false,
    String label = '正在处理插件…',
  }) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final operation = cancellable ? PluginOperation() : null;
    _operation = operation;
    operation?.startDeadline();
    try {
      await TransferProgress.run(context, label, () async {
        operation?.check();
        await action();
      }, operation: operation);
    } catch (error) {
      if (mounted) {
        if (operation?.cancelled == true) {
          try {
            operation?.check();
          } catch (reason) {
            _notice('$reason');
          }
        } else {
          _notice('操作失败：$error');
        }
      }
    } finally {
      operation?.dispose();
      _operation = null;
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
      _operation?.check();
      await PluginSystem.instance.installZip(path, operation: _operation);
      if (mounted) _notice('插件已安装，默认关闭；配置完成后可启用');
    } finally {
      await _cleanTemp();
    }
  }

  Future<void> _update(Map<String, dynamic> row) async {
    final path = await _pickZip();
    if (path == null) return;
    try {
      _operation?.check();
      await PluginService.instance.updateZip(
        row['id'] as String,
        path,
        operation: _operation,
      );
      if (mounted) _notice('插件已更新');
    } finally {
      await _cleanTemp();
    }
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    final theme = TideTheme.of(context);
    final confirmed = await TideDialogs.show<bool>(
      context: context,
      builder: (dialogContext) => TideDialogSurface(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        child: TideDialogs.glassContent(
          context: dialogContext,
          maxWidth: 0.84,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30).withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    color: Color(0xFFFF3B30),
                    size: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '删除插件',
                    style: TextStyle(
                      color: theme.textStrong,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '确定卸载“${row['name']}”？其文件、配置和私有数据都会被删除。',
              style: TextStyle(
                color: theme.textWeak,
                height: 1.5,
                fontSize: 13,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text('取消', style: TextStyle(color: theme.textWeak)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFF3B30),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    minimumSize: const Size(0, 42),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
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

  Widget _pluginIcon(TidePluginPackage? pack, {double size = 44}) {
    final theme = TideTheme.of(context);
    final icon = pack?.manifest['icon'] as String?;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.primary.withValues(alpha: .18),
            theme.primary.withValues(alpha: .06),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(Icons.power_rounded, size: size * .5, color: theme.primary),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * .28),
      child: icon == null || pack == null
          ? fallback
          : Image.file(
              File(p.join(pack.directory.path, icon)),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }

  String _author(Map<String, dynamic> row) {
    final author = row['author']?.toString().trim() ?? '';
    return author.isEmpty ? '未知作者' : author;
  }

  Future<void> _details(Map<String, dynamic> row) => TideDialogs.show<void>(
    context: context,
    builder: (dialogContext) {
      final theme = TideTheme.of(dialogContext);
      final pack = _packages[row['id']];
      final error = PluginService.instance.errors[row['id']];
      return Center(
        child: Material(
          color: Colors.transparent,
          child: TideDialogs.glassContent(
            context: dialogContext,
            children: [
              Row(
                children: [
                  _pluginIcon(pack, size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row['name']?.toString() ?? row['id'].toString(),
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: theme.textStrong,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${_author(row)} · v${row['version']}',
                          style: TextStyle(fontSize: 12, color: theme.textWeak),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭详情',
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                '插件介绍',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.textWeak,
                ),
              ),
              const SizedBox(height: 9),
              SelectableText(
                (row['description']?.toString().trim().isNotEmpty ?? false)
                    ? row['description'].toString()
                    : '暂无介绍',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.65,
                  color: theme.textStrong,
                ),
              ),
              const SizedBox(height: 20),
              SelectableText(
                'ID  ${row['id']}',
                style: TextStyle(fontSize: 12, color: theme.textWeak),
              ),
              const SizedBox(height: 8),
              Text(
                pack == null
                    ? '插件文件不可用'
                    : row['enabled'] == 1
                    ? '已启用'
                    : '未启用',
                style: TextStyle(fontSize: 12, color: theme.textWeak),
              ),
              if (pack != null) ...[
                const SizedBox(height: 8),
                Text(
                  '工具 ${(pack.manifest['tools'] as List? ?? []).length} 个',
                  style: TextStyle(fontSize: 12, color: theme.textWeak),
                ),
                if ((pack.manifest['permissions'] as List? ?? [])
                    .isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    '权限  ${(pack.manifest['permissions'] as List).join(' · ')}',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: theme.textWeak,
                    ),
                  ),
                ],
              ],
              if (error != null) ...[
                const SizedBox(height: 16),
                SelectableText(
                  error,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _action(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    bool destructive = false,
  }) {
    final theme = TideTheme.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: destructive
            ? Theme.of(context).colorScheme.error.withValues(alpha: .8)
            : theme.textWeak,
        disabledForegroundColor: theme.textFaint,
      ),
      icon: Icon(icon, size: 19),
    );
  }

  Widget _card(Map<String, dynamic> row) {
    final theme = TideTheme.of(context);
    final id = row['id'] as String;
    final pack = _packages[id];
    final enabled = row['enabled'] == 1;
    final error = PluginService.instance.errors[id];
    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.primary.withValues(alpha: .45),
          width: .7,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: theme.isDark ? .08 : .025),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _details(row),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 8, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: _pluginIcon(pack),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row['name']?.toString() ?? id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: theme.textStrong,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            row['description']?.toString() ?? '暂无介绍',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: theme.textWeak,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${_author(row)} · ${row['version']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.textWeak,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Semantics(
                        label: '启用插件',
                        toggled: enabled,
                        button: true,
                        child: Tooltip(
                          message: enabled ? '停用插件' : '启用插件',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: _busy || pack == null
                                ? null
                                : () => _operate(
                                    () => PluginService.instance.setEnabled(
                                      id,
                                      !enabled,
                                      operation: _operation,
                                    ),
                                    cancellable: !enabled,
                                    label: enabled ? '正在关闭插件…' : '正在启用插件…',
                                  ),
                            child: SizedBox(
                              width: 48,
                              height: 44,
                              child: Center(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: 38,
                                  height: 23,
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: enabled
                                        ? theme.primary
                                        : theme.surfaceVariant,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: AnimatedAlign(
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeOutCubic,
                                    alignment: enabled
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    child: Container(
                                      width: 17,
                                      height: 17,
                                      decoration: BoxDecoration(
                                        color: _busy || pack == null
                                            ? theme.textFaint
                                            : enabled
                                            ? Colors.white
                                            : theme.textWeak,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const SizedBox(width: 56),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: error != null || pack == null
                            ? Theme.of(context).colorScheme.error
                            : enabled
                            ? theme.primary
                            : theme.textFaint,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        error != null
                            ? '运行异常'
                            : pack == null
                            ? '文件不可用'
                            : enabled
                            ? '已启用'
                            : '未启用',
                        style: TextStyle(fontSize: 10, color: theme.textWeak),
                      ),
                    ),
                    if (pack != null &&
                        ((pack.manifest['config'] as Map?)?['properties']
                                    as Map? ??
                                {})
                            .isNotEmpty)
                      _action(
                        Icons.tune_rounded,
                        '插件设置',
                        _busy ? null : () => _settings(pack),
                      ),
                    if (pack?.hasUi == true)
                      _action(
                        Icons.open_in_new_rounded,
                        '打开插件',
                        _busy
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => PluginUiPage(package: pack!),
                                ),
                              ),
                      ),
                    _action(
                      Icons.upgrade_rounded,
                      '更新插件',
                      _busy
                          ? null
                          : () => _operate(
                              () => _update(row),
                              cancellable: true,
                              label: '正在更新插件…',
                            ),
                    ),
                    _action(
                      Icons.delete_outline_rounded,
                      '卸载插件',
                      _busy ? null : () => _remove(row),
                      destructive: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabs() {
    final theme = TideTheme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.surfaceVariant.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(17),
      ),
      child: LayoutBuilder(
        builder: (_, constraints) => Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: _tab == 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: Container(
                width: constraints.maxWidth / 2,
                decoration: BoxDecoration(
                  color: theme.surface,
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .06),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: List.generate(2, (index) {
                final selected = _tab == index;
                return Expanded(
                  child: Semantics(
                    selected: selected,
                    button: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(13),
                        onTap: () => setState(() => _tab = index),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 180),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selected
                                  ? theme.textStrong
                                  : theme.textWeak,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  index == 0
                                      ? Icons.widgets_outlined
                                      : Icons.storefront_outlined,
                                  size: 17,
                                  color: selected
                                      ? theme.primary
                                      : theme.textWeak,
                                ),
                                const SizedBox(width: 8),
                                Text(index == 0 ? '插件列表' : '插件市场'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
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
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
            child: _tabs(),
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
              onPressed: _busy
                  ? null
                  : () =>
                        _operate(_install, cancellable: true, label: '正在安装插件…'),
              tooltip: '导入插件 ZIP',
              child: const Icon(Icons.add_rounded),
            )
          : null,
    );
  }
}
