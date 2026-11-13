import 'reasoning_control.dart';
import 'bot_avatar_crop_page.dart';
import 'support_us_page.dart';
import 'mimo_voice_clone.dart';
import 'mimo_voice_workbench.dart';
import 'permission_management_page.dart';
import 'android_selection_menu.dart';
import 'bot_reference_images_page.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:heif_converter/heif_converter.dart';
import 'persistent_service_coordinator.dart';
import 'app_permissions.dart';
import 'ui_components.dart';
import 'db.dart';
import 'data_transfer.dart';
import 'transfer_progress.dart';
import 'ai.dart';
import 'global_notice.dart';
import 'legal_pages.dart';
import 'theme.dart';
import 'data_dashboard.dart';
import 'sticker_manager_page.dart';
import 'life_schedule_service.dart';
import 'life_schedule_pool_page.dart';
import 'advanced_settings_page.dart';
import 'storage_management_page.dart';
import 'chat_background_page.dart';
import 'global_background_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _userName = '用户';
  String _avatarPath = '';
  final _settings = [
    {'icon': Icons.api_rounded, 'title': 'API 设置', 'page': 'api'},
    {'icon': Icons.palette_rounded, 'title': '主题设置', 'page': 'theme'},
    {'icon': Icons.tune_rounded, 'title': '普通设置', 'page': 'general'},
    {
      'icon': Icons.settings_suggest_rounded,
      'title': '高级设置',
      'page': 'advanced',
    },
    {'icon': Icons.notifications_rounded, 'title': '通知管理', 'page': 'notify'},
    {
      'icon': Icons.verified_user_outlined,
      'title': '权限管理',
      'page': 'permissions',
    },
    {'icon': Icons.analytics_rounded, 'title': '数据大盘', 'page': 'dashboard'},
    {'icon': Icons.info_rounded, 'title': '关于 TideBot', 'page': 'about'},
    {'icon': Icons.storage_rounded, 'title': '数据管理', 'page': 'data'},
    {'icon': Icons.favorite_rounded, 'title': '支持我们', 'page': 'support'},
    {'icon': Icons.feedback_rounded, 'title': '反馈与建议', 'page': 'feedback'},
  ];
  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final name = await DBManager().getKV('user_name');
    final avatar = await DBManager().getKV('user_avatar');
    if (mounted) {
      setState(() {
        if (name != null && name.isNotEmpty) _userName = name;
        if (avatar != null && avatar.isNotEmpty) _avatarPath = avatar;
      });
    }
  }

  Future<void> _pickAvatar() async {
    if (!await AppPermissions.photos(context, feature: '更换头像')) return;
    try {
      final img = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (img == null) return;
      String path = img.path;
      if (path.toLowerCase().endsWith('.heic') ||
          path.toLowerCase().endsWith('.heif')) {
        final converted = await HeifConverter.convert(path);
        if (converted != null) path = converted;
      }
      if (!mounted) return;
      final dest = await selectBotAvatarCrop(context, path);
      if (dest == null) return;
      await DBManager().insertKV('user_avatar', dest);
      if (mounted) setState(() => _avatarPath = dest);
    } catch (_) {}
  }

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _userName);
    final name = await TideDialogs.show<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          children: [
            Text(
              '修改昵称',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
                color: TideTheme.of(ctx).textStrong,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              contextMenuBuilder: androidTextContextMenu,
              controller: ctrl,
              autofocus: true,
              style: TextStyle(
                fontFamily: 'TideFont',
                color: TideTheme.of(ctx).textStrong,
              ),
              decoration: const InputDecoration(hintText: '输入新昵称'),
            ),
            const SizedBox(height: 12),
            TideDialogs.glassButton(
              '保存',
              onTap: () => Navigator.pop(ctx, ctrl.text.trim()),
            ),
          ],
        ),
      ),
    );
    if (name != null && name.isNotEmpty && mounted) {
      setState(() => _userName = name);
      await DBManager().insertKV('user_name', name);
    }
  }

  @override
  Widget build(BuildContext context) => TideBackground(
    child: SafeArea(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: TideTheme.of(context).isWechat
            ? const EdgeInsets.only(bottom: 24)
            : const EdgeInsets.fromLTRB(16, 16, 16, 92),
        child: Column(
          children: [
            _buildProfileCard(),
            SizedBox(height: TideTheme.of(context).isWechat ? 0 : 24),
            ..._settings.map(
              (s) => BouncyTap(
                onTap: () => _onSetting(s),
                child: _buildSettingItem(s),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    ),
  );
  Widget _buildProfileCard() {
    final theme = TideTheme.of(context);
    final content = Row(
      children: [
        BouncyTap(
          onTap: _pickAvatar,
          child: CircleAvatar(
            radius: 38,
            backgroundColor: theme.primary.withValues(alpha: 0.15),
            backgroundImage:
                _avatarPath.isNotEmpty && File(_avatarPath).existsSync()
                ? FileImage(File(_avatarPath))
                : null,
            child: _avatarPath.isEmpty || !File(_avatarPath).existsSync()
                ? Icon(Icons.person_rounded, size: 42, color: theme.primary)
                : null,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: BouncyTap(
            onTap: _editName,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _userName,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'TideFont',
                    color: theme.onBackgroundStrong,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '点击昵称修改名字',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.onBackgroundWeak,
                    fontFamily: 'TideFont',
                  ),
                ),
              ],
            ),
          ),
        ),
        Icon(Icons.edit_rounded, size: 18, color: theme.onBackgroundWeak),
      ],
    );
    if (theme.isWechat)
      return Container(
        color: theme.surface,
        padding: const EdgeInsets.fromLTRB(24, 38, 24, 32),
        child: content,
      );
    // 全局背景图下不显示卡片，直接返回内容
    if (theme.useLiquidGlass) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
        child: content,
      );
    }
    return FrostCard(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      child: content,
    );
  }

  Widget _buildSettingItem(Map<String, dynamic> s) {
    final theme = TideTheme.of(context);
    final content = Row(
      children: [
        Icon(s['icon'] as IconData, size: 24, color: theme.primary),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            s['title'] ?? '',
            style: TextStyle(
              fontSize: 17,
              fontFamily: 'TideFont',
              color: theme.onBackgroundStrong,
            ),
          ),
        ),
        Icon(
          Icons.arrow_forward_ios_rounded,
          size: 14,
          color: theme.onBackgroundWeak,
        ),
      ],
    );
    if (theme.isWechat)
      return Container(
        color: theme.surface,
        padding: const EdgeInsets.only(left: 20),
        child: Container(
          padding: const EdgeInsets.fromLTRB(0, 18, 20, 18),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.border, width: .5)),
          ),
          child: content,
        ),
      );
    // 全局背景图下不显示卡片
    if (theme.useLiquidGlass) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ).copyWith(bottom: 10),
        child: content,
      );
    }
    return FrostCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: content,
    );
  }

  Future<String?> _pickDataBot(String title) async {
    final bots = await TransferProgress.run(
      context,
      '正在读取机器人列表…',
      () => DBManager().exportableBots(),
    );
    if (!mounted) return null;
    if (bots.isEmpty) {
      GlobalNotice.show('当前没有可选机器人');
      return null;
    }
    return showTideSheet<String>(
      context: context,
      height: 420,
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
                color: TideTheme.of(context).textStrong,
              ),
            ),
          ),
          ...bots.map(
            (bot) => ListTile(
              leading: TideBotAvatar(
                name: bot['name']?.toString() ?? '未命名',
                path: bot['avatar']?.toString(),
                size: 42,
              ),
              title: Text(
                bot['name']?.toString() ?? '未命名机器人',
                style: const TextStyle(fontFamily: 'TideFont'),
              ),
              onTap: () => Navigator.pop(context, bot['id']?.toString()),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportSelectedChat() => TransferProgress.guard(() async {
    final botId = await _pickDataBot('选择要导出的机器人');
    if (botId == null || !mounted) return;
    try {
      await TransferProgress.run(
        context,
        '正在打包聊天记录并准备保存…',
        () => DataTransfer.exclusive(() async {
          final export = await DBManager().buildChatExport(botId);
          try {
            final saved = await DataTransfer.save(
              export.file,
              export.fileName,
              'application/zip',
            );
            if (mounted && saved != null) {
              GlobalNotice.show(
                export.missingMedia == 0
                    ? '聊天记录已导出'
                    : '聊天记录已导出；${export.missingMedia} 处媒体引用已失效，文字和现有附件已保留',
              );
              TideHaptics.confirm();
            }
          } finally {
            await export.file.parent.delete(recursive: true);
          }
        }),
      );
    } catch (e) {
      if (mounted) {
        GlobalNotice.show('导出失败：$e', color: const Color(0xFFE74C3C));
        TideHaptics.error();
      }
    }
  });
  Future<void> _importSelectedChat() => TransferProgress.guard(() async {
    final botId = await _pickDataBot('选择要导入到的机器人');
    if (botId == null || !mounted) return;
    final confirmed = await _confirmDataOverwrite('聊天记录');
    if (!confirmed || !mounted) return;
    try {
      final count = await TransferProgress.run<int?>(
        context,
        '正在读取并导入聊天记录…',
        () => DataTransfer.pickImport<int>(const [
          'zip',
          'json',
        ], (path) => DBManager().importBotChat(botId, path)),
      );
      if (!mounted || count == null) return;
      GlobalNotice.show('已导入 $count 条聊天记录');
      TideHaptics.confirm();
    } catch (e) {
      if (mounted) {
        GlobalNotice.show('导入失败：$e', color: const Color(0xFFE74C3C));
        TideHaptics.error();
      }
    }
  });
  Future<bool> _confirmDataOverwrite(String label) async {
    final result = await TideDialogs.show<bool>(
      context: context,
      builder: (ctx) => TideDialogSurface(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          children: [
            const Text(
              '确认覆盖',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '当前机器人的$label将被导入文件直接覆盖，此操作不可恢复。',
              textAlign: TextAlign.start,
              style: TextStyle(
                color: TideTheme.of(ctx).textWeak,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TideDialogs.glassButton(
                    '取消',
                    onTap: () => Navigator.pop(ctx, false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TideDialogs.glassButton(
                    '继续',
                    onTap: () => Navigator.pop(ctx, true),
                    color: const Color(0xFFE74C3C),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  Future<void> _exportSelectedMemory() => TransferProgress.guard(() async {
    final botId = await _pickDataBot('选择要导出世界书的机器人');
    if (botId == null || !mounted) return;
    try {
      await TransferProgress.run(
        context,
        '正在导出世界书并准备保存…',
        () => DataTransfer.exclusive(() async {
          final export = await DBManager().buildMemoryExport(botId);
          try {
            final saved = await DataTransfer.save(
              export.file,
              export.fileName,
              'application/json',
            );
            if (mounted && saved != null) GlobalNotice.show('世界书已导出');
          } finally {
            await export.file.parent.delete(recursive: true);
          }
        }),
      );
    } catch (e) {
      if (!mounted) return;
      GlobalNotice.show('导出失败：$e', color: const Color(0xFFE74C3C));
    }
  });
  Future<void> _importSelectedMemory() => TransferProgress.guard(() async {
    final botId = await _pickDataBot('选择要导入世界书的机器人');
    if (botId == null || !mounted) return;

    // 弹窗选择合并/覆盖
    final mode = await showTideSheet<String>(
      context: context,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '选择导入方式',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 20),
            ListTile(
              leading: const Icon(Icons.merge_rounded),
              title: const Text('合并', style: TextStyle(fontFamily: 'TideFont')),
              subtitle: const Text(
                '保留现有世界书，按时间智能插入新内容',
                style: TextStyle(fontFamily: 'TideFont', fontSize: 12),
              ),
              onTap: () => Navigator.pop(context, 'merge'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.sync_rounded),
              title: const Text('覆盖', style: TextStyle(fontFamily: 'TideFont')),
              subtitle: const Text(
                '删除现有世界书，完全替换为导入内容',
                style: TextStyle(fontFamily: 'TideFont', fontSize: 12),
              ),
              onTap: () => Navigator.pop(context, 'overwrite'),
            ),
            const SizedBox(height: 12),
            TideDialogs.glassButton('取消', onTap: () => Navigator.pop(context)),
          ],
        ),
      ),
    );

    if (mode == null || !mounted) return;
    try {
      final count = await TransferProgress.run<int?>(
        context,
        '正在读取并导入世界书…',
        () => DataTransfer.pickImport<int>(
          const ['json'],
          (path) =>
              DBManager().importBotMemory(botId, path, merge: mode == 'merge'),
        ),
      );
      if (!mounted || count == null) return;
      GlobalNotice.show(
        mode == 'merge' ? '已合并导入 $count 条世界书' : '已覆盖导入 $count 条世界书',
      );
      TideHaptics.confirm();
    } on FormatException catch (e) {
      if (mounted) GlobalNotice.show(e.message, color: const Color(0xFFE74C3C));
    } catch (e) {
      if (mounted) GlobalNotice.show('导入失败：$e', color: const Color(0xFFE74C3C));
    }
  });

  void _onSetting(Map<String, dynamic> s) {
    switch (s['page']) {
      case 'api':
        Navigator.push(
          context,
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const ApiSettingsPage(),
            transitionsBuilder: (_, a, __, c) =>
                FadeTransition(opacity: a, child: c),
            transitionDuration: const Duration(milliseconds: 300),
          ),
        );
        break;
      case 'theme':
        _showThemePicker();
        break;
      case 'general':
        _showGeneralSettings();
        break;
      case 'advanced':
        _showAdvancedSettings();
        break;
      case 'permissions':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PermissionManagementPage()),
        );
        break;
      case 'notify':
        _showNotificationSettings();
        break;
      case 'about':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const TideBotAboutPage()),
        );
        break;
      case 'data':
        showTideSheet(
          context: context,
          height: 430,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '数据管理',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'TideFont',
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: Icon(
                    Icons.download_rounded,
                    color: TideTheme.of(context).primary,
                  ),
                  title: const Text(
                    '导出聊天记录',
                    style: TextStyle(fontFamily: 'TideFont'),
                  ),
                  onTap: () async {
                    if (TransferProgress.isBusy) return;
                    Navigator.pop(context);
                    await _exportSelectedChat();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.memory_rounded,
                    color: TideTheme.of(context).primary,
                  ),
                  title: const Text(
                    '导出世界书',
                    style: TextStyle(fontFamily: 'TideFont'),
                  ),
                  subtitle: const Text(
                    '包含记忆、日记、今日一言和相遇时间',
                    style: TextStyle(fontFamily: 'TideFont', fontSize: 12),
                  ),
                  onTap: () async {
                    if (TransferProgress.isBusy) return;
                    Navigator.pop(context);
                    await _exportSelectedMemory();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.settings_backup_restore_rounded,
                    color: TideTheme.of(context).primary,
                  ),
                  title: const Text(
                    '导入世界书',
                    style: TextStyle(fontFamily: 'TideFont'),
                  ),
                  subtitle: const Text(
                    '选择文件后可选合并或覆盖',
                    style: TextStyle(fontFamily: 'TideFont', fontSize: 12),
                  ),
                  onTap: () async {
                    if (TransferProgress.isBusy) return;
                    Navigator.pop(context);
                    await _importSelectedMemory();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.upload_file_rounded,
                    color: TideTheme.of(context).primary,
                  ),
                  title: const Text(
                    '导入聊天记录',
                    style: TextStyle(fontFamily: 'TideFont'),
                  ),
                  subtitle: const Text(
                    '支持 TideBot 导出的 ZIP 或 JSON 文件',
                    style: TextStyle(fontFamily: 'TideFont', fontSize: 12),
                  ),
                  onTap: () async {
                    if (TransferProgress.isBusy) return;
                    Navigator.pop(context);
                    await _importSelectedChat();
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.storage_rounded,
                    color: TideTheme.of(context).primary,
                  ),
                  title: const Text(
                    '存储空间',
                    style: TextStyle(fontFamily: 'TideFont'),
                  ),
                  subtitle: const Text(
                    '查看占用、清理缓存和多选聊天记录',
                    style: TextStyle(fontFamily: 'TideFont', fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const StorageManagementPage(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
        break;
      case 'dashboard':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const DataDashboardPage()),
        );
        break;
      case 'privacy':
        showTideSheet(
          context: context,
          height: 350,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '隐私与安全',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'TideFont',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'TideBot 采用纯本地架构：',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'TideFont',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '所有聊天数据存储在本地数据库\nAPI 密钥加密存储在本地\n无任何数据上传\n无统计 SDK, 无广告',
                  style: TextStyle(
                    fontSize: 13,
                    color: TideTheme.of(context).textWeak,
                    fontFamily: 'TideFont',
                    height: 1.8,
                  ),
                ),
              ],
            ),
          ),
        );
        break;
      case 'support':
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SupportUsPage()));
        break;
      case 'feedback':
        _openFeedback();
        break;
      default:
        GlobalNotice.show('${s['title']}功能开发中...');
    }
  }

  Future<void> _openFeedback() async {
    try {
      if (await launchUrl(
        Uri.parse('https://wj.qq.com/s2/28578088/ilkl/'),
        mode: LaunchMode.externalApplication,
      ))
        return;
    } catch (_) {
      // Keep the settings page usable if no browser can handle the link.
    }
    if (mounted) GlobalNotice.show('无法打开反馈页面，请检查是否安装浏览器后重试');
  }

  // 主题设置的配色圆点（取 theme.dart 的日间主色作为预览）
  Color _themeDotPrimary(String id) {
    final map = {
      'rose': const Color(0xFFD98C94),
      'aurora': const Color(0xFF6C8CD5),
      'lavender': const Color(0xFF9B8AC4),
      'sky': const Color(0xFF5D9BC5),
      'mint': const Color(0xFF5FAF8A),
      'peach': const Color(0xFFE39A6B),
      'plum': const Color(0xFF8E74B4),
      'teal': const Color(0xFF4FA79C),
      'sunset': const Color(0xFFE06A5A),
      'ocean': const Color(0xFF3E7CB1),
      'pinkg': const Color(0xFFE07A9A),
      'night': const Color(0xFF6B5FAE),
    };
    return map[id] ?? const Color(0xFF6C8CD5);
  }

  void _showThemePicker() {
    showTideSheet(
      context: context,
      height: 560,
      child: StatefulBuilder(
        builder: (ctx, setSt) {
          final t = TideTheme.of(ctx, listen: false);
          String mi = 'auto';
          if (!t.hasManualMode) {
            mi = 'auto';
          } else if (t.mode == ThemeMode.dark)
            mi = 'dark';
          else
            mi = 'light';
          final options = TideTheme.themeOptions;
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题 + 右上角日/夜切换按钮
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '主题设置',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'TideFont',
                        ),
                      ),
                    ),
                    // 日/夜/跟随 循环切换（system->light->dark->system）
                    GestureDetector(
                      onTap: () => t.cycleMode().then((_) {
                        if (ctx.mounted) setSt(() {});
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          color: t.bgColor == const Color(0xFFF2F2F7)
                              ? t.primary.withValues(alpha: 0.12)
                              : Colors.white.withValues(alpha: 0.12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              mi == 'dark'
                                  ? Icons.dark_mode_rounded
                                  : (mi == 'auto'
                                        ? Icons.brightness_auto_rounded
                                        : Icons.wb_sunny_rounded),
                              size: 16,
                              color: t.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              mi == 'dark'
                                  ? '夜间'
                                  : (mi == 'auto' ? '跟随系统' : '日间'),
                              style: TextStyle(
                                fontSize: 12,
                                fontFamily: 'TideFont',
                                color: t.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '选择你喜欢的配色方案，日夜均跟随系统',
                  style: TextStyle(
                    fontSize: 13,
                    color: TideTheme.of(context).textWeak,
                    fontFamily: 'TideFont',
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView(
                    children: options.map((item) {
                      final id = item['id']!;
                      final name = item['name']!;
                      final active = t.name == id;
                      return BouncyTap(
                        onTap: () {
                          t.setTheme(id);
                          setSt(() {});
                        },
                        child: FrostCard(
                          liquid: true,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _themeDotPrimary(id),
                                ),
                                child: active
                                    ? const Icon(
                                        Icons.check,
                                        color: Colors.white,
                                        size: 18,
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  name,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontFamily: 'TideFont',
                                    color: TideTheme.of(context).textStrong,
                                  ),
                                ),
                              ),
                              if (active)
                                Icon(
                                  Icons.check_circle,
                                  color: TideTheme.of(ctx).primary,
                                  size: 20,
                                ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),
                BouncyTap(
                  onTap: () async {
                    await t.restoreDefaults();
                    if (ctx.mounted) setSt(() {});
                  },
                  child: Container(
                    width: double.infinity,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: t.buttonSecondary,
                    ),
                    child: Center(
                      child: Text(
                        '恢复默认主题与背景',
                        style: TextStyle(
                          fontSize: 14,
                          color: t.textStrong,
                          fontFamily: 'TideFont',
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                BouncyTap(
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ChatBackgroundPage(),
                      ),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: TideTheme.of(ctx).primary),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 20,
                          color: TideTheme.of(ctx).primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '聊天背景图',
                          style: TextStyle(
                            fontSize: 15,
                            color: TideTheme.of(ctx).primary,
                            fontFamily: 'TideFont',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // 全局背景图入口。它与机器人聊天背景独立保存。
                BouncyTap(
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const GlobalBackgroundPage(),
                      ),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: TideTheme.of(ctx).primary),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.wallpaper_rounded,
                          size: 20,
                          color: TideTheme.of(ctx).primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '全局背景图',
                          style: TextStyle(
                            fontSize: 15,
                            color: TideTheme.of(ctx).primary,
                            fontFamily: 'TideFont',
                          ),
                        ),
                        if (t.hasGlobalBackground) ...[
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.check_circle,
                            size: 16,
                            color: Color(0xFF34C759),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showGeneralSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const GeneralSettingsPage()));
  }

  void _showAdvancedSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AdvancedSettingsPage()));
  }

  void _showNotificationSettings() async {
    final db = DBManager();
    final unread = (await db.getKV('unread_notifications')) != 'false';
    final keepRunning = (await db.getKV('persistent_notification')) == 'true';
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationSettingsPage(
          initialUnread: unread,
          initialKeepRunning: keepRunning,
        ),
      ),
    );
  }
}

class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  bool _showTime = true;
  bool _dimParentheticalText = true;
  bool _showAvatar = false;
  bool _streaming = true;
  bool _adaptiveSilence = true;
  bool _innerThought = true;
  bool _segmentedReply = true;
  bool _randomReplyDelay = false;
  bool _timeAwareness = true;
  bool _proactiveReply = true;
  bool _botPosts = false;
  bool _botPostsWithImages = false;
  bool _lifeSchedule = true;
  bool _imageGeneration = true;
  bool _webSearch = false;
  bool _showSearchSources = false;
  bool _stickers = false;
  bool _jarvis = false;
  bool _voiceReply = false;
  bool _callEmotionalVoice = true;
  String _imageStyle = '写实';
  String _searchProvider = 'Tavily';
  int _stickerChance = 50;
  int _voiceReplyChance = 50;
  final TextEditingController _voiceReplyChanceController =
      TextEditingController(text: '50');
  final TextEditingController _searchKeyController = TextEditingController();
  bool _showSearchKey = false;
  final TextEditingController _stickerChanceController = TextEditingController(
    text: '50',
  );
  int _proactiveMin = 60;
  int _proactiveMax = 90;
  int _speed = 50;
  final TextEditingController _streamSpeedController = TextEditingController(
    text: '50',
  );
  final TextEditingController _replyDelayMinController = TextEditingController(
    text: '0',
  );
  final TextEditingController _replyDelayMaxController = TextEditingController(
    text: '2',
  );
  final TextEditingController _proactiveMinController = TextEditingController(
    text: '60',
  );
  final TextEditingController _proactiveMaxController = TextEditingController(
    text: '90',
  );
  final TextEditingController _botPostsPerDayController = TextEditingController(
    text: '1',
  );
  final TextEditingController _botPostsImageChanceController =
      TextEditingController(text: '50');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = DBManager();
    final speed = int.tryParse(await db.getKV('streaming_speed') ?? '');
    if (!mounted) return;
    setState(() {
      _showTime = true;
      _showAvatar = false;
      _streaming = true;
      _speed = (speed ?? 50).clamp(1, 100);
      _streamSpeedController.text = _speed.toString();
    });
    final time = await db.getKV('show_message_time');
    final dimParentheticalText = await db.getKV('dim_parenthetical_text');
    final avatar = await db.getKV('show_chat_avatar');
    final stream =
        await db.getKV('streaming_output') ?? await db.getKV('streaming_input');
    final segmentedReply = await db.getKV('segmented_reply_enabled');
    final innerThought = await db.getKV('inner_thought_enabled');
    final adaptiveSilence = await db.getKV('adaptive_silence_enabled');
    final randomReplyDelay = await db.getKV('random_reply_delay_enabled');
    final replyDelayMin = await db.getKV('random_reply_delay_min_seconds');
    final replyDelayMax = await db.getKV('random_reply_delay_max_seconds');
    final timeAwareness = await db.getKV('time_awareness');
    final proactiveReply = await db.getKV('proactive_reply');
    final botPosts = await db.getKV('bot_posts_enabled');
    final botPostsWithImages = await db.getKV('bot_posts_with_images');
    final botPostsImageChance = int.tryParse(
      await db.getKV('bot_posts_image_chance') ?? '',
    );
    final lifeSchedule = await db.getKV('life_schedule_enabled');
    if (mounted) setState(() => _adaptiveSilence = adaptiveSilence != 'false');
    if (mounted) setState(() => _innerThought = innerThought == 'true');
    final imageGeneration = await db.getKV('bot_image_generation_enabled');
    final imageStyle = await db.getKV('bot_image_style');
    final webSearch = await db.getKV('web_search_enabled');
    final showSearchSources = await db.getKV('show_web_search_sources');
    final searchProvider = await db.getKV('web_search_provider');
    final searchKey = await db.getKV('web_search_api_key');
    final stickers = await db.getKV('bot_stickers_enabled');
    final jarvis = await db.getKV('jarvis_enabled');
    final voiceReply = await db.getKV('voice_reply_enabled');
    final callEmotionalVoice = await db.getKV('call_emotional_voice');
    final voiceReplyChance = int.tryParse(
      await db.getKV('voice_reply_chance') ?? '',
    );
    final stickerChance = int.tryParse(
      await db.getKV('bot_sticker_chance') ?? '',
    );
    final botPostsPerDay = int.tryParse(
      await db.getKV('bot_posts_per_day') ?? '',
    );
    final proactiveMin = int.tryParse(
      await db.getKV('proactive_min_minutes') ?? '',
    );
    final proactiveMax = int.tryParse(
      await db.getKV('proactive_max_minutes') ?? '',
    );
    if (!mounted) return;
    setState(() {
      _showTime = time != 'false';
      _dimParentheticalText = dimParentheticalText != 'false';
      _showAvatar = avatar == 'true';
      _streaming = stream != 'false';
      _segmentedReply = segmentedReply != 'false';
      _randomReplyDelay = randomReplyDelay == 'true';
      _replyDelayMinController.text = (int.tryParse(replyDelayMin ?? '') ?? 0)
          .clamp(0, 60)
          .toString();
      _replyDelayMaxController.text = (int.tryParse(replyDelayMax ?? '') ?? 2)
          .clamp(0, 60)
          .toString();
      _timeAwareness = timeAwareness != 'false';
      _proactiveReply = proactiveReply != 'false';
      _botPosts = botPosts == 'true';
      _botPostsWithImages = botPostsWithImages == 'true';
      _botPostsImageChanceController.text = (botPostsImageChance ?? 50)
          .clamp(1, 100)
          .toString();
      _lifeSchedule = lifeSchedule != 'false';
      _imageGeneration = imageGeneration != 'false';
      // 自定义风格是任意文本（如“水彩插画”），不能只按预设白名单判定；
      // 只有真正为空时才回退到默认的“写实”。
      _imageStyle = imageStyle?.trim().isNotEmpty == true ? imageStyle! : '写实';
      _webSearch = webSearch == 'true';
      _showSearchSources = showSearchSources == 'true';
      _searchProvider = _displaySearchProvider(
        searchProvider?.isNotEmpty == true ? searchProvider! : '',
      );
      _searchKeyController.text = searchKey ?? '';
      _stickers = stickers == 'true';
      _jarvis = jarvis == 'true';
      _voiceReply = voiceReply == 'true';
      _callEmotionalVoice = callEmotionalVoice != 'false';
      _voiceReplyChance = (voiceReplyChance ?? 50).clamp(1, 100);
      _voiceReplyChanceController.text = _voiceReplyChance.toString();
      _stickerChance = (stickerChance ?? 50).clamp(1, 100);
      _stickerChanceController.text = _stickerChance.toString();
      _botPostsPerDayController.text = (botPostsPerDay ?? 1)
          .clamp(1, 10)
          .toString();
      _proactiveMin = (proactiveMin ?? 60).clamp(1, 1440);
      _proactiveMax = (proactiveMax ?? 90).clamp(_proactiveMin, 1440);
      _proactiveMinController.text = _proactiveMin.toString();
      _proactiveMaxController.text = _proactiveMax.toString();
      _streamSpeedController.text = _speed.toString();
    });
  }

  @override
  void dispose() {
    _streamSpeedController.dispose();
    _replyDelayMinController.dispose();
    _replyDelayMaxController.dispose();
    _proactiveMinController.dispose();
    _proactiveMaxController.dispose();
    _botPostsPerDayController.dispose();
    _botPostsImageChanceController.dispose();
    _searchKeyController.dispose();
    _voiceReplyChanceController.dispose();
    _stickerChanceController.dispose();
    super.dispose();
  }

  String _displaySearchProvider(String raw) {
    if (raw.toLowerCase().contains('deepseek')) return 'DeepSeek';
    if (raw.contains('Tavily')) return 'Tavily';
    if (raw.contains('博查') || raw.contains('Bocha')) return '博查 Bocha';
    if (raw.contains('Serper')) return 'Serper';
    if (raw.contains('Brave')) return 'Brave Search';
    if (raw.contains('Bing')) return 'Bing Web Search';
    return 'Tavily';
  }

  String _searchKeyLabel(TideTheme theme) =>
      _searchProvider == 'DeepSeek' ? 'DeepSeek API Key' : '搜索 API Key';

  String get _searchKeyHint => _searchProvider == 'DeepSeek'
      ? '填写 DeepSeek 开放平台 API Key，使用官方联网搜索服务。'
      : '填写所选搜索服务商提供的 API Key；常规搜索无结果时会自动尝试内部兜底能力。';

  Future<void> _save(String key, String value) async {
    await DBManager().insertKV(key, value);
  }

  Widget _choiceField({
    required TideTheme theme,
    required String label,
    required String value,
    required List<String> options,
    required ValueChanged<String> onPick,
    Widget? icon,
  }) {
    return BouncyTap(
      onTap: () async {
        final picked = await showTideSheet<String>(
          context: context,
          height: 360,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            children: [
              Text(
                label,
                style: TextStyle(
                  color: theme.textStrong,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  fontFamily: 'TideFont',
                ),
              ),
              const SizedBox(height: 8),
              ...options.map(
                (option) => ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  title: Text(
                    option,
                    style: TextStyle(
                      color: theme.textStrong,
                      fontFamily: 'TideFont',
                    ),
                  ),
                  trailing: option == value
                      ? Icon(Icons.check_rounded, color: theme.primary)
                      : null,
                  onTap: () => Navigator.pop(context, option),
                ),
              ),
            ],
          ),
        );
        if (picked != null) onPick(picked);
      },
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: theme.surfaceVariant,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            if (icon != null) ...[icon, const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: theme.textWeak,
                      fontSize: 11,
                      fontFamily: 'TideFont',
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.textStrong,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.expand_more_rounded, color: theme.iconMuted),
          ],
        ),
      ),
    );
  }

  Widget _settingSwitch({
    required TideTheme theme,
    required String title,
    String? help,
    required bool value,
    required ValueChanged<bool> onChanged,
    Widget? child,
  }) => Column(
    children: [
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Row(
          children: [
            Text(title, style: const TextStyle(fontFamily: 'TideFont')),
            if (help != null)
              IconButton(
                icon: Icon(
                  Icons.help_outline_rounded,
                  size: 18,
                  color: theme.textWeak,
                ),
                tooltip: '说明',
                onPressed: () => TideDialogs.show(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: theme.surface,
                    title: Text(
                      title,
                      style: TextStyle(
                        color: theme.textStrong,
                        fontFamily: 'TideFont',
                      ),
                    ),
                    content: Text(
                      help,
                      style: TextStyle(
                        color: theme.textWeak,
                        fontFamily: 'TideFont',
                        height: 1.5,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text(
                          '知道了',
                          style: TextStyle(fontFamily: 'TideFont'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        value: value,
        activeThumbColor: theme.primary,
        onChanged: onChanged,
      ),
      if (child != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: child,
        ),
    ],
  );

  InputDecoration _roundInput(
    TideTheme theme, {
    required String label,
    Widget? icon,
  }) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: theme.border),
    );
    return InputDecoration(
      isDense: true,
      labelText: label,
      prefixIcon: icon,
      filled: true,
      fillColor: theme.surfaceVariant,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: theme.primary, width: 1.5),
      ),
      border: border,
    );
  }

  Widget _replyDelayRange(TideTheme theme) => Row(
    children: [
      Expanded(
        child: TextField(
          contextMenuBuilder: androidTextContextMenu,
          controller: _replyDelayMinController,
          keyboardType: TextInputType.number,
          style: TextStyle(color: theme.textStrong, fontFamily: 'TideFont'),
          decoration: _roundInput(theme, label: '最短（秒）'),
          onChanged: (value) {
            final n = int.tryParse(value);
            final max = int.tryParse(_replyDelayMaxController.text) ?? 2;
            if (n != null && n >= 0 && n <= max && n <= 60) {
              _save('random_reply_delay_min_seconds', '$n');
            }
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          '至',
          style: TextStyle(color: theme.textWeak, fontFamily: 'TideFont'),
        ),
      ),
      Expanded(
        child: TextField(
          contextMenuBuilder: androidTextContextMenu,
          controller: _replyDelayMaxController,
          keyboardType: TextInputType.number,
          style: TextStyle(color: theme.textStrong, fontFamily: 'TideFont'),
          decoration: _roundInput(theme, label: '最长（秒）'),
          onChanged: (value) {
            final n = int.tryParse(value);
            final min = int.tryParse(_replyDelayMinController.text) ?? 0;
            if (n != null && n >= min && n <= 60) {
              _save('random_reply_delay_max_seconds', '$n');
            }
          },
        ),
      ),
    ],
  );

  Widget _compactRange(TideTheme theme) => Row(
    children: [
      Expanded(
        child: TextField(
          contextMenuBuilder: androidTextContextMenu,
          controller: _proactiveMinController,
          keyboardType: TextInputType.number,
          style: TextStyle(color: theme.textStrong, fontFamily: 'TideFont'),
          decoration: _roundInput(theme, label: '最短（分钟）'),
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null && n >= 1 && n <= _proactiveMax) {
              _proactiveMin = n;
              _save('proactive_min_minutes', '$n');
            }
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          '至',
          style: TextStyle(color: theme.textWeak, fontFamily: 'TideFont'),
        ),
      ),
      Expanded(
        child: TextField(
          contextMenuBuilder: androidTextContextMenu,
          controller: _proactiveMaxController,
          keyboardType: TextInputType.number,
          style: TextStyle(color: theme.textStrong, fontFamily: 'TideFont'),
          decoration: _roundInput(theme, label: '最长（分钟）'),
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null && n >= _proactiveMin && n <= 1440) {
              _proactiveMax = n;
              _save('proactive_max_minutes', '$n');
            }
          },
        ),
      ),
    ],
  );

  Future<void> _manageLifePools() async {
    final current = await LifeScheduleService.instance.pools();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LifeSchedulePoolPage(initialPools: current),
      ),
    );
  }

  Widget _compactPostsPerDay(TideTheme theme) => TextField(
    contextMenuBuilder: androidTextContextMenu,
    controller: _botPostsPerDayController,
    keyboardType: TextInputType.number,
    style: TextStyle(color: theme.textStrong, fontFamily: 'TideFont'),
    decoration: _roundInput(
      theme,
      label: '每个机器人每天发布数量（1–10）',
      icon: Icon(Icons.dynamic_feed_rounded, color: theme.primary, size: 19),
    ),
    onChanged: (v) {
      final n = int.tryParse(v);
      if (n != null && n >= 1 && n <= 10) _save('bot_posts_per_day', '$n');
    },
  );

  Widget _compactSpeed(TideTheme theme) => TextField(
    contextMenuBuilder: androidTextContextMenu,
    controller: _streamSpeedController,
    keyboardType: TextInputType.number,
    style: TextStyle(color: theme.textStrong, fontFamily: 'TideFont'),
    decoration: _roundInput(
      theme,
      label: '显示速度（1–100）',
      icon: Icon(Icons.speed_rounded, color: theme.primary, size: 19),
    ),
    onChanged: (v) {
      final n = int.tryParse(v);
      if (n != null && n >= 1 && n <= 100) {
        _speed = n;
        _save('streaming_speed', '$n');
      }
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('普通设置', style: TextStyle(fontFamily: 'TideFont')),
          backgroundColor: theme.isWechat
              ? theme.wechatBar
              : Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: ListView(
          padding: theme.isWechat
              ? const EdgeInsets.only(bottom: 32)
              : const EdgeInsets.fromLTRB(12, 8, 12, 32),
          children: [
            _sectionHeader(theme, '对话表现', Icons.forum_outlined),
            FrostCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _settingSwitch(
                    theme: theme,
                    title: '显示消息发送时间',
                    value: _showTime,
                    onChanged: (v) {
                      setState(() => _showTime = v);
                      _save('show_message_time', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '聊天界面显示头像',
                    value: _showAvatar,
                    onChanged: (v) {
                      setState(() => _showAvatar = v);
                      _save('show_chat_avatar', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '括号内字体变灰',
                    value: _dimParentheticalText,
                    onChanged: (v) {
                      setState(() => _dimParentheticalText = v);
                      _save('dim_parenthetical_text', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '现实时间感知',
                    help: '发送请求时，在末尾附注现实时间；稳定人设提示保持不变，以提升缓存命中率。',
                    value: _timeAwareness,
                    onChanged: (v) {
                      setState(() => _timeAwareness = v);
                      _save('time_awareness', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '内心独白',
                    help: '默认开启。机器人回复时会先显示一个可折叠的内心独白气泡，展现真实的思考过程和情感状态。',
                    value: _innerThought,
                    onChanged: (v) {
                      setState(() => _innerThought = v);
                      _save('inner_thought_enabled', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '适时沉默',
                    help: '默认开启。模型会在自然结束、明确无需回复等安全情境自行调用沉默工具；关闭后不会提供该工具。',
                    value: _adaptiveSilence,
                    onChanged: (v) {
                      setState(() => _adaptiveSilence = v);
                      _save('adaptive_silence_enabled', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '分段回复',
                    help: '默认开启。模型回复会按自然句逐段呈现，让聊天节奏更接近真人。',
                    value: _segmentedReply,
                    onChanged: (v) {
                      setState(() => _segmentedReply = v);
                      _save('segmented_reply_enabled', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '随机延迟回复',
                    help: '开启后，模型生成完成及每一段后续消息都会在下方秒数范围内随机等待。',
                    value: _randomReplyDelay,
                    onChanged: (v) {
                      setState(() => _randomReplyDelay = v);
                      _save('random_reply_delay_enabled', '$v');
                    },
                    child: _randomReplyDelay ? _replyDelayRange(theme) : null,
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '流式输出',
                    help: '按设定速度逐字呈现每段回复，不受提供商返回速度或流式支持影响。',
                    value: _streaming,
                    onChanged: (v) {
                      setState(() => _streaming = v);
                      _save('streaming_output', '$v');
                    },
                    child: _streaming ? _compactSpeed(theme) : null,
                  ),
                ],
              ),
            ),
            _sectionHeader(theme, '主动与智能', Icons.auto_awesome_outlined),
            FrostCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _settingSwitch(
                    theme: theme,
                    title: '主动回复',
                    help: '应用保持运行时，机器人会在连续沉默达到下方随机区间后尝试自然开启话题。',
                    value: _proactiveReply,
                    onChanged: (v) {
                      setState(() => _proactiveReply = v);
                      _save('proactive_reply', '$v');
                    },
                    child: _proactiveReply ? _compactRange(theme) : null,
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '联网搜索',
                    help: '仅开启后机器人才能按需搜索实时信息。填写对应搜索服务商 API Key 后可用。',
                    value: _webSearch,
                    onChanged: (v) {
                      setState(() => _webSearch = v);
                      _save('web_search_enabled', '$v');
                    },
                    child: _webSearch
                        ? Column(
                            children: [
                              _settingSwitch(
                                theme: theme,
                                title: '显示联网搜索消息来源',
                                help:
                                    '默认隐藏。开启后，仅在使用搜索的消息底部显示一个来源图标；点击图标会在浏览器打开最终使用的网页。',
                                value: _showSearchSources,
                                onChanged: (v) {
                                  setState(() => _showSearchSources = v);
                                  _save('show_web_search_sources', '$v');
                                },
                              ),
                              _choiceField(
                                theme: theme,
                                label: '搜索服务商',
                                value: _searchProvider,
                                options: const [
                                  'Tavily',
                                  'DeepSeek',
                                  '博查 Bocha',
                                  'Serper',
                                  'Brave Search',
                                  'Bing Web Search',
                                ],
                                icon: Icon(
                                  Icons.travel_explore_rounded,
                                  color: theme.primary,
                                ),
                                onPick: (value) {
                                  setState(() => _searchProvider = value);
                                  _save('web_search_provider', value);
                                },
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                contextMenuBuilder: androidTextContextMenu,
                                controller: _searchKeyController,
                                obscureText: !_showSearchKey,
                                style: TextStyle(
                                  color: theme.textStrong,
                                  fontFamily: 'TideFont',
                                ),
                                decoration:
                                    _roundInput(
                                      theme,
                                      label: _searchKeyLabel(theme),
                                      icon: Icon(
                                        Icons.key_rounded,
                                        color: theme.primary,
                                      ),
                                    ).copyWith(
                                      suffixIcon: IconButton(
                                        tooltip: _showSearchKey
                                            ? '隐藏 API Key'
                                            : '显示 API Key',
                                        onPressed: () => setState(
                                          () =>
                                              _showSearchKey = !_showSearchKey,
                                        ),
                                        icon: Icon(
                                          _showSearchKey
                                              ? Icons.visibility_off_rounded
                                              : Icons.visibility_rounded,
                                          color: theme.textWeak,
                                        ),
                                      ),
                                    ),
                                onChanged: (value) =>
                                    _save('web_search_api_key', value.trim()),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _searchKeyHint,
                                style: TextStyle(
                                  color: theme.textWeak,
                                  fontSize: 11,
                                  fontFamily: 'TideFont',
                                  height: 1.5,
                                ),
                              ),
                            ],
                          )
                        : null,
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '机器人生图',
                    help: '开启后机器人可在需要生成图片时使用生图能力，并遵循下方默认风格。关闭后机器人不会感知此工具存在。',
                    value: _imageGeneration,
                    onChanged: (v) {
                      setState(() => _imageGeneration = v);
                      _save('bot_image_generation_enabled', '$v');
                    },
                    child: _imageGeneration
                        ? Column(
                            children: [
                              ListTile(
                                leading: const Icon(
                                  Icons.add_photo_alternate_outlined,
                                ),
                                title: const Text('参考图设置'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const BotReferenceImagesPage(),
                                  ),
                                ),
                              ),
                              _choiceField(
                                theme: theme,
                                label: '默认生图风格',
                                value: _imageStyle,
                                options: const ['写实', '动漫', '科幻', '不选择', '自定义'],
                                icon: Icon(
                                  Icons.palette_outlined,
                                  color: theme.primary,
                                ),
                                onPick: (value) async {
                                  if (value == '自定义') {
                                    final controller = TextEditingController(
                                      text: _imageStyle == '自定义'
                                          ? ''
                                          : _imageStyle,
                                    );
                                    final custom = await TideDialogs.show<String>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        backgroundColor: Colors.transparent,
                                        contentPadding: EdgeInsets.zero,
                                        content: TideDialogs.glassContent(
                                          context: ctx,
                                          children: [
                                            const Text(
                                              '自定义生图风格',
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w700,
                                                fontFamily: 'TideFont',
                                              ),
                                            ),
                                            const SizedBox(height: 12),
                                            TextField(
                                              contextMenuBuilder:
                                                  androidTextContextMenu,
                                              controller: controller,
                                              autofocus: true,
                                              decoration: const InputDecoration(
                                                hintText: '例如：水彩插画、赛博朋克、胶片摄影',
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child:
                                                      TideDialogs.glassButton(
                                                        '取消',
                                                        onTap: () =>
                                                            Navigator.pop(ctx),
                                                      ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child:
                                                      TideDialogs.glassButton(
                                                        '保存',
                                                        onTap: () =>
                                                            Navigator.pop(
                                                              ctx,
                                                              controller.text
                                                                  .trim(),
                                                            ),
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                    controller.dispose();
                                    if (custom == null || custom.isEmpty)
                                      return;
                                    if (!mounted) return;
                                    setState(() => _imageStyle = custom);
                                    _save('bot_image_style', custom);
                                    return;
                                  }
                                  setState(() => _imageStyle = value);
                                  _save('bot_image_style', value);
                                },
                              ),
                            ],
                          )
                        : null,
                  ),
                ],
              ),
            ),
            _sectionHeader(theme, '机器人互动', Icons.emoji_emotions_outlined),
            FrostCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _settingSwitch(
                    theme: theme,
                    title: '通话情绪语音',
                    help:
                        '默认开启。机器人根据每轮对话自动生成细致的情绪、重音、停顿和语气变化，无需选择情绪或强度；语音与文字输入均生效，保持原音色。效果取决于语音模型。',
                    value: _callEmotionalVoice,
                    onChanged: (v) {
                      setState(() => _callEmotionalVoice = v);
                      _save('call_emotional_voice', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '语音回复',
                    help: '默认关闭。命中概率时，机器人会尝试生成语音；失败时仍只显示原文本。',
                    value: _voiceReply,
                    onChanged: (v) {
                      setState(() => _voiceReply = v);
                      _save('voice_reply_enabled', '$v');
                    },
                    child: _voiceReply
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                            child: TextField(
                              contextMenuBuilder: androidTextContextMenu,
                              controller: _voiceReplyChanceController,
                              keyboardType: TextInputType.number,
                              style: TextStyle(
                                color: theme.textStrong,
                                fontFamily: 'TideFont',
                              ),
                              decoration: _roundInput(
                                theme,
                                label: '随机语音回复概率（1–100）',
                                icon: Icon(
                                  Icons.record_voice_over_rounded,
                                  color: theme.primary,
                                ),
                              ),
                              onChanged: (value) {
                                final chance = int.tryParse(value);
                                if (chance != null &&
                                    chance >= 1 &&
                                    chance <= 100) {
                                  _voiceReplyChance = chance;
                                  _save('voice_reply_chance', '$chance');
                                }
                              },
                            ),
                          )
                        : null,
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '机器人发送表情包',
                    help: '仅从你自己维护的素材池中选择。概率用于建议发送，机器人可自主决定发送或不发送。关闭后不提供表情包工具。',
                    value: _stickers,
                    onChanged: (v) {
                      setState(() => _stickers = v);
                      _save('bot_stickers_enabled', '$v');
                    },
                    child: _stickers
                        ? Column(
                            children: [
                              TextField(
                                contextMenuBuilder: androidTextContextMenu,
                                controller: _stickerChanceController,
                                keyboardType: TextInputType.number,
                                style: TextStyle(
                                  color: theme.textStrong,
                                  fontFamily: 'TideFont',
                                ),
                                decoration: _roundInput(
                                  theme,
                                  label: '建议发送概率（1–100）',
                                  icon: Icon(
                                    Icons.sentiment_satisfied_alt_rounded,
                                    color: theme.primary,
                                  ),
                                ),
                                onChanged: (value) {
                                  final chance = int.tryParse(value);
                                  if (chance != null &&
                                      chance >= 1 &&
                                      chance <= 100) {
                                    _stickerChance = chance;
                                    _save('bot_sticker_chance', '$chance');
                                  }
                                },
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  icon: const Icon(
                                    Icons.add_photo_alternate_outlined,
                                  ),
                                  label: const Text(
                                    '添加和管理表情包',
                                    style: TextStyle(fontFamily: 'TideFont'),
                                  ),
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          const StickerManagerPage(),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : null,
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: 'AI军师辅助',
                    help: '开启后，每次聊天会先判断意图、风险和回复策略，再交给机器人按自己的人设回复。会额外消耗一次模型请求。',
                    value: _jarvis,
                    onChanged: (v) async {
                      if (v) {
                        final ok = await TideDialogs.show<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: Colors.transparent,
                            contentPadding: EdgeInsets.zero,
                            content: TideDialogs.glassContent(
                              context: ctx,
                              children: [
                                Text(
                                  '开启 AI军师辅助',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'TideFont',
                                    color: TideTheme.of(ctx).textStrong,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '本功能开启后会消耗更多的 token，确认开启吗',
                                  style: TextStyle(
                                    fontFamily: 'TideFont',
                                    height: 1.5,
                                    color: TideTheme.of(ctx).textStrong,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TideDialogs.glassButton(
                                        '取消',
                                        onTap: () => Navigator.pop(ctx, false),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TideDialogs.glassButton(
                                        '继续',
                                        onTap: () => Navigator.pop(ctx, true),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                        if (ok != true) return;
                      }
                      setState(() => _jarvis = v);
                      await _save('jarvis_enabled', '$v');
                    },
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '拟人化日程',
                    help:
                        '默认开启。每位机器人会在当天首次打开应用时按各自模型生成生活状态；日程仅在聊天和生图时作为内部背景使用。',
                    value: _lifeSchedule,
                    onChanged: (v) {
                      setState(() => _lifeSchedule = v);
                      _save('life_schedule_enabled', '$v');
                    },
                    child: _lifeSchedule
                        ? SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.tune_rounded),
                              label: const Text(
                                '管理日程池',
                                style: TextStyle(fontFamily: 'TideFont'),
                              ),
                              onPressed: _manageLifePools,
                            ),
                          )
                        : null,
                  ),
                  _settingSwitch(
                    theme: theme,
                    title: '机器人发布动态',
                    help: '开启后，每位已配置聊天模型的机器人会在进入广场时按设置数量生成独立动态，并按日期去重。',
                    value: _botPosts,
                    onChanged: (v) {
                      setState(() => _botPosts = v);
                      _save('bot_posts_enabled', '$v');
                    },
                    child: _botPosts
                        ? Column(
                            children: [
                              _compactPostsPerDay(theme),
                              _settingSwitch(
                                theme: theme,
                                title: '随机发布带图动态',
                                help: '默认关闭。命中概率后会使用已授权的生图模型；生成失败时照常发布纯文本。',
                                value: _botPostsWithImages,
                                onChanged: (v) {
                                  setState(() => _botPostsWithImages = v);
                                  _save('bot_posts_with_images', '$v');
                                },
                                child: _botPostsWithImages
                                    ? TextField(
                                        contextMenuBuilder:
                                            androidTextContextMenu,
                                        controller:
                                            _botPostsImageChanceController,
                                        keyboardType: TextInputType.number,
                                        decoration: _roundInput(
                                          theme,
                                          label: '带图概率（1–100）',
                                          icon: Icon(
                                            Icons.image_rounded,
                                            color: theme.primary,
                                          ),
                                        ),
                                        onChanged: (value) {
                                          final chance = int.tryParse(value);
                                          if (chance != null &&
                                              chance >= 1 &&
                                              chance <= 100) {
                                            _save(
                                              'bot_posts_image_chance',
                                              '$chance',
                                            );
                                          }
                                        },
                                      )
                                    : null,
                              ),
                            ],
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(TideTheme theme, String title, IconData icon) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: theme.primary),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                color: theme.textStrong,
                fontWeight: FontWeight.w700,
                fontSize: 14,
                fontFamily: 'TideFont',
              ),
            ),
          ],
        ),
      );
}

class NotificationSettingsPage extends StatefulWidget {
  final bool initialUnread;
  final bool initialKeepRunning;

  const NotificationSettingsPage({
    super.key,
    required this.initialUnread,
    required this.initialKeepRunning,
  });

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  late bool _unread;
  late bool _keepRunning;
  bool _switchingPersistentNotification = false;

  @override
  void initState() {
    super.initState();
    _unread = widget.initialUnread;
    _keepRunning = widget.initialKeepRunning;
  }

  Future<void> _setValue(String key, bool value) async {
    await DBManager().insertKV(key, value.toString());
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('通知管理', style: TextStyle(fontFamily: 'TideFont')),
          backgroundColor: theme.isWechat
              ? theme.wechatBar
              : Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: ListView(
          padding: theme.isWechat
              ? const EdgeInsets.only(bottom: 32)
              : const EdgeInsets.fromLTRB(12, 8, 12, 32),
          children: [
            FrostCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text(
                      '机器人未读消息通知',
                      style: TextStyle(fontFamily: 'TideFont'),
                    ),
                    subtitle: const Text(
                      'APP 不在前台时提醒',
                      style: TextStyle(fontFamily: 'TideFont', fontSize: 12),
                    ),
                    value: _unread,
                    activeThumbColor: theme.primary,
                    onChanged: (value) async {
                      if (value &&
                          !await AppPermissions.notifications(context)) {
                        return;
                      }
                      setState(() => _unread = value);
                      await _setValue('unread_notifications', value);
                    },
                  ),
                  SwitchListTile(
                    title: const Text(
                      'TideBot 正在运行中',
                      style: TextStyle(fontFamily: 'TideFont'),
                    ),
                    subtitle: const Text(
                      '开启后显示持久化状态通知',
                      style: TextStyle(fontFamily: 'TideFont', fontSize: 12),
                    ),
                    value: _keepRunning,
                    activeThumbColor: theme.primary,
                    onChanged: _switchingPersistentNotification
                        ? null
                        : (value) async {
                            if (value &&
                                !await AppPermissions.notifications(context)) {
                              return;
                            }
                            if (!mounted) return;
                            setState(
                              () => _switchingPersistentNotification = true,
                            );
                            try {
                              await PersistentServiceCoordinator.instance
                                  .setEnabled(value);
                              if (!mounted) return;
                              setState(() => _keepRunning = value);
                            } catch (e) {
                              if (!mounted) return;
                              GlobalNotice.show(
                                '无法切换运行通知：$e',
                                color: Theme.of(context).colorScheme.error,
                              );
                            } finally {
                              if (mounted) {
                                setState(
                                  () =>
                                      _switchingPersistentNotification = false,
                                );
                              }
                            }
                          },
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

class ApiSettingsPage extends StatefulWidget {
  const ApiSettingsPage({super.key});
  @override
  State<ApiSettingsPage> createState() => _ApiSettingsPageState();
}

class _ApiSettingsPageState extends State<ApiSettingsPage> {
  List<Map<String, dynamic>> _providers = [];
  List<Map<String, dynamic>> _sttProviders = [];
  List<Map<String, dynamic>> _ttsProviders = [];
  bool _loading = true;
  final Map<String, List<String>> _modelListCache = {};
  final _presets = [
    {
      'name': 'MiniMax',
      'key_url': 'https://platform.minimaxi.com/',
      'url': 'https://api.minimax.cn/v1',
      'models': 'MiniMax-M3.1-Flash',
    },
    {
      'name': 'DeepSeek',
      'key_url': 'https://platform.deepseek.com/api_keys',
      'url': 'https://api.deepseek.com/v1',
      'models': 'deepseek-chat',
    },
    {
      'name': 'SiliconFlow',
      'key_url': 'https://cloud.siliconflow.cn/account/ak',
      'url': 'https://api.siliconflow.cn/v1',
      'models': 'Qwen/Qwen2.5-7B-Instruct',
    },
    {
      'name': '阿里云百炼',
      'key_url': 'https://bailian.console.aliyun.com/',
      'url': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'models': 'qwen-plus',
    },
    {
      'name': 'Mimo',
      'key_url': 'https://platform.xiaomimimo.com/',
      'url': 'https://api.xiaomimimo.com/v1',
      'models': 'mimo-v2-flash',
    },
    {
      'name': 'Kimi',
      'key_url': 'https://platform.moonshot.cn/',
      'url': 'https://api.moonshot.cn/v1',
      'models': 'moonshot-v1-8k',
    },
    {
      'name': 'Gitee AI',
      'key_url': 'https://ai.gitee.com/',
      'url': 'https://ai.gitee.com/v1',
      'models': 'Qwen2.5-7B-Instruct',
    },
  ];
  final _sttPresets = [
    {
      'name': 'SiliconFlow STT',
      'key_url': 'https://cloud.siliconflow.cn/account/ak',
      'url': 'https://api.siliconflow.cn/v1',
      'models': 'FunAudioLLM/SenseVoiceSmall',
      'protocol': 'openai',
    },
    {
      'name': 'MiMo STT',
      'key_url': 'https://platform.xiaomimimo.com/',
      'url': 'https://api.xiaomimimo.com/v1',
      'models': 'mimo-v2.5-asr',
      'protocol': 'mimo',
    },
    {
      'name': 'MiniMax STT',
      'key_url': 'https://platform.minimaxi.com/',
      // MiniMax does not publish an official ASR endpoint in its current API
      // reference. Keep this as an editable OpenAI-compatible preset instead
      // of sending a fabricated request to an unrelated legacy endpoint.
      'url': 'https://api.minimax.chat/v1',
      'models': 'speech-01',
      'protocol': 'unsupported',
    },
  ];
  final _ttsPresets = [
    {
      'name': 'SiliconFlow TTS',
      'key_url': 'https://cloud.siliconflow.cn/account/ak',
      'url': 'https://api.siliconflow.cn/v1',
      'models': 'FunAudioLLM/CosyVoice2-0.5B',
      'voice': 'default',
      'protocol': 'openai',
    },
    {
      'name': 'MiMo TTS',
      'key_url': 'https://platform.xiaomimimo.com/',
      'url': 'https://api.xiaomimimo.com/v1/chat/completions',
      'models': 'mimo-v2.5-tts',
      'voice': 'default',
      'protocol': 'mimo',
    },
    {
      'name': 'MiniMax TTS',
      'key_url': 'https://platform.minimaxi.com/',
      'url': 'https://api.minimax.cn/v1',
      'models': 'speech-02-turbo',
      'voice': 'male-qn-qingse',
      'protocol': 'minimax',
    },
  ];
  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final db = DBManager();
    final raw = await db.getKV('provider_list');
    final sttRaw = await db.getKV('stt_provider_list');
    final ttsRaw = await db.getKV('tts_provider_list');
    List<Map<String, dynamic>> list = [];
    List<Map<String, dynamic>> sttList = [];
    List<Map<String, dynamic>> ttsList = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List;
        list = decoded.map((e) => e as Map<String, dynamic>).toList();
      } catch (_) {}
    }
    if (sttRaw != null && sttRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(sttRaw) as List;
        sttList = decoded
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (_) {}
    }
    if (ttsRaw != null && ttsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(ttsRaw) as List;
        ttsList = decoded.map((e) => e as Map<String, dynamic>).toList();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _providers = list;
        _sttProviders = sttList;
        _ttsProviders = ttsList;
        _loading = false;
      });
    }
  }

  Future<void> _saveList() async {
    for (var i = 0; i < _providers.length; i++) {
      _providers[i]['id'] ??=
          'provider_${DateTime.now().microsecondsSinceEpoch}_$i';
    }
    await DBManager().insertKV('provider_list', jsonEncode(_providers));
    for (var i = 0; i < _sttProviders.length; i++) {
      _sttProviders[i]['id'] ??=
          'stt_${DateTime.now().microsecondsSinceEpoch}_$i';
    }
    await DBManager().insertKV('stt_provider_list', jsonEncode(_sttProviders));
    for (var i = 0; i < _ttsProviders.length; i++) {
      _ttsProviders[i]['id'] ??=
          'tts_${DateTime.now().microsecondsSinceEpoch}_$i';
    }
    await DBManager().insertKV('tts_provider_list', jsonEncode(_ttsProviders));
    if (mounted) {
      GlobalNotice.show('已保存', color: TideTheme.of(context).primary);
      TideHaptics.confirm();
    }
  }

  void _addProvider() {
    showTideSheet(
      context: context,
      height: 520,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const Text(
                '新增模型提供商',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'TideFont',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _presets
                    .map(
                      (p) => BouncyTap(
                        onTap: () {
                          Navigator.pop(context);
                          _showAddDialog(
                            p['name']!,
                            p['url']!,
                            '',
                            p['models']!,
                            false,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: TideTheme.of(context).surfaceVariant,
                          ),
                          child: Text(
                            p['name']!,
                            style: TextStyle(
                              fontSize: 13,
                              color: TideTheme.of(context).textStrong,
                              fontFamily: 'TideFont',
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              BouncyTap(
                onTap: () {
                  Navigator.pop(context);
                  _showAddDialog('自定义', '', '', '', false);
                },
                child: Container(
                  width: double.infinity,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: TideTheme.of(context).primary),
                  ),
                  child: Center(
                    child: Text(
                      '自定义',
                      style: TextStyle(
                        fontSize: 15,
                        color: TideTheme.of(context).primary,
                        fontFamily: 'TideFont',
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '语音识别 (STT)',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'TideFont',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _sttPresets
                    .map(
                      (p) => BouncyTap(
                        onTap: () {
                          Navigator.pop(context);
                          _showSttDialog(
                            p['name']!,
                            p['url']!,
                            '',
                            p['models']!,
                            protocol: p['protocol']!,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: TideTheme.of(context).surfaceVariant,
                          ),
                          child: Text(
                            p['name']!,
                            style: TextStyle(
                              fontSize: 13,
                              color: TideTheme.of(context).textStrong,
                              fontFamily: 'TideFont',
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              BouncyTap(
                onTap: () {
                  Navigator.pop(context);
                  _showSttDialog('自定义 STT', '', '', '');
                },
                child: Container(
                  width: double.infinity,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: TideTheme.of(context).primary),
                  ),
                  child: Center(
                    child: Text(
                      '添加 STT 提供商',
                      style: TextStyle(
                        fontSize: 15,
                        color: TideTheme.of(context).primary,
                        fontFamily: 'TideFont',
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '文本转语音 (TTS)',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'TideFont',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _ttsPresets
                    .map(
                      (p) => BouncyTap(
                        onTap: () {
                          Navigator.pop(context);
                          _showTtsDialog(
                            p['name']!,
                            p['url']!,
                            '',
                            p['models']!,
                            p['voice']!,
                            protocol: p['protocol']!,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: TideTheme.of(context).surfaceVariant,
                          ),
                          child: Text(
                            p['name']!,
                            style: TextStyle(
                              fontSize: 13,
                              color: TideTheme.of(context).textStrong,
                              fontFamily: 'TideFont',
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              BouncyTap(
                onTap: () {
                  Navigator.pop(context);
                  _showTtsDialog('自定义', '', '', '', '');
                },
                child: Container(
                  width: double.infinity,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: TideTheme.of(context).primary),
                  ),
                  child: Center(
                    child: Text(
                      '自定义 TTS',
                      style: TextStyle(
                        fontSize: 15,
                        color: TideTheme.of(context).primary,
                        fontFamily: 'TideFont',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddDialog(
    String name,
    String url,
    String key,
    String models,
    bool isTts,
  ) {
    final preset = _findPreset(name, url);
    final nCtrl = TextEditingController(text: name);
    final uCtrl = TextEditingController(text: url);
    final kCtrl = TextEditingController(text: key);
    final mCtrl = TextEditingController(text: models);
    var thinkingMode = false;
    var reasoningEffort = 'medium';
    TideDialogs.show(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          maxWidth: 0.9,
          children: [
            Text(
              isTts ? '添加 TTS' : '添加提供商',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 12),
            _f('名称', nCtrl),
            const SizedBox(height: 8),
            _f('API 地址', uCtrl),
            const SizedBox(height: 8),
            _f('API Key', kCtrl, obscure: true, keyUrl: preset?['key_url']),
            const SizedBox(height: 8),
            _modelField(ctx, mCtrl, uCtrl, kCtrl),
            if (!isTts)
              StatefulBuilder(
                builder: (settingContext, updateSetting) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('思考模式'),
                      value: thinkingMode,
                      onChanged: (value) =>
                          updateSetting(() => thinkingMode = value),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: thinkingMode
                          ? ReasoningControl(
                              value: reasoningEffort,
                              onChanged: (value) =>
                                  updateSetting(() => reasoningEffort = value),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TideDialogs.glassButton(
                    '取消',
                    onTap: () => Navigator.pop(ctx),
                    color: TideTheme.of(context).buttonSecondary,
                    textColor: TideTheme.of(context).textStrong,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TideDialogs.glassButton(
                    '添加',
                    onTap: () {
                      final raw = mCtrl.text.trim();
                      // 只允许一个模型：若含逗号/换行等多值分隔，取第一个并提示
                      String model = raw;
                      if (raw.contains(',') || raw.contains('，')) {
                        final parts = raw.split(RegExp('[，,]'));
                        if (parts.isNotEmpty) model = parts.first.trim();
                        GlobalNotice.show(
                          '只能填一个模型，已按「$model」保存',
                          color: const Color(0xFFE74C3C),
                        );
                        TideHaptics.warning();
                      }
                      setState(() {
                        final p = {
                          'name': nCtrl.text.trim(),
                          'preset_name': preset?['name'],
                          'is_custom': preset == null,
                          'url': uCtrl.text.trim(),
                          'key': kCtrl.text.trim(),
                          'model': model,
                          'thinking_mode': thinkingMode,
                          'reasoning_effort': reasoningEffort,
                          'id':
                              'provider_${DateTime.now().microsecondsSinceEpoch}',
                        };
                        _providers.add(p);
                      });
                      Navigator.pop(ctx);
                      _saveList();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSttDialog(
    String name,
    String url,
    String key,
    String model, {
    String protocol = 'openai',
  }) {
    final preset = _findPreset(name, url);
    final nCtrl = TextEditingController(text: name);
    final uCtrl = TextEditingController(text: url);
    final kCtrl = TextEditingController(text: key);
    final mCtrl = TextEditingController(text: model);
    TideDialogs.show(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          maxWidth: 0.9,
          children: [
            const Text(
              '添加 STT 提供商',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 12),
            _f('名称', nCtrl),
            const SizedBox(height: 8),
            _f('API 地址', uCtrl),
            const SizedBox(height: 8),
            _f('API Key', kCtrl, obscure: true, keyUrl: preset?['key_url']),
            const SizedBox(height: 8),
            _modelField(ctx, mCtrl, uCtrl, kCtrl),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TideDialogs.glassButton(
                    '取消',
                    onTap: () => Navigator.pop(ctx),
                    color: TideTheme.of(context).buttonSecondary,
                    textColor: TideTheme.of(context).textStrong,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TideDialogs.glassButton(
                    '添加',
                    onTap: () {
                      if (uCtrl.text.trim().isEmpty ||
                          kCtrl.text.trim().isEmpty ||
                          mCtrl.text.trim().isEmpty) {
                        GlobalNotice.show('请填写 API 地址、Key 和 STT 模型');
                        return;
                      }
                      setState(
                        () => _sttProviders.add({
                          'name': nCtrl.text.trim(),
                          'preset_name': preset?['name'],
                          'is_custom': preset == null,
                          'url': uCtrl.text.trim(),
                          'key': kCtrl.text.trim(),
                          'model': mCtrl.text.trim(),
                          'protocol': protocol,
                          'id': 'stt_${DateTime.now().microsecondsSinceEpoch}',
                        }),
                      );
                      Navigator.pop(ctx);
                      _saveList();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mimoVoiceField(
    BuildContext ctx,
    TextEditingController voice,
    TextEditingController model,
    TextEditingController url,
    TextEditingController key,
    Map<String, dynamic>? Function() current,
    void Function(Map<String, dynamic>) apply,
  ) {
    return _f(
      '音色',
      voice,
      trailing: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: TideTheme.of(ctx).primary,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: () async {
          final result = await Navigator.of(ctx, rootNavigator: true)
              .push<Map<String, dynamic>>(
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => MimoVoiceWorkbench(
                    initial: current(),
                    model: model.text,
                    fetchModels: (workbenchContext, modelController) =>
                        _showModelPicker(
                          workbenchContext,
                          url,
                          key,
                          modelController,
                        ),
                  ),
                ),
              );
          if (!ctx.mounted || result == null) return;
          apply(result);
          model.text = result['model'] as String;
          voice.text = mimoCloneVoice;
        },
        child: const Text('MiMo 音色克隆工作台', style: TextStyle(fontSize: 12)),
      ),
    );
  }

  void _showTtsDialog(
    String name,
    String url,
    String key,
    String models,
    String voice, {
    String protocol = 'openai',
  }) {
    final preset = _findPreset(name, url);
    final nCtrl = TextEditingController(text: name);
    final uCtrl = TextEditingController(text: url);
    final kCtrl = TextEditingController(text: key);
    final mCtrl = TextEditingController(text: models);
    final vCtrl = TextEditingController(text: voice);
    Map<String, dynamic>? clone;
    final nativeInstructions = protocol == 'mimo' || protocol == 'minimax';
    var supportsInstructions = nativeInstructions;
    TideDialogs.show(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          maxWidth: 0.9,
          children: [
            const Text(
              '添加 TTS 提供商',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 12),
            _f('名称', nCtrl),
            const SizedBox(height: 8),
            _f('API 地址', uCtrl),
            const SizedBox(height: 8),
            _f('API Key', kCtrl, obscure: true, keyUrl: preset?['key_url']),
            const SizedBox(height: 8),
            _modelField(ctx, mCtrl, uCtrl, kCtrl),
            const SizedBox(height: 8),
            if (protocol == 'mimo')
              _mimoVoiceField(
                ctx,
                vCtrl,
                mCtrl,
                uCtrl,
                kCtrl,
                () => clone,
                (value) => clone = value,
              )
            else
              _f('音色', vCtrl),
            const SizedBox(height: 8),
            StatefulBuilder(
              builder: (context, update) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeThumbColor: TideTheme.of(context).primary,
                title: const Text('支持语气指令'),
                value: supportsInstructions,
                onChanged: nativeInstructions
                    ? null
                    : (v) => update(() => supportsInstructions = v),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TideDialogs.glassButton(
                    '取消',
                    onTap: () => Navigator.pop(ctx),
                    color: TideTheme.of(context).buttonSecondary,
                    textColor: TideTheme.of(context).textStrong,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TideDialogs.glassButton(
                    '添加',
                    onTap: () {
                      if (isMimoClone(protocol, vCtrl.text) && clone == null) {
                        GlobalNotice.show('请先在 MiMo 音色克隆工作台应用参考音频');
                        return;
                      }
                      String model = mCtrl.text.trim();
                      if (model.contains(',') || model.contains('，')) {
                        final parts = model.split(RegExp('[，,]'));
                        if (parts.isNotEmpty) model = parts.first.trim();
                        GlobalNotice.show(
                          '只能填一个模型，已按「$model」保存',
                          color: const Color(0xFFE74C3C),
                        );
                        TideHaptics.warning();
                      }
                      setState(() {
                        final p = {
                          'name': nCtrl.text.trim(),
                          'preset_name': preset?['name'],
                          'is_custom': preset == null,
                          'url': uCtrl.text.trim(),
                          'key': kCtrl.text.trim(),
                          'model': model,
                          'voice': vCtrl.text.trim(),
                          if (clone != null) 'mimo_clone': clone,
                          'protocol': protocol,
                          'supports_instructions': supportsInstructions,
                          'id': 'tts_${DateTime.now().microsecondsSinceEpoch}',
                        };
                        _ttsProviders.add(p);
                      });
                      Navigator.pop(ctx);
                      _saveList();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<List<String>> _fetchProviderModels({
    required String baseUrl,
    required String apiKey,
  }) async {
    final root = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final normalizedRoot = root
        .replaceFirst(RegExp(r'/chat/completions/?$'), '')
        .replaceFirst(RegExp(r'/audio/speech/?$'), '');
    if (normalizedRoot.isEmpty) throw Exception('请先填写 API Base URL');
    if (apiKey.trim().isEmpty) throw Exception('请先填写 API Key');
    final cacheKey = '$normalizedRoot|${apiKey.trim()}';
    final cached = _modelListCache[cacheKey];
    if (cached != null && cached.isNotEmpty) return List<String>.from(cached);
    final candidates = <String>[normalizedRoot];
    if (root.contains('compatible-mode/v1')) {
      candidates.add(root.replaceFirst('/compatible-mode/v1', ''));
    }
    Object? lastError;
    for (final candidate in candidates.toSet()) {
      try {
        final response = await http
            .get(
              Uri.parse('$candidate/models'),
              headers: {
                'Authorization': 'Bearer ${apiKey.trim()}',
                if (Uri.parse(candidate).host == 'api.xiaomimimo.com')
                  'api-key': apiKey.trim(),
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 75));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (response.statusCode == 429 || response.statusCode >= 500) {
            final retryAfter =
                int.tryParse(response.headers['retry-after']?.trim() ?? '') ??
                0;
            await Future<void>.delayed(
              Duration(seconds: retryAfter.clamp(1, 15)),
            );
          }
          lastError = 'HTTP ${response.statusCode}';
          continue;
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final rows = decoded is Map
            ? (decoded['data'] ?? decoded['models'] ?? decoded['output'])
            : decoded;
        final list = rows is List
            ? rows
            : (rows is Map ? (rows['data'] ?? rows['models']) : null);
        if (list is List) {
          final models =
              list
                  .map((item) {
                    if (item is String) return item.trim();
                    if (item is Map)
                      return (item['id'] ?? item['name'] ?? item['model'] ?? '')
                          .toString()
                          .trim();
                    return '';
                  })
                  .where((id) => id.isNotEmpty)
                  .toSet()
                  .toList()
                ..sort();
          if (models.isNotEmpty) return models;
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception('获取模型失败：${lastError ?? '未知错误'}');
  }

  Future<void> _showModelPicker(
    BuildContext dialogContext,
    TextEditingController urlCtrl,
    TextEditingController keyCtrl,
    TextEditingController modelCtrl,
  ) async {
    FocusScope.of(dialogContext).unfocus();
    final searchCtrl = TextEditingController();
    List<String> models = [];
    String? error;
    var loading = true;
    var loadStarted = false;
    await TideDialogs.show<void>(
      context: dialogContext,
      builder: (pickerContext) => StatefulBuilder(
        builder: (pickerContext, setPickerState) {
          Future<void> load() async {
            if (loading && loadStarted) return;
            loadStarted = true;
            setPickerState(() {
              loading = true;
              error = null;
            });
            Object? lastError;
            for (var attempt = 0; attempt < 3; attempt++) {
              try {
                final result = await _fetchProviderModels(
                  baseUrl: urlCtrl.text,
                  apiKey: keyCtrl.text,
                );
                if (!pickerContext.mounted) return;
                setPickerState(() {
                  models = result;
                  loading = false;
                });
                return;
              } catch (e) {
                lastError = e;
                if (attempt < 2) {
                  await Future<void>.delayed(
                    Duration(seconds: 2 * (attempt + 1)),
                  );
                }
              }
            }
            if (!pickerContext.mounted) return;
            setPickerState(() {
              error = lastError.toString();
              loading = false;
            });
          }

          if (loading && models.isEmpty && error == null && !loadStarted) {
            WidgetsBinding.instance.addPostFrameCallback((_) => load());
          }
          final query = searchCtrl.text.trim().toLowerCase();
          final visible = query.isEmpty
              ? models
              : models.where((m) => m.toLowerCase().contains(query)).toList();
          final theme = TideTheme.of(pickerContext);
          return AlertDialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 24,
            ),
            contentPadding: EdgeInsets.zero,
            content: Container(
              width: 420,
              constraints: const BoxConstraints(maxWidth: 460),
              decoration: BoxDecoration(
                color: theme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.primary.withValues(alpha: .18)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: theme.primary.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.memory_rounded,
                            color: theme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '选择模型',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'TideFont',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(pickerContext),
                          icon: Icon(
                            Icons.close_rounded,
                            color: theme.iconMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: theme.textFaint.withValues(alpha: .2),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                    child: TextField(
                      contextMenuBuilder: androidTextContextMenu,
                      controller: searchCtrl,
                      onChanged: (_) => setPickerState(() {}),
                      autofocus: false,
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.textStrong,
                        fontFamily: 'TideFont',
                      ),
                      decoration: InputDecoration(
                        hintText: '搜索已获取的模型',
                        hintStyle: TextStyle(
                          color: theme.textFaint,
                          fontFamily: 'TideFont',
                        ),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          color: theme.iconMuted,
                        ),
                        filled: true,
                        fillColor: theme.surfaceVariant,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    height: 300,
                    margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    decoration: BoxDecoration(
                      color: theme.surfaceVariant.withValues(alpha: .55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: loading
                        ? Center(
                            child: CircularProgressIndicator(
                              color: theme.primary,
                            ),
                          )
                        : error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.cloud_off_rounded,
                                    size: 30,
                                    color: theme.textWeak,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    '获取模型失败',
                                    style: TextStyle(
                                      color: theme.textStrong,
                                      fontFamily: 'TideFont',
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    error!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.textWeak,
                                      fontFamily: 'TideFont',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      loadStarted = false;
                                      load();
                                    },
                                    icon: const Icon(
                                      Icons.refresh_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('重试'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : visible.isEmpty
                        ? Center(
                            child: Text(
                              '没有匹配的模型',
                              style: TextStyle(
                                color: theme.textWeak,
                                fontFamily: 'TideFont',
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: visible.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              indent: 14,
                              endIndent: 14,
                              color: theme.textFaint.withValues(alpha: .16),
                            ),
                            itemBuilder: (_, index) => ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: Icon(
                                Icons.auto_awesome_rounded,
                                size: 18,
                                color: theme.primary,
                              ),
                              title: Text(
                                visible[index],
                                style: TextStyle(
                                  fontSize: 14,
                                  color: theme.textStrong,
                                  fontFamily: 'TideFont',
                                ),
                              ),
                              trailing: modelCtrl.text == visible[index]
                                  ? Icon(
                                      Icons.check_circle_rounded,
                                      size: 18,
                                      color: theme.primary,
                                    )
                                  : null,
                              onTap: () {
                                modelCtrl.text = visible[index];
                                Navigator.pop(pickerContext);
                              },
                            ),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Row(
                      children: [
                        Text(
                          '${visible.length} 个模型',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.textWeak,
                            fontFamily: 'TideFont',
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: loading
                              ? null
                              : () {
                                  loadStarted = false;
                                  load();
                                },
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('刷新'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    searchCtrl.dispose();
  }

  Widget _modelField(
    BuildContext dialogContext,
    TextEditingController modelCtrl,
    TextEditingController urlCtrl,
    TextEditingController keyCtrl,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '模型名（可手动输入或获取后选择）',
          style: TextStyle(
            fontSize: 13,
            color: TideTheme.of(dialogContext).textWeak,
            fontFamily: 'TideFont',
          ),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: TideTheme.of(dialogContext).surfaceVariant,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  contextMenuBuilder: androidTextContextMenu,
                  controller: modelCtrl,
                  style: const TextStyle(fontSize: 14, fontFamily: 'TideFont'),
                  decoration: const InputDecoration(
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _showModelPicker(
                  dialogContext,
                  urlCtrl,
                  keyCtrl,
                  modelCtrl,
                ),
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('获取'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Iterable<Map<String, String>> get _allProviderPresets => [
    ..._presets,
    ..._sttPresets,
    ..._ttsPresets,
  ];

  Map<String, String>? _findPreset(String name, String url) {
    for (final preset in _allProviderPresets) {
      if (preset['name'] == name && preset['url'] == url) return preset;
    }
    return null;
  }

  String? _providerKeyUrl(Map<String, dynamic> provider) {
    if (provider['is_custom'] == true) return null;
    final presetName = provider['preset_name'];
    if (presetName != null) {
      for (final preset in _allProviderPresets) {
        if (preset['name'] == presetName) return preset['key_url'];
      }
      return null;
    }
    // Older records predate preset identity; require both original name and URL.
    return _findPreset(
      provider['name']?.toString() ?? '',
      provider['url']?.toString() ?? '',
    )?['key_url'];
  }

  Future<void> _openKeyPlatform(String url) async {
    try {
      if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication))
        return;
    } catch (_) {
      // Report a missing browser or platform launch failure without closing the form.
    }
    if (mounted) GlobalNotice.show('无法打开开放平台，请检查是否安装浏览器后重试');
  }

  Widget _f(
    String label,
    TextEditingController c, {
    bool obscure = false,
    String? keyUrl,
    Widget? trailing,
  }) {
    // Keep this outside the builder: declaring it inside rebuilds resets the
    // field to hidden before the eye button state can be painted.
    var hidden = obscure;
    return StatefulBuilder(
      builder: (context, setFieldState) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: TideTheme.of(context).textWeak,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ),
                if (trailing != null) trailing,
                if (keyUrl != null)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: TideTheme.of(context).primary,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _openKeyPlatform(keyUrl),
                    child: const Text(
                      '没有APIkey?去获取',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: TideTheme.of(context).surfaceVariant,
              ),
              child: TextField(
                contextMenuBuilder: androidTextContextMenu,
                controller: c,
                obscureText: hidden,
                style: const TextStyle(fontSize: 14, fontFamily: 'TideFont'),
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: InputBorder.none,
                  suffixIcon: obscure
                      ? IconButton(
                          tooltip: hidden ? '显示 API Key' : '隐藏 API Key',
                          icon: Icon(
                            hidden
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () =>
                              setFieldState(() => hidden = !hidden),
                        )
                      : null,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _editProvider(Map<String, dynamic> p, {bool isStt = false}) {
    final nCtrl = TextEditingController(text: p['name']);
    final uCtrl = TextEditingController(text: p['url']);
    final kCtrl = TextEditingController(text: p['key']);
    final mCtrl = TextEditingController(text: p['model']);
    var thinkingMode = p['thinking_mode'] == true;
    var reasoningEffort =
        [
          'low',
          'medium',
          'high',
          'xhigh',
          'max',
        ].contains(p['reasoning_effort'])
        ? p['reasoning_effort'].toString()
        : 'medium';
    final hasVoice = p.containsKey('voice');
    final nativeInstructions =
        p['protocol'] == 'mimo' || p['protocol'] == 'minimax';
    var supportsInstructions =
        nativeInstructions || p['supports_instructions'] == true;
    Map<String, dynamic>? clone = p['mimo_clone'] is Map
        ? Map<String, dynamic>.from(p['mimo_clone'] as Map)
        : null;
    final vCtrl = TextEditingController(text: p['voice']?.toString() ?? '');
    final isDashScope =
        hasVoice &&
        (p['name']?.toString().contains('百炼') == true ||
            p['url']?.toString().contains('dashscope.aliyuncs.com') == true);
    TideDialogs.show(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          maxWidth: 0.9,
          children: [
            Text(
              '编辑${isStt ? ' STT' : (hasVoice ? ' TTS' : '')}提供商',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 12),
            _f('名称', nCtrl),
            if (!isDashScope) ...[
              const SizedBox(height: 8),
              _f('API 地址', uCtrl),
            ],
            const SizedBox(height: 8),
            _f('API Key', kCtrl, obscure: true, keyUrl: _providerKeyUrl(p)),
            const SizedBox(height: 8),
            _modelField(ctx, mCtrl, uCtrl, kCtrl),
            if (!isStt && !hasVoice)
              StatefulBuilder(
                builder: (settingContext, updateSetting) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('思考模式'),
                      value: thinkingMode,
                      onChanged: (value) =>
                          updateSetting(() => thinkingMode = value),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: thinkingMode
                          ? ReasoningControl(
                              value: reasoningEffort,
                              onChanged: (value) =>
                                  updateSetting(() => reasoningEffort = value),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            if (hasVoice) ...[
              const SizedBox(height: 8),
              if (p['protocol'] == 'mimo')
                _mimoVoiceField(
                  ctx,
                  vCtrl,
                  mCtrl,
                  uCtrl,
                  kCtrl,
                  () => clone,
                  (value) => clone = value,
                )
              else
                _f('音色', vCtrl),
              StatefulBuilder(
                builder: (context, update) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: TideTheme.of(context).primary,
                  title: const Text('支持语气指令'),
                  value: supportsInstructions,
                  onChanged: nativeInstructions
                      ? null
                      : (value) => update(() => supportsInstructions = value),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TideDialogs.glassButton(
                    '取消',
                    onTap: () => Navigator.pop(ctx),
                    color: TideTheme.of(context).buttonSecondary,
                    textColor: TideTheme.of(context).textStrong,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TideDialogs.glassButton(
                    '保存',
                    onTap: () {
                      if (isMimoClone(
                            p['protocol']?.toString() ?? '',
                            vCtrl.text,
                          ) &&
                          clone == null) {
                        GlobalNotice.show('请先在 MiMo 音色克隆工作台应用参考音频');
                        return;
                      }
                      if (!p.containsKey('is_custom')) {
                        final preset = _findPreset(
                          p['name']?.toString() ?? '',
                          p['url']?.toString() ?? '',
                        );
                        p['preset_name'] = preset?['name'];
                        p['is_custom'] = preset == null;
                      }
                      p['name'] = nCtrl.text.trim();
                      p['url'] = uCtrl.text.trim();
                      p['key'] = kCtrl.text.trim();
                      p['model'] = mCtrl.text.trim();
                      if (!isStt && !hasVoice) {
                        p['thinking_mode'] = thinkingMode;
                        p['reasoning_effort'] = reasoningEffort;
                      }
                      if (hasVoice) {
                        p['voice'] = vCtrl.text.trim();
                        p['supports_instructions'] = supportsInstructions;
                      }
                      if (clone != null) p['mimo_clone'] = clone;
                      Navigator.pop(ctx);
                      _saveList();
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _deleteProvider(int idx, {bool isTts = false, bool isStt = false}) {
    final collection = isStt
        ? _sttProviders
        : (isTts ? _ttsProviders : _providers);
    final name = collection[idx]['name'];
    TideDialogs.show(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          maxWidth: 0.85,
          children: [
            Text(
              '删除${isStt ? 'STT' : (isTts ? 'TTS' : '')}提供商',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '确定删除「$name」吗？',
              style: const TextStyle(fontSize: 14, fontFamily: 'TideFont'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TideDialogs.glassButton(
                    '取消',
                    onTap: () => Navigator.pop(ctx),
                    color: TideTheme.of(context).buttonSecondary,
                    textColor: TideTheme.of(context).textStrong,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TideDialogs.glassButton(
                    '删除',
                    onTap: () {
                      setState(() {
                        if (isStt) {
                          _sttProviders.removeAt(idx);
                        } else if (isTts) {
                          _ttsProviders.removeAt(idx);
                        } else {
                          _providers.removeAt(idx);
                        }
                      });
                      Navigator.pop(ctx);
                      _saveList();
                    },
                    color: const Color(0xFFE74C3C),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _testProvider(Map<String, dynamic> p) async {
    GlobalNotice.show('测试中');
    try {
      final result = await AIManager().testProviderCapabilities(
        p['url']?.toString() ?? '',
        p['key']?.toString() ?? '',
        p['model']?.toString() ?? '',
      );
      if (result['passed'] == true) {
        final latency = result['fastest_latency'];
        GlobalNotice.show(
          '测试通过${latency is num ? '，延迟 ${latency.toInt()}ms' : ''}',
          color: const Color(0xFF34C759),
        );
      } else {
        GlobalNotice.show(
          '测试失败：${result['error'] ?? '聊天模型未返回有效正文'}',
          color: const Color(0xFFE74C3C),
        );
      }
    } catch (_) {
      GlobalNotice.show('测试失败', color: const Color(0xFFE74C3C));
    }
  }

  Future<void> _testTtsProvider(Map<String, dynamic> p) async {
    GlobalNotice.show('测试中');
    final started = DateTime.now();
    try {
      final path = await AIManager().generateTTS(
        '你好',
        p['id']?.toString() ?? '',
      );
      if (path != null && path.isNotEmpty) {
        GlobalNotice.show(
          '测试通过，延迟 ${DateTime.now().difference(started).inMilliseconds}ms',
          color: const Color(0xFF34C759),
        );
      } else {
        GlobalNotice.show(
          '测试失败，请查看开发日志中的 HTTP 响应',
          color: const Color(0xFFE74C3C),
        );
      }
    } catch (_) {
      GlobalNotice.show(
        '测试失败，请查看开发日志中的 HTTP 响应',
        color: const Color(0xFFE74C3C),
      );
    }
  }

  Future<void> _testSttProvider(Map<String, dynamic> p) async {
    GlobalNotice.show('正在发送 STT 真实测试请求');
    final started = DateTime.now();
    try {
      final path = await AIManager().createSttProbeAudio();
      final text = await AIManager().transcribeWithProvider(p, path);
      if (text != null && text.isNotEmpty) {
        GlobalNotice.show(
          '测试通过，延迟 ${DateTime.now().difference(started).inMilliseconds}ms',
          color: const Color(0xFF34C759),
        );
      } else {
        GlobalNotice.show(
          '测试失败，请查看开发日志中的 HTTP 响应',
          color: const Color(0xFFE74C3C),
        );
      }
    } catch (_) {
      GlobalNotice.show(
        '测试失败，请查看开发日志中的 HTTP 响应',
        color: const Color(0xFFE74C3C),
      );
    }
  }

  @override
  Widget build(BuildContext context) => TideBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text(
          'API 设置',
          style: TextStyle(fontWeight: FontWeight.w600, fontFamily: 'TideFont'),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.add_circle_outline_rounded,
              color: TideTheme.of(context).primary,
              size: 26,
            ),
            onPressed: _addProvider,
          ),
        ],
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                color: TideTheme.of(context).primary,
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_providers.isEmpty &&
                      _sttProviders.isEmpty &&
                      _ttsProviders.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 80),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.api_rounded,
                              size: 60,
                              color: Color(0xFFC7C7CC),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '还没有添加任何模型提供商',
                              style: TextStyle(
                                fontSize: 15,
                                color: TideTheme.of(context).textWeak,
                                fontFamily: 'TideFont',
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '点击右上角 + 添加',
                              style: TextStyle(
                                fontSize: 13,
                                color: TideTheme.of(context).textFaint,
                                fontFamily: 'TideFont',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_providers.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Text(
                        'AI 模型',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'TideFont',
                          color: TideTheme.of(context).textStrong,
                        ),
                      ),
                    ),
                    ...List.generate(_providers.length, (i) {
                      final p = _providers[i];
                      return BouncyTap(
                        onTap: () => _editProvider(p),
                        child: FrostCard(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      p['name'] ?? '',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'TideFont',
                                      ),
                                    ),
                                  ),
                                  BouncyTap(
                                    onTap: () => _testProvider(p),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        color: TideTheme.of(
                                          context,
                                        ).primary.withValues(alpha: 0.15),
                                      ),
                                      child: Text(
                                        '测试',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: TideTheme.of(context).primary,
                                          fontFamily: 'TideFont',
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  BouncyTap(
                                    onTap: () => _deleteProvider(i),
                                    child: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 20,
                                      color: Color(0xFFE74C3C),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                p['url'] ?? '',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: TideTheme.of(context).textWeak,
                                  fontFamily: 'TideFont',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if ((p['model'] ?? '').toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '模型: ${p['model']}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: TideTheme.of(context).textFaint,
                                      fontFamily: 'TideFont',
                                    ),
                                  ),
                                ),
                              if ((p['key'] ?? '').toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    'Key: ${(p['key'] as String).length < 8 ? p['key'] : (p['key'] as String).substring(0, 8)}...',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: TideTheme.of(context).textFaint,
                                      fontFamily: 'TideFont',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                  if (_sttProviders.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 8),
                      child: Text(
                        '语音识别 (STT)',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'TideFont',
                          color: TideTheme.of(context).textStrong,
                        ),
                      ),
                    ),
                    ...List.generate(_sttProviders.length, (i) {
                      final p = _sttProviders[i];
                      return BouncyTap(
                        onTap: () => _editProvider(p, isStt: true),
                        child: FrostCard(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      p['name']?.toString() ?? '',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'TideFont',
                                      ),
                                    ),
                                  ),
                                  BouncyTap(
                                    onTap: () => _testSttProvider(p),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        color: TideTheme.of(
                                          context,
                                        ).primary.withValues(alpha: 0.15),
                                      ),
                                      child: Text(
                                        '测试',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: TideTheme.of(context).primary,
                                          fontFamily: 'TideFont',
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  BouncyTap(
                                    onTap: () =>
                                        _deleteProvider(i, isStt: true),
                                    child: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 20,
                                      color: Color(0xFFE74C3C),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                p['url']?.toString() ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: TideTheme.of(context).textWeak,
                                  fontFamily: 'TideFont',
                                ),
                              ),
                              if ((p['model'] ?? '').toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '模型: ${p['model']}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: TideTheme.of(context).textFaint,
                                      fontFamily: 'TideFont',
                                    ),
                                  ),
                                ),
                              if ((p['key'] ?? '').toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    'Key: ${(p['key'] as String).length < 8 ? p['key'] : (p['key'] as String).substring(0, 8)}...',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: TideTheme.of(context).textFaint,
                                      fontFamily: 'TideFont',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                  if (_ttsProviders.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 8),
                      child: Text(
                        'TTS 语音',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'TideFont',
                          color: TideTheme.of(context).textStrong,
                        ),
                      ),
                    ),
                    ...List.generate(_ttsProviders.length, (i) {
                      final p = _ttsProviders[i];
                      return BouncyTap(
                        onTap: () => _editProvider(p),
                        child: FrostCard(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      p['name'] ?? '',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'TideFont',
                                      ),
                                    ),
                                  ),
                                  BouncyTap(
                                    onTap: () => _testTtsProvider(p),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        color: TideTheme.of(
                                          context,
                                        ).primary.withValues(alpha: 0.15),
                                      ),
                                      child: Text(
                                        '测试',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: TideTheme.of(context).primary,
                                          fontFamily: 'TideFont',
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  BouncyTap(
                                    onTap: () =>
                                        _deleteProvider(i, isTts: true),
                                    child: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 20,
                                      color: Color(0xFFE74C3C),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                p['url'] ?? '',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: TideTheme.of(context).textWeak,
                                  fontFamily: 'TideFont',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if ((p['model'] ?? '').toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '模型: ${p['model']}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: TideTheme.of(context).textFaint,
                                      fontFamily: 'TideFont',
                                    ),
                                  ),
                                ),
                              if ((p['voice'] ?? '').toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '音色: ${p['voice']}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: TideTheme.of(context).textFaint,
                                      fontFamily: 'TideFont',
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
    ),
  );
}
