import 'internet_reachability_monitor.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'daily_quote_service.dart';
import 'db.dart';
import 'theme.dart';
import 'ui_components.dart';

class ChatSidebarController extends ChangeNotifier {
  AnimationController? _animation;
  bool _open = false;
  bool _dragActive = false;
  Map<String, dynamic>? bot;

  bool get isOpen => _open;
  bool get dragActive => _dragActive;
  Animation<double>? get progress => _animation;

  void attach(TickerProvider vsync) {
    _animation ??= AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 220),
    )..addListener(notifyListeners);
  }

  void updateBot(Map<String, dynamic>? value) {
    bot = value;
    notifyListeners();
  }

  void open() {
    if (_open) return;
    _open = true;
    notifyListeners();
    _animation?.forward(from: 0);
  }

  Future<void> close() async {
    if (!_open) return;
    await _animation?.reverse();
    _open = false;
    _dragActive = false;
    notifyListeners();
  }

  void beginDrag() {
    _dragActive = true;
    if (!_open) {
      _open = true;
      notifyListeners();
    }
  }

  void updateDrag(double deltaDx, double width) {
    if (!_dragActive || _animation == null || width <= 0) return;
    _animation!.value = (_animation!.value + deltaDx / width).clamp(0.0, 1.0);
  }

  void endDrag(double velocity) {
    if (!_dragActive) return;
    _dragActive = false;
    if (velocity > 500 || (velocity > -500 && (_animation?.value ?? 0) >= .5)) {
      _animation?.forward();
      _open = true;
      notifyListeners();
    } else {
      unawaited(close());
    }
  }

  @override
  void dispose() {
    _animation?.dispose();
    super.dispose();
  }
}

class ChatSidebar extends StatefulWidget {
  final Map<String, dynamic>? bot;
  final Animation<double> progress;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final VoidCallback onClose;
  final ValueChanged<String> onOpenManager;

  const ChatSidebar({
    super.key,
    required this.bot,
    required this.progress,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onClose,
    required this.onOpenManager,
  });

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends State<ChatSidebar> {
  final DBManager _db = DBManager();
  Map<String, dynamic> get _bot => widget.bot ?? const {};
  Map<String, dynamic>? _latestPost;
  String _userName = '用户';
  String _userAvatar = '';
  String _quote = '';
  Timer? _clock;
  DateTime _now = DateTime.now();
  bool? _online;
  StreamSubscription<bool>? _reachabilitySubscription;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _online = InternetReachabilityMonitor.instance.online;
    _reachabilitySubscription =
        InternetReachabilityMonitor.instance.changes.listen((online) {
      if (mounted) setState(() => _online = online);
    });
    _load();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void didUpdateWidget(covariant ChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bot?['id'] != widget.bot?['id']) {
      _latestPost = null;
      _quote = '';
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final bot = _bot;
    final botId = bot['id']?.toString() ?? '';
    final results = await Future.wait([
      botId.isEmpty
          ? Future.value(<Map<String, dynamic>>[])
          : _db.queryPostsForBot(
              botId: botId,
              botName: bot['name']?.toString() ?? '',
              limit: 1,
            ),
      _db.getKV('user_name'),
      _db.getKV('user_avatar'),
    ]);
    final now = DateTime.now();
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _latestPost = (results[0] as List<Map<String, dynamic>>).firstOrNull;
      _userName = (results[1] as String?)?.trim().isNotEmpty == true
          ? results[1] as String
          : '用户';
      _userAvatar = results[2] as String? ?? '';
      _now = now;
    });
    if (botId.isEmpty) return;
    unawaited(
      DailyQuoteService.instance.get(botId).then((quote) {
        if (!mounted || generation != _loadGeneration || quote.trim().isEmpty)
          return;
        setState(() => _quote = quote);
      }).catchError((_) {}),
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    unawaited(_reachabilitySubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final bot = _bot;
    final width = MediaQuery.sizeOf(context).width * .86;
    return AnimatedBuilder(
      animation: widget.progress,
      builder: (context, child) {
        final progress = widget.progress.value;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onClose,
                onHorizontalDragUpdate: widget.onDragUpdate,
                onHorizontalDragEnd: widget.onDragEnd,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .30 * progress),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(-width * (1 - progress), 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Material(
                  color: theme.surface,
                  child: SafeArea(
                    right: false,
                    child: SizedBox(
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _header(theme),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                              children: [
                                _timeCard(theme),
                                const SizedBox(height: 12),
                                if (bot['id']?.toString().isNotEmpty ==
                                    true) ...[
                                  _statusCard(theme, bot),
                                  const SizedBox(height: 12),
                                  _postCard(theme, bot),
                                ] else
                                  _panel(
                                    theme,
                                    const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 16,
                                      ),
                                      child: Text(
                                        '暂无机器人',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _managerButton(
                                        theme,
                                        Icons.extension_rounded,
                                        'Skill',
                                        'skill',
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _managerButton(
                                        theme,
                                        Icons.hub_rounded,
                                        'MCP',
                                        'mcp',
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _managerButton(
                                        theme,
                                        Icons.widgets_rounded,
                                        '插件',
                                        'plugin',
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _managerButton(
                                        theme,
                                        Icons.palette_rounded,
                                        '主题',
                                        'theme',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomLeft,
                            child: IconButton(
                              tooltip: theme.isDark ? '切换到日间模式' : '切换到夜间模式',
                              onPressed: () => theme.cycleMode(),
                              icon: Icon(
                                theme.isDark
                                    ? Icons.light_mode_rounded
                                    : Icons.dark_mode_rounded,
                                color: theme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(TideTheme theme) {
    final avatar = _userAvatar.isNotEmpty && File(_userAvatar).existsSync()
        ? FileImage(File(_userAvatar))
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 25,
            backgroundColor: theme.primary.withValues(alpha: .15),
            backgroundImage: avatar,
            child: avatar == null
                ? Icon(Icons.person_rounded, color: theme.primary)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: theme.textStrong,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: 8,
                      color: _online == true
                          ? const Color(0xFF34C759)
                          : theme.iconMuted,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _online == null ? '检测中' : (_online! ? '在线' : '离线'),
                      style: TextStyle(fontSize: 12, color: theme.textWeak),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: widget.onClose,
            tooltip: '关闭',
            icon: Icon(Icons.close_rounded, color: theme.iconMuted),
          ),
        ],
      ),
    );
  }

  Widget _timeCard(TideTheme theme) => _panel(
        theme,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            Text(
              '${_now.year}年${_now.month}月${_now.day}日  ${_weekday(_now.weekday)}',
              style: const TextStyle(color: Color(0xDFFFFFFF)),
            ),
            if (_quote.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '“$_quote”',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: Colors.white,
                ),
              ),
            ],
          ],
        ),
      );

  Widget _statusCard(TideTheme theme, Map<String, dynamic> bot) => _panel(
        theme,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TideBotAvatar(
                  name: bot['name']?.toString() ?? 'TideBot',
                  path: bot['avatar']?.toString(),
                  size: 38,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    bot['name']?.toString() ?? 'TideBot',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: theme.textStrong,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('当前心情：${_mood(bot)}', style: TextStyle(color: theme.textWeak)),
            const SizedBox(height: 5),
            FutureBuilder<Map<String, int>>(
              future: _db.todayBotStats(bot['id']?.toString() ?? ''),
              builder: (context, snapshot) {
                final stats =
                    snapshot.data ?? const {'messages': 0, 'tokens': 0};
                return Text(
                  '今日发送 ${stats['messages']} 条  ·  ${stats['tokens']} token',
                  style: TextStyle(color: theme.textWeak),
                );
              },
            ),
          ],
        ),
      );

  Widget _postCard(TideTheme theme, Map<String, dynamic> bot) => _panel(
        theme,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '最新动态 —— ${bot['name']?.toString() ?? 'TideBot'}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: theme.textStrong,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _latestPost?['content']?.toString().trim().isNotEmpty == true
                  ? _latestPost!['content'].toString()
                  : '还没有新的动态',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(height: 1.4, color: theme.textWeak),
            ),
          ],
        ),
      );

  Widget _managerButton(
    TideTheme theme,
    IconData icon,
    String label,
    String? id,
  ) =>
      BouncyTap(
        onTap: () {
          if (id != null) widget.onOpenManager(id);
        },
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: theme.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: theme.primary, width: 1.5),
          ),
          child: Row(
            children: [
              Icon(icon, color: theme.primary),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: theme.textStrong,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Icon(Icons.chevron_right_rounded, color: theme.iconMuted),
            ],
          ),
        ),
      );

  Widget _panel(TideTheme theme, Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.primary,
          borderRadius: BorderRadius.circular(20),
        ),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white),
          child: IconTheme.merge(
            data: const IconThemeData(color: Colors.white),
            child: child,
          ),
        ),
      );

  String _mood(Map<String, dynamic> bot) =>
      bot['mood']?.toString().trim().isNotEmpty == true
          ? bot['mood'].toString()
          : '平静';
  String _weekday(int day) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day - 1];
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
