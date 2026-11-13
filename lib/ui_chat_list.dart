import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'chat_event_bus.dart';
import 'chat_protocol.dart';
import 'message_delivery_service.dart';
import 'db.dart';
import 'global_notice.dart';
import 'ui_components.dart';
import 'chat_sidebar.dart';
import 'ui_chat_room.dart';
import 'theme.dart';
import 'wechat_theme_widgets.dart';
import 'ui_create_bot.dart';
import 'bot_state.dart';

class ChatListPage extends StatefulWidget {
  final GlobalKey<ChatListPageState>? pageKey;
  final ChatSidebarController? sidebar;
  const ChatListPage({super.key, this.pageKey, this.sidebar});
  @override
  State<ChatListPage> createState() => ChatListPageState();
}

class ChatListPageState extends State<ChatListPage> {
  static const _cacheKey = 'chat_list_snapshot_v1';
  static List<Map<String, dynamic>>? _lastBots;
  static String? _lastCacheJson;
  static Future<void> _cacheWrite = Future<void>.value();
  List<Map<String, dynamic>> _bots = [];
  bool _hasLoaded = false;
  bool _loadFailed = false;
  int _loadGeneration = 0;
  bool _showParticles = false;
  int _particleRun = 0;
  final List<Offset> _origins = [];
  // Keys must outlive ListView rebuilds. Creating a GlobalKey inside itemBuilder
  // makes the key detached after a previous deletion, so later particles lose
  // their source RenderBox.
  final Map<String, GlobalKey> _botCardKeys = <String, GlobalKey>{};
  final Set<String> _openingBots = <String>{};

  StreamSubscription<ChatEvent>? _chatEvents;

  @override
  void initState() {
    super.initState();
    final cached = _lastBots;
    if (cached != null) {
      _bots = cached;
      _hasLoaded = true;
      // Sidebar listeners can rebuild the parent, so notify after this build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateSidebar();
      });
    } else {
      unawaited(_restoreCachedBots());
    }
    _chatEvents = ChatEventBus.instance.events.listen((event) {
      if (!mounted || event.botId == null) return;
      load();
    });
    load();
  }

  @override
  void dispose() {
    _chatEvents?.cancel();
    super.dispose();
  }

  void _openSidebar() {
    widget.sidebar?.open();
  }

  void _updateSidebarDrag(DragUpdateDetails details) {
    final width = MediaQuery.sizeOf(context).width * .86;
    widget.sidebar?.updateDrag(details.delta.dx, width);
  }

  void _endSidebarDrag(DragEndDetails details) {
    widget.sidebar?.endDrag(details.velocity.pixelsPerSecond.dx);
  }

  Future<void> _restoreCachedBots() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final cached = decoded.map((row) {
        final bot = Map<String, dynamic>.from(row as Map);
        if (bot['id'] is! String || (bot['id'] as String).isEmpty) {
          throw const FormatException('Invalid cached bot');
        }
        return bot;
      }).toList();
      // A late disk read must never replace a fresh database result.
      if (!mounted || _hasLoaded) return;
      _lastCacheJson = raw;
      _applyBots(cached, persist: false);
    } catch (error) {
      debugPrint('[chat_list] snapshot read failed: $error');
    }
  }

  void _updateSidebar() {
    final sidebar = widget.sidebar;
    if (sidebar == null) return;
    final first = _bots.isEmpty ? null : _bots.first;
    if (!mapEquals(sidebar.bot, first)) sidebar.updateBot(first);
  }

  void _applyBots(List<Map<String, dynamic>> rows, {bool persist = true}) {
    final changed =
        !_hasLoaded ||
        _bots.length != rows.length ||
        List.generate(
          rows.length,
          (i) => i,
        ).any((i) => !mapEquals(_bots[i], rows[i]));
    void update() {
      _bots = rows;
      _hasLoaded = true;
      _loadFailed = false;
    }

    // Refreshing an identical snapshot does not rebuild cards or the sidebar.
    if (changed || (_loadFailed && _bots.isEmpty)) {
      setState(update);
    } else {
      update();
    }
    _lastBots = rows;
    _updateSidebar();
    if (!persist) return;
    try {
      final encoded = jsonEncode(rows);
      if (encoded == _lastCacheJson) return;
      _lastCacheJson = encoded;
      // Serialize writes so an older slow write cannot restore deleted cards.
      _cacheWrite = _cacheWrite
          .then((_) async {
            final prefs = await SharedPreferences.getInstance();
            if (!await prefs.setString(_cacheKey, encoded)) {
              throw StateError('Snapshot write failed');
            }
          })
          .catchError((Object error) {
            if (_lastCacheJson == encoded) _lastCacheJson = null;
            debugPrint('[chat_list] snapshot write failed: $error');
          });
    } catch (error) {
      debugPrint('[chat_list] snapshot encoding failed: $error');
    }
  }

  Future<void> load() async {
    final generation = ++_loadGeneration;
    if (mounted && _loadFailed) {
      if (_bots.isEmpty) {
        setState(() => _loadFailed = false);
      } else {
        _loadFailed = false;
      }
    }
    final db = DBManager();
    List<Map<String, dynamic>> bots;
    try {
      bots = await db.queryBots(throwOnError: true);
    } catch (error) {
      print('[chat_list] queryBots failed: $error');
      if (mounted && generation == _loadGeneration) {
        // A failed read is not an empty database. Keep the last visible cards.
        if (_bots.isEmpty) {
          setState(() => _loadFailed = true);
        } else {
          _loadFailed = true;
        }
      }
      return;
    }
    if (!mounted || generation != _loadGeneration) return;

    if (bots.isEmpty) {
      _applyBots([]);
      return;
    }

    // Show known bots before waiting for their message previews on first load.
    // Refreshes keep the existing cards until the complete replacement is ready.
    if (!_hasLoaded || _bots.isEmpty) {
      final initial = bots
          .map(
            (bot) => <String, dynamic>{
              ...bot,
              'preview': '',
              'lastTime':
                  (bot['last_msg_time'] as int?) ??
                  (bot['created_at'] as int?) ??
                  0,
              'unread': false,
            },
          )
          .toList();
      _applyBots(initial, persist: false);
    }

    final previous = {for (final bot in _bots) bot['id']: bot};
    // 并发查询所有机器人的消息预览
    final previewFutures = bots.map((b) async {
      List<Map<String, dynamic>> msgs = const [];
      try {
        msgs = await DBManager().queryMessages(
          b['id'] as String,
          limit: 30,
          descending: true,
        );
      } catch (error) {
        print('[chat_list] queryMessages failed: $error');
        final cached = previous[b['id']];
        if (cached != null) {
          return <String, dynamic>{
            ...b,
            'preview': cached['preview'],
            'lastTime': cached['lastTime'],
            'unread': cached['unread'],
          };
        }
      }
      String preview = '';
      int lastTime =
          (b['last_msg_time'] as int?) ?? (b['created_at'] as int?) ?? 0;
      if (msgs.isNotEmpty) {
        final chosen = msgs.firstWhere(
          (m) => m['type']?.toString() != 'sticker',
          orElse: () => msgs.first,
        );
        final type = chosen['type']?.toString() ?? 'text';
        preview = chatListPreview(
          type: type,
          rawContent: chosen['content']?.toString() ?? '',
        );
        if (preview.length > 25) preview = '${preview.substring(0, 25)}...';
        lastTime = msgs.first['timestamp'] as int? ?? lastTime;
      }
      final latestAssistant = msgs
          .where((message) => message['role']?.toString() == 'assistant')
          .fold<int>(0, (latest, message) {
            final timestamp = (message['timestamp'] as num?)?.toInt() ?? 0;
            return timestamp > latest ? timestamp : latest;
          });
      final lastRead = (b['last_read_at'] as num?)?.toInt() ?? 0;
      return {
        ...b,
        'preview': preview,
        'lastTime': lastTime,
        'unread': latestAssistant > lastRead,
      };
    }).toList();

    final enriched = await Future.wait(previewFutures);
    enriched.sort((a, b) {
      final aPin = (a['is_pinned'] as int?) ?? 0;
      final bPin = (b['is_pinned'] as int?) ?? 0;
      if (aPin != bPin) return bPin.compareTo(aPin);
      return (b['lastTime'] as int).compareTo(a['lastTime'] as int);
    });
    if (mounted && generation == _loadGeneration) {
      _applyBots(enriched);
    }
  }

  void _deleteBot(Map<String, dynamic> bot, GlobalKey key) async {
    final confirm = await TideDialogs.show<bool>(
      context: context,
      builder: (ctx) => TideDialogSurface(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          children: [
            const Center(
              child: Text(
                '确认删除',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'TideFont',
                ),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '确定删除「${bot['name']}」吗？\n此操作不可恢复。',
                textAlign: TextAlign.start,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF636366),
                  fontFamily: 'TideFont',
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TideDialogs.glassButton(
                    '取消',
                    onTap: () => Navigator.pop(ctx, false),
                    color: const Color(0xFFE8E8F0),
                    textColor: const Color(0xFF1C1C1E),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TideDialogs.glassButton(
                    '删除',
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
    if (confirm == true) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final pos = box.localToGlobal(Offset.zero);
        final w = box.size.width;
        final h = box.size.height;
        // 全卡片范围撒点：四角 + 中心 + 随机分布
        _origins.clear();
        for (int i = 0; i < 12; i++) {
          _origins.add(
            Offset(
              pos.dx + w * (0.1 + 0.8 * (i / 11)),
              pos.dy + h * (0.2 + 0.6 * ((i * 7) % 11) / 10),
            ),
          );
        }
        setState(() {
          // 每次删除都递增 Key，强制 ParticleOverlay 创建新的动画状态。
          _particleRun++;
          _showParticles = true;
        });
      }
      await DBManager().deleteBot(bot['id'] as String);
      load();
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _showParticles = false);
      });
    }
  }

  Future<void> _openChat(Map<String, dynamic> bot) async {
    final id = bot['id']?.toString() ?? '';
    if (id.isEmpty || !_openingBots.add(id)) return;
    if (mounted) setState(() {});
    try {
      final current = await DBManager().getBotById(id);
      if (!mounted) return;
      if (current == null) {
        await load();
        return;
      }
      await Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (c, a, s) => ChatRoomPage(botData: current),
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          transitionsBuilder: (c, a, s, child) {
            final anim = CurvedAnimation(
              parent: a,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.06),
                end: Offset.zero,
              ).animate(anim),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.98, end: 1).animate(anim),
                child: FadeTransition(opacity: anim, child: child),
              ),
            );
          },
        ),
      );
      await MessageDeliveryService.instance.markRead(id);
      if (mounted) load();
    } catch (error) {
      debugPrint('[chat_list] open chat failed: $error');
      if (mounted) GlobalNotice.show('暂时无法打开聊天，请重试');
    } finally {
      _openingBots.remove(id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    Widget content = TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          top: !theme.isWechat,
          child: Column(
            children: [
              if (theme.isWechat)
                Container(
                  height: 56 + MediaQuery.paddingOf(context).top,
                  decoration: BoxDecoration(
                    color: theme.wechatBar,
                    border: Border(
                      bottom: BorderSide(color: theme.divider, width: .5),
                    ),
                  ),
                  padding: EdgeInsets.only(
                    left: 20,
                    right: 8,
                    top: MediaQuery.paddingOf(context).top,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          button: true,
                          label: '打开 TideBot 侧栏',
                          child: GestureDetector(
                            onTap: _openSidebar,
                            child: Text(
                              'TideBot',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                                color: theme.textStrong,
                              ),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '添加机器人',
                        icon: WechatIcon(
                          kind: 'add',
                          color: theme.textStrong,
                          size: 26,
                        ),
                        onPressed: () async {
                          final result = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const CreateBotPage(),
                            ),
                          );
                          if (result == true && mounted) load();
                        },
                      ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                      button: true,
                      label: '打开 TideBot 侧栏',
                      child: GestureDetector(
                        onTap: _openSidebar,
                        child: Text(
                          'TideBot',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            fontFamily: 'TideFont',
                            color: TideTheme.of(context).textStrong,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: _bots.isEmpty && _loadFailed
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '机器人列表加载失败',
                              style: TextStyle(
                                color: TideTheme.of(context).textWeak,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TideDialogs.glassButton(
                              '重试',
                              onTap: load,
                              color: TideTheme.of(context).primary,
                            ),
                          ],
                        ),
                      )
                    : !_hasLoaded
                    ? Center(
                        child: CircularProgressIndicator(
                          color: TideTheme.of(context).primary,
                        ),
                      )
                    : _bots.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.inbox_rounded,
                              size: 50,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              '还没有机器人',
                              style: TextStyle(
                                color: Color(0xFF8E8E93),
                                fontSize: 15,
                                fontFamily: 'TideFont',
                              ),
                            ),
                            Text(
                              theme.isWechat ? '点击右上角 + 创建' : '点击右下角 + 创建',
                              style: const TextStyle(
                                color: Color(0xFFC7C7CC),
                                fontSize: 13,
                                fontFamily: 'TideFont',
                              ),
                            ),
                          ],
                        ),
                      )
                    : _list(),
              ),
            ],
          ),
        ),
      ),
    );
    if (theme.isWechat) {
      content = AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: theme.wechatBar,
          statusBarIconBrightness: theme.isDark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: theme.isDark
              ? Brightness.dark
              : Brightness.light,
        ),
        child: content,
      );
    }
    final shell = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        final sidebar = widget.sidebar;
        if (sidebar == null ||
            sidebar.isOpen ||
            details.globalPosition.dx > 28) {
          return;
        }
        sidebar.beginDrag();
      },
      onHorizontalDragUpdate: (details) {
        if (widget.sidebar?.dragActive == true) _updateSidebarDrag(details);
      },
      onHorizontalDragEnd: (details) {
        if (widget.sidebar?.dragActive == true) _endSidebarDrag(details);
      },
      child: content,
    );
    return _showParticles
        ? ParticleOverlay(
            key: ValueKey(_particleRun),
            origins: _origins,
            onDone: () {
              if (mounted) setState(() => _showParticles = false);
            },
            child: shell,
          )
        : shell;
  }

  Widget _list() => ListView.builder(
    padding: TideTheme.of(context).isWechat
        ? EdgeInsets.zero
        : const EdgeInsets.fromLTRB(16, 4, 16, 100),
    itemCount: _bots.length,
    itemBuilder: (ctx, i) {
      final bot = _bots[i];
      final id = bot['id']?.toString() ?? 'bot_$i';
      final key = _botCardKeys.putIfAbsent(id, GlobalKey.new);
      return GestureDetector(
        key: key,
        onTap: () => _openChat(bot),
        onLongPress: () => showTideSheet(
          context: context,
          height: 232,
          child: Column(
            children: [
              const SizedBox(height: 10),
              ListTile(
                leading: Icon(
                  Icons.push_pin_rounded,
                  color: TideTheme.of(context).primary,
                ),
                title: Text(
                  ((bot['is_pinned'] as int?) ?? 0) == 1 ? '取消置顶' : '置顶',
                  style: const TextStyle(fontFamily: 'TideFont'),
                ),
                onTap: () {
                  Navigator.pop(context);
                  final pin = ((bot['is_pinned'] as int?) ?? 0) == 1 ? 0 : 1;
                  DBManager().toggleBotPin(bot['id'] as String, pin);
                  load();
                },
              ),
              ListTile(
                leading: Icon(
                  (bot['is_disabled'] == 1 || bot['is_disabled'] == true)
                      ? Icons.play_circle_outline_rounded
                      : Icons.pause_circle_outline_rounded,
                  color: const Color(0xFFF39C12),
                ),
                title: Text(
                  (bot['is_disabled'] == 1 || bot['is_disabled'] == true)
                      ? '启用机器人'
                      : '禁用机器人',
                  style: const TextStyle(fontFamily: 'TideFont'),
                ),
                subtitle: const Text(
                  '禁用后机器人不会回复、执行日程或主动消息。',
                  style: TextStyle(fontFamily: 'TideFont', fontSize: 11),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  final disabled = isBotDisabled(bot['is_disabled']);
                  await DBManager().updateBot(bot['id'] as String, {
                    'is_disabled': disabled ? 0 : 1,
                  });
                  load();
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_rounded,
                  color: Color(0xFFE74C3C),
                ),
                title: const Text(
                  '删除机器人',
                  style: TextStyle(
                    fontFamily: 'TideFont',
                    color: Color(0xFFE74C3C),
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _deleteBot(bot, key);
                },
              ),
            ],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: TideTheme.of(context).isWechat ? 0 : 10,
          ),
          child: _card(bot),
        ),
      );
    },
  );

  Widget _wechatRow(Map<String, dynamic> bot) {
    final theme = TideTheme.of(context);
    final pinned = bot['is_pinned'] == 1;
    final disabled = isBotDisabled(bot['is_disabled']);
    final color = pinned ? theme.wechatBar : theme.surface;
    return Container(
      color: color,
      padding: const EdgeInsets.only(left: 16),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: TideBotAvatar(
                  name: bot['name']?.toString() ?? '',
                  path: bot['avatar']?.toString(),
                  size: 48,
                  radius: 5,
                ),
              ),
              if (bot['unread'] == true)
                Positioned(
                  right: -4,
                  top: -4,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFA5151),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 76),
              padding: const EdgeInsets.only(top: 13, bottom: 13, right: 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: theme.divider, width: .5),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bot['name']?.toString() ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            color: theme.textStrong,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          bot['preview']?.toString().isNotEmpty == true
                              ? bot['preview'].toString()
                              : '点击开始对话',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: theme.textWeak),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        fmtTime(bot['lastTime'] as int? ?? 0),
                        style: TextStyle(fontSize: 11, color: theme.textWeak),
                      ),
                      if (disabled)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Icon(
                            Icons.notifications_off_outlined,
                            size: 16,
                            color: theme.textWeak,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> bot) {
    final av = (bot['avatar'] as String?) ?? '';
    if (TideTheme.of(context).isWechat) return _wechatRow(bot);
    return GlassCard(
      liquid: true,
      padding: const EdgeInsets.all(14),
      onTap: () => _openChat(bot),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              TideBotAvatar(
                name: bot['name'] as String? ?? '',
                path: av,
                size: 56,
              ),
              if (bot['unread'] == true)
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE74C3C),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: TideTheme.of(context).bgColor,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (((bot['is_pinned'] as int?) ?? 0) == 1) ...[
                      Icon(
                        Icons.push_pin_rounded,
                        size: 14,
                        color: TideTheme.of(context).primary,
                      ),
                      const SizedBox(width: 2),
                    ],
                    if (bot['is_disabled'] == 1 ||
                        bot['is_disabled'] == true) ...[
                      const Icon(
                        Icons.pause_circle_filled_rounded,
                        size: 17,
                        color: Color(0xFFE67E22),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        bot['name'] as String? ?? '',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'TideFont',
                          color: TideTheme.of(context).textStrong,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  bot['preview'] as String? ?? '点击开始对话',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: TideTheme.of(context).textWeak,
                    fontFamily: 'TideFont',
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                fmtTime(bot['lastTime'] as int? ?? 0),
                style: TextStyle(
                  fontSize: 11,
                  color: TideTheme.of(context).textFaint,
                  fontFamily: 'TideFont',
                ),
              ),
              const SizedBox(height: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: TideTheme.of(context).textFaint,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
