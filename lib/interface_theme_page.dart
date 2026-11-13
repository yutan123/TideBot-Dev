import 'package:flutter/material.dart';

import 'global_notice.dart';
import 'theme.dart';
import 'ui_components.dart';

/// 界面风格的选择入口；配色与背景仍由现有主题设置管理。
class InterfaceThemePage extends StatefulWidget {
  const InterfaceThemePage({super.key});

  @override
  State<InterfaceThemePage> createState() => _InterfaceThemePageState();
}

class _InterfaceThemePageState extends State<InterfaceThemePage> {
  bool _saving = false;

  Future<void> _select(String next) async {
    if (_saving) return;
    final theme = TideTheme.of(context);
    setState(() => _saving = true);
    try {
      await theme.setInterfaceTheme(next);
    } catch (_) {
      if (mounted) GlobalNotice.show('保存主题失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return Scaffold(
      backgroundColor: theme.pageBackground,
      appBar: AppBar(
        title: const Text('主题'),
        backgroundColor: theme.pageBackground,
        foregroundColor: theme.textStrong,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          InterfaceThemeCard(
            title: 'TideBot主题',
            applied: !theme.isWechat,
            busy: _saving,
            removable: false,
            onPressed: () => _select('default'),
          ),
          const SizedBox(height: 20),
          InterfaceThemeCard(
            title: '微信风主题',
            applied: theme.isWechat,
            busy: _saving,
            onPressed: () => _select(theme.isWechat ? 'default' : 'wechat'),
          ),
        ],
      ),
    );
  }
}

/// 主题展示卡片，上部预留预览区域，后续可传入实际预览内容。
class InterfaceThemeCard extends StatelessWidget {
  const InterfaceThemeCard({
    super.key,
    required this.title,
    required this.applied,
    required this.onPressed,
    this.busy = false,
    this.removable = true,
    this.preview,
  });

  final String title;
  final bool applied;
  final bool busy;
  final bool removable;
  final VoidCallback onPressed;
  final Widget? preview;

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return FrostCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 10,
              child: ColoredBox(color: theme.surfaceVariant, child: preview),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: theme.textStrong,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy || (applied && !removable)
                        ? null
                        : onPressed,
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      busy
                          ? '正在保存…'
                          : (applied ? (removable ? '卸下' : '已应用') : '应用'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
