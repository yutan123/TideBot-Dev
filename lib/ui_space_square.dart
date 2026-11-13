import 'user_profile_changes.dart';
import 'android_selection_menu.dart';
import 'life_schedule_service.dart';
import 'bot_image_tool.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:math';
import 'package:image_picker/image_picker.dart';
import 'app_log_service.dart';
import 'ui_components.dart';
import 'global_notice.dart';
import 'message_delivery_service.dart';
import 'db.dart';
import 'theme.dart';
import 'world_book_preview_window.dart';
import 'ai.dart';
import 'game_arena_page.dart';
import 'memory_manager_page.dart';
import 'daily_quote_service.dart';
import 'diary_calendar_page.dart';
import 'world_book_detail_page.dart';
import 'bot_vital_signs_service.dart';
import 'bot_data_page.dart';

// ==================== 空间页 ====================
class SpacePage extends StatefulWidget {
  final PageController? pageController;

  /// Uses the real space layout with example content, without loading services.
  final bool previewOnly;
  const SpacePage({super.key, this.pageController, this.previewOnly = false});
  @override
  State<SpacePage> createState() => _SpacePageState();
}

class _SpacePageState extends State<SpacePage> {
  String _botId = '';
  String _botName = '';
  String _dailyQuote = '';
  int _daysSince = 0;
  List<Map<String, dynamic>> _memories = [];
  Map<String, dynamic>? _vitalSigns;
  int _vitalCardIndex = 0;
  Timer? _vitalCardTimer;
  final ScrollController _diaryScrollController = ScrollController();
  Timer? _diaryTimer;
  int _diaryScrollIndex = 0;
  int _diaryVisibleStart = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.previewOnly) {
      _botId = 'background_preview';
      _botName = '伙伴';
      _dailyQuote = '潮起有时，陪伴无期。';
      _daysSince = 128;
      _vitalSigns = {};
      _loading = false;
    } else {
      _loadData();
    }
  }

  @override
  void dispose() {
    _diaryTimer?.cancel();
    _vitalCardTimer?.cancel();
    _diaryScrollController.dispose();
    super.dispose();
  }

  // 记忆按三条一屏循环滚动：短期在上、长期在下，短期结束后接长期再转回短期，
  // 打开空间页面即自动滚动，无需手动开启。用户点按可临时暂停/继续。
  void _startDiaryAutoScroll() {
    if (_memories.isEmpty || _diaryTimer != null) return;
    _diaryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) {
        _diaryTimer?.cancel();
        _diaryTimer = null;
        return;
      }
      // 每次前进一条，取模实现短期→长期→短期的无缝循环。
      final next = (_diaryVisibleStart + 1) % _memories.length;
      setState(() => _diaryVisibleStart = next);
    });
  }

  void _startVitalCarousel() {
    _vitalCardTimer?.cancel();
    _vitalCardIndex = Random().nextInt(6);
    _vitalCardTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() {
        var next = Random().nextInt(5);
        if (next >= _vitalCardIndex) next++;
        _vitalCardIndex = next;
      });
      unawaited(_refreshVitals());
    });
  }

  Future<void> _refreshVitals() async {
    final id = _botId;
    if (id.isEmpty) return;
    try {
      final data = await BotVitalSignsService.instance.snapshot(id);
      if (mounted && id == _botId) setState(() => _vitalSigns = data);
    } catch (e) {
      debugPrint('[vitals] refresh failed: $e');
    }
  }

  void _toggleDiaryAutoScroll() {
    if (_memories.length < 2) return;
    if (_diaryTimer != null) {
      _diaryTimer?.cancel();
      _diaryTimer = null;
      return;
    }
    _startDiaryAutoScroll();
  }

  Future<void> _loadData() async {
    final db = DBManager();
    final bots = await db.queryBots();
    if (bots.isNotEmpty) {
      // 选择跨页面/重启持久化；当机器人被删除时再安全回退到首个。
      final savedBotId = await db.getKV('space_selected_bot_id') ?? '';
      Map<String, dynamic>? b;
      final preferredId = _botId.isNotEmpty ? _botId : savedBotId;
      if (preferredId.isNotEmpty) {
        try {
          b = bots.firstWhere((x) => x['id'] == preferredId);
        } catch (_) {
          b = null;
        }
      }
      b ??= bots.first;
      _botId = b['id'] as String? ?? '';
      await db.setKV('space_selected_bot_id', _botId);
      _botName = b['name'] as String? ?? '';
      _dailyQuote = b['daily_quote'] as String? ?? '';
      final created = b['created_at'];
      final createdMillis = created is num
          ? created.toInt()
          : int.tryParse(created?.toString() ?? '');
      final metAt = createdMillis != null
          ? DateTime.fromMillisecondsSinceEpoch(createdMillis)
          : DateTime.tryParse(created?.toString() ?? '') ?? DateTime.now();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final metDate = DateTime(metAt.year, metAt.month, metAt.day);
      _daysSince = (today.difference(metDate).inDays + 1).clamp(1, 1 << 30);
      final shortMemories = await db.queryMemories(
        _botId,
        type: 'short',
        limit: 50,
      );
      final longMemories = await db.queryMemories(
        _botId,
        type: 'long',
        limit: 50,
      );
      final mem = [...shortMemories, ...longMemories];

      _vitalSigns = await BotVitalSignsService.instance.snapshot(_botId);
      // The space card reflects the same state injected into chat prompts,
      // including safe time-based fluctuations between messages.
      _memories = mem;
      if (_diaryVisibleStart >= _memories.length) _diaryVisibleStart = 0;
      if (_diaryScrollIndex >= _memories.length) _diaryScrollIndex = 0;
      final quoteBotId = _botId;
      unawaited(
        DailyQuoteService.instance
            .get(quoteBotId)
            .then((quote) {
              if (!mounted || quoteBotId != _botId || quote.trim().isEmpty)
                return;
              setState(() => _dailyQuote = quote);
            })
            .catchError((_) {}),
      );
      if (mounted) {
        setState(() {
          _loading = false;
        });
        // 打开空间页面即自动开始记忆循环滚动。
        _startDiaryAutoScroll();
        // Five-second character data carousel
        _startVitalCarousel();
      }
    } else {
      _daysSince = 0;
      _dailyQuote = '';
      _memories = [];
      _vitalSigns = null;
      _botId = '';
      _botName = '';
      if (mounted) setState(() => _loading = false);
    }
  }

  // 日程仅作为机器人内部生活状态，不在空间页直接展示。

  // ignore: unused_element
  Future<void> _openMemoryManager() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MemoryManagerPage(botId: _botId, botName: _botName),
      ),
    );
    if (mounted) _loadData();
  }

  void _showMemoryDetail(Map<String, dynamic> m) {
    final theme = TideTheme.of(context);
    showTideSheet(
      context: context,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              m['content'] ?? '',
              style: TextStyle(
                fontSize: 15,
                color: theme.textStrong,
                fontFamily: 'TideFont',
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              formatTime(m['timestamp']),
              style: TextStyle(
                fontSize: 13,
                color: theme.textFaint,
                fontFamily: 'TideFont',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 记忆窗口：从短期→长期合并列表中，取 _diaryVisibleStart 开始的 3 条（循环取模），
  // 配合 AnimatedSwitcher 做淡入滚动观感。显示不足 3 条时按实际数量铺开。
  Widget _buildDiaryWindow(TideTheme theme) => WorldBookPreviewWindow(
    memories: _memories,
    startIndex: _diaryVisibleStart,
    onSelect: _showMemoryDetail,
    formatTimestamp: formatTime,
  );

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final dateStr = '${now.year}.${now.month}.${now.day}';
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: _loading
            ? Center(child: CircularProgressIndicator(color: theme.primary))
            : SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: theme.isWechat
                    ? const EdgeInsets.fromLTRB(12, 16, 12, 32)
                    : const EdgeInsets.fromLTRB(16, 12, 16, 100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(timeStr, dateStr, theme),
                    const SizedBox(height: 20),
                    if (_botId.isNotEmpty) ...[
                      _buildQuoteCard(theme),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: _buildDaysCard(theme),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: _buildVitalCarousel(theme),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(child: _buildSectionTitle('世界书')),
                          TextButton.icon(
                            onPressed: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => WorldBookDetailPage(
                                    botId: _botId,
                                    botName: _botName,
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.menu_book_rounded, size: 16),
                            label: const Text(
                              '查看',
                              style: TextStyle(fontFamily: 'TideFont'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_memories.isEmpty)
                        Text(
                          '还没有记录',
                          style: TextStyle(
                            color: theme.textFaint,
                            fontFamily: 'TideFont',
                          ),
                        )
                      else
                        GestureDetector(
                          onTap: _toggleDiaryAutoScroll,
                          onPanDown: (_) {
                            if (_diaryTimer != null) _toggleDiaryAutoScroll();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: _buildDiaryWindow(theme),
                          ),
                        ),
                      const SizedBox(height: 24),
                      _buildSectionTitle('TA 的日记'),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 380,
                        child: DiaryCalendarWidget(
                          key: ValueKey('diary_$_botId'),
                          botId: _botId,
                          botName: _botName,
                        ),
                      ),
                    ] else
                      const FrostCard(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            '还没有创建机器人\n点击底部聊天 Tab 开始',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              color: Color(0xFF8E8E93),
                              fontFamily: 'TideFont',
                              height: 1.6,
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

  Widget _buildHeader(String time, String date, TideTheme theme) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            time,
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w300,
              fontFamily: 'TideFont',
              color: theme.textStrong,
            ),
          ),
          Text(
            date,
            style: TextStyle(
              fontSize: 14,
              color: theme.textWeak,
              fontFamily: 'TideFont',
            ),
          ),
        ],
      ),
      if (_botId.isNotEmpty)
        BouncyTap(
          onTap: () async {
            final db = DBManager();
            final bots = await db.queryBots();
            if (!mounted) return;
            showTideSheet(
              context: context,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  const Text(
                    '切换机器人',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'TideFont',
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...bots.map(
                    (b) => Column(
                      children: [
                        ListTile(
                          title: Text(
                            b['name'] ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'TideFont'),
                          ),
                          trailing: _botId == b['id']
                              ? Icon(
                                  Icons.check_rounded,
                                  color: TideTheme.of(context).primary,
                                )
                              : null,
                          onTap: () async {
                            final selectedId = b['id'] as String? ?? '';
                            await db.setKV('space_selected_bot_id', selectedId);
                            if (!mounted) return;
                            setState(() {
                              _botId = selectedId;
                              _botName = b['name'] as String? ?? '';
                            });
                            Navigator.pop(context);
                            _loadData();
                          },
                        ),
                        const Divider(height: 1),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: theme.surface.withValues(
                alpha: theme.isDark ? 0.82 : 0.80,
              ),
              border: Border.all(color: theme.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _botName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'TideFont',
                    color: theme.primary,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: theme.primary,
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _buildQuoteCard(TideTheme theme) => FrostCard(
    liquid: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.format_quote_rounded, color: theme.primary, size: 20),
            const SizedBox(width: 8),
            Text(
              '今日一言',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                fontFamily: 'TideFont',
                color: theme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          _dailyQuote.isNotEmpty ? _dailyQuote : '点击刷新今日一言',
          style: TextStyle(
            fontSize: 16,
            fontFamily: 'TideFont',
            color: _dailyQuote.isNotEmpty ? theme.textStrong : theme.textFaint,
            height: 1.5,
          ),
        ),
      ],
    ),
  );

  Widget _buildDaysCard(TideTheme theme) => FrostCard(
    liquid: true,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '$_daysSince',
            style: TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.w200,
              fontFamily: 'TideFont',
              color: theme.primary,
              height: 1.0,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '相遇天数',
          style: TextStyle(
            fontSize: 14,
            color: theme.textWeak,
            fontFamily: 'TideFont',
            letterSpacing: 2,
          ),
        ),
      ],
    ),
  );

  Widget _buildVitalCarousel(TideTheme theme) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(.2, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: VitalMetricCard(
        key: ValueKey('$_botId:$_vitalCardIndex'),
        data: _vitalSigns ?? {},
        index: _vitalCardIndex,
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              allowSnapshotting: false,
              builder: (_) => BotDataPage(botId: _botId, botName: _botName),
            ),
          );
          if (mounted) await _refreshVitals();
        },
      ),
    );
  }

  Widget _buildSectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        fontFamily: 'TideFont',
        color: TideTheme.of(context).textStrong,
      ),
    ),
  );

  // 日程仅作为机器人内部生活状态，不在空间页直接展示。
}

// ==================== 广场页 ====================
class SquarePage extends StatefulWidget {
  final GlobalKey<SquarePageState>? pageKey;
  const SquarePage({super.key, this.pageKey});
  @override
  State<SquarePage> createState() => SquarePageState();
}

class SquarePageState extends State<SquarePage>
    with SingleTickerProviderStateMixin {
  bool _showGames = false;
  late AnimationController _switchCtrl;
  late Animation<Offset> _slideAnim;
  final ScrollController _scrollCtrl = ScrollController();
  final List<Map<String, dynamic>> _feeds = [];
  int _feedPage = 0;
  static const _pageSize = 10;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _showParticles = false;
  int _particleRun = 0;
  final List<Offset> _particleOrigins = [];
  final _games = [
    {'name': '五子棋', 'desc': '和 TA 真实对弈', 'icon': 'grid'},
    {'name': '井字棋', 'desc': '和 TA 真实对弈', 'icon': 'circle'},
    {'name': '20问猜物', 'desc': '由 TA 发问和猜测', 'icon': 'help'},
    {'name': '斗地主', 'desc': '32 张牌双人对局', 'icon': 'casino'},
  ];
  final Map<String, IconData> _gameIcons = {
    'grid': Icons.grid_4x4_rounded,
    'circle': Icons.circle_outlined,
    'help': Icons.help_outline_rounded,
    'casino': Icons.casino_rounded,
    'book': Icons.menu_book_rounded,
    'favorite': Icons.favorite_rounded,
  };

  @override
  void initState() {
    super.initState();
    _switchCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _switchCtrl, curve: Curves.easeOutCubic));
    _switchCtrl.forward();
    _scrollCtrl.addListener(_onScroll);
    _prepareBotPosts().whenComplete(_loadFeeds);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _switchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >=
            _scrollCtrl.position.maxScrollExtent - 200 &&
        !_loadingMore &&
        _hasMore) {
      _loadFeeds();
    }
  }

  void toggleGames() {
    setState(() {
      _showGames = !_showGames;
      _switchCtrl.reset();
      _switchCtrl.forward();
    });
  }

  Future<void> _prepareBotPosts() async {
    final db = DBManager();
    if (await db.getKV('bot_posts_enabled') != 'true') return;
    final day = DateTime.now();
    final dayKey = '${day.year}-${day.month}-${day.day}';
    final perDay =
        (int.tryParse(await db.getKV('bot_posts_per_day') ?? '') ?? 1).clamp(
          1,
          10,
        );
    final bots = await db.queryBots();
    for (final bot in bots) {
      final botId = bot['id']?.toString() ?? '';
      if (botId.isEmpty || bot['chat_model']?.toString().isEmpty != false) {
        continue;
      }
      for (var index = 0; index < perDay; index++) {
        final marker = 'bot_post_date_${botId}_$index';
        if (await db.getKV(marker) == dayKey) continue;
        // Never generate or publish a future slot early. This method runs when
        // the feed opens, so scheduled time must be checked before model work.
        final dayStart = DateTime(
          day.year,
          day.month,
          day.day,
        ).millisecondsSinceEpoch;
        // Store each day's random slot. Hash-based slots made every bot post at
        // the exact same clock time on every day.
        final scheduleKey = 'bot_post_time_${botId}_${dayKey}_$index';
        var slot = int.tryParse(await db.getKV(scheduleKey) ?? '');
        if (slot == null || slot < 0 || slot >= 24 * 60) {
          // Day + bot + index seed: stable after generation, different tomorrow.
          final rng = Random('$dayKey:$botId:$index'.hashCode);
          slot = 8 * 60 + rng.nextInt(14 * 60); // 08:00–21:59
          await db.setKV(scheduleKey, '$slot');
        }
        final scheduledAt = dayStart + slot * Duration.millisecondsPerMinute;
        if (DateTime.now().millisecondsSinceEpoch < scheduledAt) continue;
        final withImages = await db.getKV('bot_posts_with_images') == 'true';
        final imageChance =
            (int.tryParse(await db.getKV('bot_posts_image_chance') ?? '') ?? 50)
                .clamp(1, 100);
        // The setting is the sole source of probability. The model plans a
        // scene only after the application selects this post for an image.
        final wantsImage =
            withImages &&
            Random('$dayKey:$botId:$index:image'.hashCode).nextInt(100) <
                imageChance;
        final hasPortraitReference =
            (await db.getKV('bot_image_reference_$botId') ?? '')
                .trim()
                .isNotEmpty;
        final referenceRule = hasPortraitReference
            ? '已设置你自己的人像照片作为参考图。必须在 JSON 中填写 use_portrait_reference 布尔值：美食、景点、物件等不含人物的配图为 false，image_prompt 明确不出现人物；配图出现人物（包括自拍、合照或局部人像）必须为 true。false 使用文生图，true 使用人像参考图进行图改，不要为了使用参考图额外添加人物。'
            : '未设置人像参考图，使用文生图，use_portrait_reference 填写 false。';
        final res = await AIManager().sendMessage(
          task: AIRequestTask.feedPost,
          botId: botId,
          text:
              // ignore: prefer_interpolation_to_compose_strings
              (wantsImage
                  ? '请以第一人称创作今天第 ${index + 1} 条朋友圈生活动态。仅输出严格 JSON，不要 markdown：{"content":"20到60字的自然生活动态","image_prompt":"与正文一致的完整生图提示词","use_portrait_reference":false}。$referenceRule 正文要具体、口语化，不写标签，不提图片。image_prompt 必须包含当前场景、时间、动作、可见穿搭或环境；未配置明确外观时优先第一人称生活场景、物件、环境或局部画面。不要出现机器人、机械人、AI 助手、文字、水印、UI 或聊天截图。'
                  : '请以第一人称发一条像朋友圈一样的生活动态（20到60字）：写今天真实、具体的小事、行动、瞬间感受或想分享给朋友的话。这是今天第 ${index + 1} 条，请避免重复已有内容。不要写成文章、日记、总结、散文或说教；自然口语化、有生活感，不要使用心情标签、话题标签，也不要提到图片、照片、配图或任何媒体占位。') +
              '\n当前本地时间：${DateTime.now().toIso8601String()}。\n当天生活素材（计划不等于已发生）：${await LifeScheduleService.instance.ensureToday(botId)}\n当天已发动态：${(await (await db.database).query('posts', where: 'author_id = ? AND timestamp >= ?', whereArgs: [botId, DateTime.now().copyWith(hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0).millisecondsSinceEpoch])).map((p) => p['content']).join('；')}',
          persistResponse: false,
          allowTools: false,
        );
        if (res['success'] != true) continue;
        final rawReply = res['reply']?.toString().trim() ?? '';
        String content = rawReply;
        String imagePrompt = '';
        bool usePortraitReference = false;
        if (wantsImage) {
          try {
            final decoded = jsonDecode(rawReply);
            if (decoded is Map) {
              content = decoded['content']?.toString().trim() ?? '';
              imagePrompt = decoded['image_prompt']?.toString().trim() ?? '';
              usePortraitReference = resolvePortraitReference(
                hasPortraitReference: hasPortraitReference,
                selection: decoded['use_portrait_reference'],
              );
            } else {
              content = rawReply;
            }
          } catch (error) {
            // A malformed structured response should lose only its image plan.
            // Keep valid prose when only the reference decision is invalid.
            imagePrompt = '';
            AppLogService.instance.add('POST', '动态图片计划解析失败，已降级为无图动态：$error');
          }
          if (content.isEmpty) {
            AppLogService.instance.add('POST', '带图动态缺少有效正文，已跳过');
            continue;
          }
          if (imagePrompt.isEmpty) {
            AppLogService.instance.add('POST', '带图动态缺少生图提示词，已降级为无图动态');
          }
        }

        if (content.isEmpty) continue;
        final postId = 'botpost_${botId}_${dayKey}_$index';
        String imagePath = '';
        if (wantsImage &&
            imagePrompt.isNotEmpty &&
            imagePrompt.length <= 2000) {
          imagePath =
              await AIManager().generateImageForBot(
                botId: botId,
                prompt: hasPortraitReference && !usePortraitReference
                    ? '$imagePrompt。画面不包含人物、人像、手部或身体局部，不添加人物元素。'
                    : imagePrompt,
                usePortraitReference: usePortraitReference,
              ) ??
              '';
        }
        // scheduledAt was calculated before generation so no future post can
        // enter the feed ahead of its planned local time.

        // 动态本体不含伪造的互动数据——点赞与评论必须来自真实发生的机器人互动。
        await db.insertPost({
          'id': postId,
          'author_id': botId,
          'content': content,
          'image_path': imagePath,
          'likes': 0,
          'comments': 0,
          'user_liked': 0,
          'user_collected': 0,
          'timestamp': scheduledAt,
        });
        // 真实互动：让其他机器人真实地查看这条由 ${bot['name']} 发布的动态，
        // 每个互动机器人都调用它自己的模型产出一条第一人称评论（非模板/非随机），
        // 并把"点赞"与"评论"作为持久化事件写入 feed_events / post_comments。
        final otherBots = bots
            .where(
              (cb) =>
                  (cb['id']?.toString() ?? '') != botId &&
                  (cb['chat_model']?.toString().isNotEmpty ?? false),
            )
            .toList();
        final shuffled = List<Map<String, dynamic>>.from(otherBots)
          ..shuffle(Random('$postId:reactions'.hashCode));
        for (var i = 0; i < shuffled.length && i < 2; i++) {
          final reactor = shuffled[i];
          final chance = Random(
            '$postId:${reactor['id']}'.hashCode,
          ).nextDouble();
          // Reactions are optional: some posts receive nothing, some only a like,
          // and only a subset receive an actual generated comment.
          if (chance > .58) continue;
          final reactorId = reactor['id']?.toString() ?? '';
          if (reactorId.isEmpty) continue;
          // 每个互动事件幂等：同一天同一机器人对同一条动态只真实互动一次。
          final reactKey = 'bot_react_${reactorId}_$postId';
          if (await db.getKV(reactKey) == '1') continue;
          final interaction = Random(
            '$postId:$reactorId:kind'.hashCode,
          ).nextDouble();
          if (interaction < .72) {
            await db.recordFeedEvent(
              postId: postId,
              actorId: reactorId,
              eventType: 'like',
            );
          }
          if (interaction < .38) {
            await db.recordFeedEvent(
              postId: postId,
              actorId: reactorId,
              eventType: 'collect',
            );
          }
          if (interaction > .44) {
            await db.setKV(reactKey, '1');
            continue;
          }
          // This bot chose to leave a real generated comment.
          try {
            final reactRes = await AIManager().sendMessage(
              task: AIRequestTask.feedComment,
              botId: reactorId,
              text:
                  '你在空间广场看到${bot['name'] ?? '另一个机器人'}发布了一条动态："$content"。请用你自己的第一人称口吻写一句简短评论（15字以内）回应这条动态，语气自然，不要出现心情标签、话题标签或"评论"二字。',
              persistResponse: false,
              includeChatHistory: false,
              enableAutoSummary: false,
            );
            final commentText = (reactRes['reply']?.toString() ?? '').trim();
            if (commentText.isNotEmpty) {
              await db.insertRealPostComment(
                postId: postId,
                authorId: reactor['name']?.toString() ?? '机器人',
                content: commentText,
                timestamp: scheduledAt + 60000 + i * 900000,
              );
            }
          } catch (_) {
            // 任一机器人模型不可用不影响其他机器人，也不影响动态本身落库。
          }
          await db.setKV(reactKey, '1');
        }
        await db.setKV(marker, dayKey);
      }
    }
  }

  Future<void> _loadFeeds() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final db = DBManager();
    final rows = await db.queryPosts(
      offset: _feedPage * _pageSize,
      limit: _pageSize,
    );
    if (rows.isEmpty || rows.length < _pageSize) _hasMore = false;
    // New posts use a stable bot ID. Older releases stored the bot name, so
    // resolve both representations before rendering the current name and avatar.
    final bots = await db.queryBots();
    Map<String, dynamic> botByAuthor(String? authorId) {
      if (authorId == null || authorId.isEmpty) return const {};
      for (final bot in bots) {
        if (bot['id']?.toString() == authorId ||
            bot['name']?.toString() == authorId) {
          return bot;
        }
      }
      return const {};
    }

    // 点赞数与评论数不再读取 posts 上的伪造整数字段，改为从
    // feed_events / post_comments 真实聚合计数。
    final feeds = <Map<String, dynamic>>[];
    for (final r in rows) {
      final postId = r['id']?.toString() ?? '';
      final likes = postId.isEmpty ? 0 : await db.countPostLikes(postId);
      final comments = postId.isEmpty ? 0 : await db.countPostComments(postId);
      final author = r['author_id']?.toString().trim() ?? '匿名';
      final bot = botByAuthor(author);
      final displayAuthor = bot.isNotEmpty
          ? bot['name']?.toString() ?? author
          : author;
      feeds.add({
        'user': displayAuthor == '我' ? '我' : displayAuthor,
        'author_id': author,
        'is_bot': bot.isNotEmpty,
        'bot_avatar': bot['avatar']?.toString(),
        'content': r['content'] ?? '',
        'image': r['image_path'] ?? '',
        'likes': likes,
        'comments': comments,
        'favorited': postId.isNotEmpty
            ? await db.hasFeedEvent(
                postId: postId,
                actorId: 'me',
                eventType: 'like',
              )
            : false,
        'collected': postId.isNotEmpty
            ? await db.hasFeedEvent(
                postId: postId,
                actorId: 'me',
                eventType: 'collect',
              )
            : false,
        'time': r['timestamp'] != null ? formatTime(r['timestamp']) : '',
        'id': r['id'],
      });
    }
    if (mounted) {
      setState(() {
        _feeds.addAll(feeds);
        _feedPage++;
        _loadingMore = false;
      });
    }
  }

  Future<void> _shareFeed(Map<String, dynamic> f) async {
    final db = DBManager();
    final bots = await db.queryBots();
    if (!mounted || bots.isEmpty) return;
    final botId = await showTideSheet<String>(
      context: context,
      height: 420,
      child: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Text(
              '分享给机器人',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                fontFamily: 'TideFont',
              ),
            ),
          ),
          ...bots.map(
            (bot) => ListTile(
              leading: TideBotAvatar(
                name: bot['name']?.toString() ?? 'TA',
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
    if (botId == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = jsonEncode({
      'post_id': f['id']?.toString() ?? '',
      'author': f['user']?.toString() ?? '匿名',
      'content': f['content']?.toString() ?? '',
      'image_path': f['image']?.toString() ?? '',
      'timestamp': f['timestamp'] ?? now,
    });
    await MessageDeliveryService.instance.insert({
      'id': 'share_$now',
      'bot_id': botId,
      'role': 'user',
      'type': 'shared_post',
      'content': payload,
      'file_path': f['image']?.toString(),
      'timestamp': now,
    });
    // A share is a real chat turn, not merely an archived card. Ask the bot
    // immediately while keeping the JSON payload out of its natural-language UI.
    final readable =
        '用户分享了一条动态。作者：${f['user'] ?? '匿名'}；发布时间：${formatTime(f['timestamp'] ?? now)}；内容：${f['content'] ?? ''}；${(f['image']?.toString().isNotEmpty == true) ? '动态附有一张图片。' : ''} 请针对这条动态自然回应。';
    final reply = await AIManager().sendMessage(botId: botId, text: readable);
    if (!mounted) return;
    GlobalNotice.show(
      reply['success'] == true ? '动态已发送，机器人已回复' : '动态已发送；机器人回复失败，可在聊天页重试',
      color: reply['success'] == true ? null : const Color(0xFFE74C3C),
    );
  }

  void publishFeed() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (c, a, s) => _PublishFeedPage(
          onPublished: (text, imagePath) async {
            final db = DBManager();
            final now = DateTime.now().millisecondsSinceEpoch;
            final postId = 'post_$now';
            await db.insertPost({
              'id': postId,
              'author_id': '我',
              'content': text,
              'image_path': imagePath ?? '',
              'likes': 0,
              'comments': 0,
              'user_liked': 0,
              'user_collected': 0,
              'timestamp': now,
            });
            setState(
              () => _feeds.insert(0, {
                'user': '我',
                'content': text,
                'image': imagePath ?? '',
                'likes': 0,
                'comments': 0,
                'favorited': false,
                'collected': false,
                'time': '刚刚',
                'id': postId,
              }),
            );
          },
        ),
        transitionsBuilder: (c, a, s, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.3),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
  }

  void _openFeedDetail(Map<String, dynamic> f) {
    openFeedDetail(
      context,
      f,
      onUpdate: () {
        if (mounted) setState(() {});
      },
    );
  }

  void _deleteFeed(Map<String, dynamic> f, GlobalKey cardKey) async {
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
                '删除动态',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'TideFont',
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '确定删除这条动态吗？\n此操作不可恢复。',
                textAlign: TextAlign.start,
                style: TextStyle(
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
      final box = cardKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final position = box.localToGlobal(Offset.zero);
        _particleOrigins.clear();
        for (var i = 0; i < 12; i++) {
          _particleOrigins.add(
            Offset(
              position.dx + box.size.width * (0.1 + 0.8 * i / 11),
              position.dy + box.size.height * (0.2 + 0.6 * ((i * 7) % 11) / 10),
            ),
          );
        }
        setState(() {
          _particleRun++;
          _showParticles = true;
        });
      }
      await DBManager().deletePost(f['id'] as String? ?? '');
      if (mounted) {
        setState(() => _feeds.removeWhere((x) => x['id'] == f['id']));
        Future.delayed(const Duration(milliseconds: 1400), () {
          if (mounted) setState(() => _showParticles = false);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final content = Stack(
      children: [
        Container(
          color: theme.bgColor,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      const Spacer(),
                      BouncyTap(
                        onTap: toggleGames,
                        child: AnimatedRotation(
                          turns: _showGames ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOutCubic,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              color: theme.primary.withValues(alpha: 0.12),
                            ),
                            child: Icon(
                              _showGames
                                  ? Icons.videogame_asset_rounded
                                  : Icons.article_rounded,
                              size: 22,
                              color: theme.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
                Expanded(
                  child: SlideTransition(
                    position: _slideAnim,
                    child: _showGames ? _buildGames(theme) : _buildFeeds(theme),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    return _showParticles
        ? ParticleOverlay(
            key: ValueKey(_particleRun),
            origins: _particleOrigins,
            onDone: () {
              if (mounted) setState(() => _showParticles = false);
            },
            child: content,
          )
        : content;
  }

  Widget _wechatFeeds(TideTheme theme) => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.only(bottom: 32),
    itemCount: _feeds.isEmpty ? 1 : _feeds.length,
    itemBuilder: (context, index) {
      if (_feeds.isEmpty)
        return const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: Text('还没有动态，点击 + 发布第一条')),
        );
      final feed = _feeds[index];
      final key = GlobalKey();
      final image = feed['image']?.toString() ?? '';
      return GestureDetector(
        key: key,
        onTap: () => _openFeedDetail(feed),
        onLongPress: () => _deleteFeed(feed, key),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.surface,
            border: Border(bottom: BorderSide(color: theme.border, width: .5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TideBotAvatar(
                name: feed['user']?.toString() ?? '用户',
                path: feed['is_bot'] == true
                    ? feed['bot_avatar']?.toString()
                    : null,
                size: 42,
                radius: 5,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      feed['user']?.toString() ?? '',
                      style: const TextStyle(
                        color: Color(0xFF576B95),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      feed['content']?.toString() ?? '',
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.5,
                        color: theme.textStrong,
                      ),
                    ),
                    if (image.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 280,
                            maxHeight: 320,
                          ),
                          child: Image.file(
                            File(image),
                            fit: BoxFit.contain,
                            errorBuilder: (_, error, stack) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            feed['time']?.toString() ?? '',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.textWeak,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '动态详情与互动',
                          onPressed: () => _openFeedDetail(feed),
                          style: IconButton.styleFrom(
                            backgroundColor: theme.surfaceVariant,
                            minimumSize: const Size(36, 28),
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          icon: const Icon(
                            Icons.more_horiz,
                            color: Color(0xFF576B95),
                          ),
                        ),
                      ],
                    ),
                    if ((feed['likes'] as int? ?? 0) > 0)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        color: theme.surfaceVariant,
                        child: Text(
                          '♡  ${feed['likes']} 人赞过',
                          style: const TextStyle(color: Color(0xFF576B95)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _buildFeeds(TideTheme theme) => theme.isWechat
      ? _wechatFeeds(theme)
      : _feeds.isEmpty
      ? ListView(
          key: const ValueKey('feeds_empty'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
          children: const [
            FrostCard(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  '还没有动态\n点击右下角 + 发布第一条',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Color(0xFF8E8E93),
                    fontFamily: 'TideFont',
                    height: 1.6,
                  ),
                ),
              ),
            ),
          ],
        )
      : ListView.builder(
          key: const ValueKey('feeds'),
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
          physics: const BouncingScrollPhysics(),
          itemCount: _feeds.length,
          itemBuilder: (ctx, i) {
            final f = _feeds[i];
            final cardKey = GlobalKey();
            return FrostCard(
              key: cardKey,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              onTap: () => _openFeedDetail(f),
              onLongPress: () => _deleteFeed(f, cardKey),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => _openFeedDetail(f),
                    child: Row(
                      children: [
                        f['is_bot'] == true
                            ? TideBotAvatar(
                                name: f['user']?.toString() ?? 'TA',
                                path: f['bot_avatar']?.toString(),
                                size: 36,
                              )
                            : CircleAvatar(
                                radius: 18,
                                backgroundColor: theme.primary.withValues(
                                  alpha: 0.15,
                                ),
                                child: Icon(
                                  Icons.person_rounded,
                                  size: 20,
                                  color: theme.primary,
                                ),
                              ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              f['user'] ?? '',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'TideFont',
                              ),
                            ),
                            Text(
                              f['time'] ?? '',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFC7C7CC),
                                fontFamily: 'TideFont',
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        BouncyTap(
                          onTap: () => _shareFeed(f),
                          child: const Icon(
                            Icons.share_rounded,
                            size: 18,
                            color: Color(0xFFC7C7CC),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () => _openFeedDetail(f),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (f['image'] != null &&
                            (f['image'] as String).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.file(
                                File(f['image'] as String),
                                width: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        Text(
                          f['content'] ?? '',
                          style: TextStyle(
                            fontSize: 14,
                            fontFamily: 'TideFont',
                            color: theme.isDark
                                ? Colors.white
                                : const Color(0xFF3C3C43),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      BouncyTap(
                        onTap: () async {
                          final wasLiked = f['favorited'] as bool;
                          setState(() {
                            f['favorited'] = !wasLiked;
                            f['likes'] =
                                (f['likes'] as int) +
                                (f['favorited'] == true ? 1 : -1);
                          });
                          // 用户的点赞是真实互动事件，落库 feed_events。
                          final nowLiked = await DBManager().toggleFeedEvent(
                            postId: f['id'] as String? ?? '',
                            actorId: 'me',
                            eventType: 'like',
                          );
                          if (nowLiked != (f['favorited'] as bool) && mounted) {
                            setState(() {
                              f['favorited'] = nowLiked;
                              f['likes'] =
                                  (f['likes'] as int) + (nowLiked ? 1 : -1);
                            });
                          }
                        },
                        child: Row(
                          children: [
                            Icon(
                              f['favorited'] == true
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              size: 18,
                              color: f['favorited'] == true
                                  ? const Color(0xFFE74C3C)
                                  : const Color(0xFFC7C7CC),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${f['likes']}',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFFC7C7CC),
                                fontFamily: 'TideFont',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      BouncyTap(
                        onTap: () => _commentFeed(f, theme),
                        child: Row(
                          children: [
                            Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 18,
                              color: theme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${f['comments']}',
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.primary,
                                fontFamily: 'TideFont',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      BouncyTap(
                        onTap: () async {
                          setState(
                            () => f['collected'] = !(f['collected'] as bool),
                          );
                          // 收藏是真实互动事件（feed_events collect，幂等切换）。
                          await DBManager().toggleFeedEvent(
                            postId: f['id'] as String? ?? '',
                            actorId: 'me',
                            eventType: 'collect',
                          );
                        },
                        child: Icon(
                          f['collected'] == true
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                          size: 18,
                          color: f['collected'] == true
                              ? theme.primary
                              : const Color(0xFFC7C7CC),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );

  void _commentFeed(Map<String, dynamic> f, TideTheme theme) {
    _openFeedDetail(f);
  }

  Future<void> _startGame(String game) async {
    final bots = await DBManager().queryBots();
    if (!mounted) return;
    if (bots.isEmpty) {
      GlobalNotice.show('请先创建机器人', color: const Color(0xFFE74C3C));
      return;
    }
    final theme = TideTheme.of(context);
    await showTideSheet(
      context: context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '选择对战机器人',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: theme.textStrong,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '本局 $game 会和选中的 TA 进行，游戏内也能直接聊天。',
              style: TextStyle(color: theme.textWeak, fontFamily: 'TideFont'),
            ),
            const SizedBox(height: 10),
            ...bots.map(
              (bot) => ListTile(
                leading: TideBotAvatar(
                  name: bot['name']?.toString() ?? '未命名机器人',
                  path: bot['avatar']?.toString(),
                  size: 44,
                ),
                title: Text(
                  bot['name']?.toString() ?? '未命名机器人',
                  style: TextStyle(
                    color: theme.textStrong,
                    fontFamily: 'TideFont',
                  ),
                ),
                subtitle: Text(
                  bot['chat_model']?.toString().isNotEmpty == true
                      ? '已配置模型'
                      : '未配置模型，仍可进行本地回合',
                  style: TextStyle(
                    color: theme.textWeak,
                    fontSize: 12,
                    fontFamily: 'TideFont',
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GameArenaPage(game: game, bot: bot),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGames(TideTheme theme) => theme.isWechat
      ? ListView.separated(
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: _games.length,
          separatorBuilder: (_, index) =>
              Divider(height: .5, indent: 72, color: theme.border),
          itemBuilder: (_, index) {
            final game = _games[index];
            return ColoredBox(
              color: theme.surface,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.primary.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _gameIcons[game['icon']] ?? Icons.extension_rounded,
                    color: theme.primary,
                  ),
                ),
                title: Text(game['name'] ?? ''),
                subtitle: Text(game['desc'] ?? ''),
                trailing: Icon(Icons.chevron_right, color: theme.textWeak),
                onTap: () => _startGame(game['name']?.toString() ?? ''),
              ),
            );
          },
        )
      : GridView.builder(
          key: const ValueKey('games'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
          physics: const BouncingScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            // 仅四款游戏，使用更高的入口卡片以提升可点性与可读性。
            childAspectRatio: 0.78,
          ),
          itemCount: _games.length,
          itemBuilder: (ctx, i) {
            final g = _games[i];
            final icon = _gameIcons[g['icon']] ?? Icons.extension_rounded;
            return BouncyTap(
              onTap: () => _startGame(g['name']?.toString() ?? ''),
              child: FrostCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 52, color: theme.primary),
                    const SizedBox(height: 14),
                    Text(
                      g['name'] ?? '',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'TideFont',
                        color: theme.textStrong,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      g['desc'] ?? '',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFC7C7CC),
                        fontFamily: 'TideFont',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
}

// ==================== 全屏发布页 ====================
class _PublishFeedPage extends StatefulWidget {
  final Function(String, String?) onPublished;
  const _PublishFeedPage({required this.onPublished});
  @override
  State<_PublishFeedPage> createState() => _PublishFeedPageState();
}

class _PublishFeedPageState extends State<_PublishFeedPage> {
  final ctrl = TextEditingController();
  String? _imagePath;

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  void _pickImage() async {
    final p = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
    );
    if (p != null) setState(() => _imagePath = p.path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    // Keep the backdrop inside the page so it moves with the entire route.
    return TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            '发布动态',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontFamily: 'TideFont',
              color: theme.onBackgroundStrong,
            ),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            TextButton(
              onPressed: () {
                final text = ctrl.text.trim();
                if (text.isNotEmpty) {
                  widget.onPublished(text, _imagePath);
                  Navigator.pop(context);
                }
              },
              child: Text(
                '发布',
                style: TextStyle(
                  color: theme.primary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'TideFont',
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: TextField(
                  contextMenuBuilder: androidTextContextMenu,
                  controller: ctrl,
                  autofocus: true,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(
                    fontSize: 16,
                    fontFamily: 'TideFont',
                    height: 1.8,
                  ),
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    hintText: '分享你的想法...',
                    hintStyle: TextStyle(
                      fontSize: 16,
                      color: Color(0xFFC7C7CC),
                      fontFamily: 'TideFont',
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            if (_imagePath != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      Image.file(
                        File(_imagePath!),
                        height: 120,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () => setState(() => _imagePath = null),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black54,
                            ),
                            child: const Icon(
                              Icons.close,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: BouncyTap(
                onTap: _pickImage,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: theme.primary.withValues(alpha: 0.1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_rounded, size: 20, color: theme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '添加图片',
                        style: TextStyle(
                          color: theme.primary,
                          fontFamily: 'TideFont',
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<Map<String, dynamic>?> feedMapFromPostId(String postId) async {
  final id = postId.trim();
  if (id.isEmpty) return null;
  final db = DBManager();
  final post = await db.getPostById(id);
  if (post == null) return null;
  final bots = await db.queryBots();
  final author = post['author_id']?.toString().trim() ?? '匿名';
  Map<String, dynamic> bot = const {};
  for (final item in bots) {
    if (item['id']?.toString() == author ||
        item['name']?.toString() == author) {
      bot = item;
      break;
    }
  }
  final displayAuthor = bot.isNotEmpty
      ? bot['name']?.toString() ?? author
      : author;
  return {
    'user': displayAuthor == '我' ? '我' : displayAuthor,
    'author_id': author,
    'is_bot': bot.isNotEmpty,
    'bot_avatar': bot['avatar']?.toString(),
    'content': post['content'] ?? '',
    'image': post['image_path'] ?? '',
    'likes': await db.countPostLikes(id),
    'comments': await db.countPostComments(id),
    'favorited': await db.hasFeedEvent(
      postId: id,
      actorId: 'me',
      eventType: 'like',
    ),
    'collected': await db.hasFeedEvent(
      postId: id,
      actorId: 'me',
      eventType: 'collect',
    ),
    'time': post['timestamp'] != null ? formatTime(post['timestamp']) : '',
    'id': id,
    'timestamp': post['timestamp'],
  };
}

void openFeedDetail(
  BuildContext context,
  Map<String, dynamic> feed, {
  VoidCallback? onUpdate,
}) {
  Navigator.push(
    context,
    PageRouteBuilder(
      pageBuilder: (c, a, s) =>
          _FeedDetailPage(feed: feed, onUpdate: onUpdate ?? () {}),
      transitionsBuilder: (c, a, s, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.15),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

// ==================== 动态详情页 ====================
class _FeedDetailPage extends StatefulWidget {
  final Map<String, dynamic> feed;
  final VoidCallback onUpdate;
  const _FeedDetailPage({required this.feed, required this.onUpdate});

  @override
  State<_FeedDetailPage> createState() => _FeedDetailPageState();
}

class _FeedDetailPageState extends State<_FeedDetailPage> {
  final _commentCtrl = TextEditingController();
  List<Map<String, dynamic>> _comments = [];
  String _userName = '我';
  String? _userAvatar;
  bool _loading = true;
  bool _sendingComment = false;
  Map<String, dynamic>? _replyTarget;

  @override
  void initState() {
    super.initState();
    _loadComments();
    UserProfileChanges.revision.addListener(_reloadUserProfile);
  }

  @override
  void dispose() {
    UserProfileChanges.revision.removeListener(_reloadUserProfile);
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _reloadUserProfile() async {
    final revision = UserProfileChanges.revision.value;
    final db = DBManager();
    final name = await db.getKV('user_name');
    final avatar = await db.getKV('user_avatar');
    if (!mounted || revision != UserProfileChanges.revision.value) return;
    setState(() {
      _userName = name?.trim().isNotEmpty == true ? name! : '我';
      _userAvatar = avatar;
    });
  }

  Future<void> _loadComments() async {
    final db = DBManager();
    final userName = await db.getKV('user_name');
    final userAvatar = await db.getKV('user_avatar');
    // 关联机器人名字到头像，供评论真实头像展示。
    final bots = await db.queryBots();
    final avatarMap = <String, String>{};
    for (final b in bots) {
      final name = b['name']?.toString() ?? '';
      if (name.isNotEmpty) avatarMap[name] = b['avatar']?.toString() ?? '';
    }
    final rows = await db.queryPostComments(widget.feed['id'] as String? ?? '');
    if (mounted) {
      setState(() {
        _userName = userName?.trim().isNotEmpty == true ? userName! : '我';
        _userAvatar = userAvatar;
        // 用户评论在显示时读取当前资料，作者标识保持为 me。
        _comments = rows.map((c) {
          final author = c['author_id']?.toString() ?? '';
          final avatar = avatarMap[author];
          return {
            ...c,
            if (avatar != null && avatar.isNotEmpty) 'author_avatar': avatar,
          };
        }).toList();
        _loading = false;
      });
    }
  }

  Future<void> _toggleLike() async {
    final db = DBManager();
    final wasLiked = widget.feed['favorited'] as bool;
    // 先乐观更新 UI，再写入真实互动事件。
    setState(() {
      widget.feed['favorited'] = !wasLiked;
      widget.feed['likes'] =
          (widget.feed['likes'] as int) +
          (widget.feed['favorited'] == true ? 1 : -1);
    });
    // 用户的点赞是真实发生的互动事件：写 feed_events（actor 固定为 'me'）。
    final nowLiked = await db.toggleFeedEvent(
      postId: widget.feed['id'] as String? ?? '',
      actorId: 'me',
      eventType: 'like',
    );
    // 若写入失败（如空 postId），回滚 UI。
    if (nowLiked != (widget.feed['favorited'] as bool) && mounted) {
      setState(() {
        widget.feed['favorited'] = nowLiked;
        widget.feed['likes'] =
            (widget.feed['likes'] as int) + (nowLiked ? 1 : -1);
      });
    }
    widget.onUpdate();
  }

  Future<void> _toggleCollect() async {
    final db = DBManager();
    setState(() {
      widget.feed['collected'] = !(widget.feed['collected'] as bool);
    });
    // 收藏同样是真实互动事件（存在 feed_events 的 collect 事件）。
    await db.toggleFeedEvent(
      postId: widget.feed['id'] as String? ?? '',
      actorId: 'me',
      eventType: 'collect',
    );
    widget.onUpdate();
  }

  Future<void> _sendComment() async {
    final content = _commentCtrl.text.trim();
    if (content.isEmpty || _sendingComment) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final comment = <String, dynamic>{
      'id': 'pc_$now',
      'post_id': widget.feed['id'],
      'author_id': 'me',
      'content': content,
      'parent_id': _replyTarget?['id'],
      'timestamp': now,
      'pending': true,
    };
    setState(() {
      _sendingComment = true;
      _commentCtrl.clear();
      _replyTarget = null;
      _comments.add(comment);
      widget.feed['comments'] = (widget.feed['comments'] as int) + 1;
    });
    try {
      final stored = Map<String, dynamic>.from(comment)..remove('pending');
      await DBManager().insertPostComment(stored);
      if (mounted) {
        setState(() {
          comment.remove('pending');
          _sendingComment = false;
        });
      }
      widget.onUpdate();
      // If this is a reply, it stays nested under its target; author replies
      // directly to that same node, enabling unlimited comment depth.
      unawaited(_maybeBotReply(comment));
    } catch (_) {
      if (mounted) {
        setState(() {
          _comments.remove(comment);
          widget.feed['comments'] = ((widget.feed['comments'] as int) - 1)
              .clamp(0, 1 << 30);
          _sendingComment = false;
        });
        GlobalNotice.show('评论发送失败，请重试', color: const Color(0xFFE74C3C));
      }
    }
  }

  // 机器人原作者以一定概率回复用户的评论；回复是真实的模型产出，且幂等去重。
  Future<void> _maybeBotReply(Map<String, dynamic> userComment) async {
    if (widget.feed['is_bot'] != true) return;
    final authorName = widget.feed['author_id']?.toString().trim() ?? '';
    if (authorName.isEmpty) return;
    // Replies are intentionally probabilistic, not mandatory for every comment.
    if (Random('reply:${userComment['id']}'.hashCode).nextDouble() > .45)
      return;
    final db = DBManager();
    final bots = await db.queryBots();
    Map<String, dynamic> authorBot = const {};
    for (final b in bots) {
      if (b['name']?.toString() == authorName) {
        authorBot = b;
        break;
      }
    }
    final botId = authorBot['id']?.toString() ?? '';
    if (botId.isEmpty || authorName == userComment['author_id']?.toString())
      return;
    // 同一机器人对同一条评论只回复一次。
    final replyKey = 'bot_reply_${botId}_${userComment['id']}';
    if ((await db.getKV(replyKey)) == '1') return;
    final um2 = userComment['content']?.toString() ?? '';
    try {
      final res = await AIManager().sendMessage(
        task: AIRequestTask.feedComment,
        botId: botId,
        text:
            '原动态：${widget.feed['content']}。相关评论线程：${jsonEncode((await db.queryPostComments(widget.feed['id'].toString())).where((c) => c['id'] == userComment['id'] || c['id'] == userComment['parent_id'] || c['parent_id'] == userComment['id']).toList())}。评论者：${userComment['author_id']}。有人在你的动态下留下内容：“$um2”。请用第一人称口吻简短自然地回应这条内容（20字以内）。这可能来自用户，也可能来自另一位机器人；不要提及系统、指令或心情标签。',
        persistResponse: false,
        includeChatHistory: false,
        enableAutoSummary: false,
      );
      final reply = (res['reply']?.toString() ?? '').trim();
      if (reply.isEmpty) return;
      await db.insertRealPostComment(
        postId: widget.feed['id'] as String? ?? '',
        authorId: authorName,
        content: reply,
        parentId: userComment['id']?.toString(),
      );
      await db.setKV(replyKey, '1');
      if (mounted) {
        final replyComment = <String, dynamic>{
          'id': 'br_${DateTime.now().millisecondsSinceEpoch}',
          'post_id': widget.feed['id'],
          'author_id': authorName,
          'content': reply,
          'parent_id': userComment['id']?.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'author_avatar': authorBot['avatar']?.toString() ?? '',
        };
        setState(() {
          _comments.add(replyComment);
          widget.feed['comments'] = (widget.feed['comments'] as int) + 1;
        });
        widget.onUpdate();
      }
    } catch (_) {
      // 回复失败不影响主流程。
    }
  }

  // 评论属于当前本地数据库；无论用户或机器人作者，长按均允许管理删除。
  bool _canDeleteComment(Map<String, dynamic> comment) =>
      comment['id']?.toString().trim().isNotEmpty == true &&
      comment['pending'] != true;

  Future<void> _deleteComment(Map<String, dynamic> comment) async {
    if (!_canDeleteComment(comment)) return;
    final id = comment['id']?.toString() ?? '';
    if (id.isEmpty || comment['pending'] == true) return;
    final confirmed = await TideDialogs.show<bool>(
      context: context,
      builder: (ctx) => TideDialogSurface(
        backgroundColor: Colors.transparent,
        contentPadding: EdgeInsets.zero,
        content: TideDialogs.glassContent(
          context: ctx,
          children: [
            Text(
              '删除评论',
              textAlign: TextAlign.start,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: TideTheme.of(ctx).textStrong,
                fontFamily: 'TideFont',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '确定删除这条评论吗？',
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
                    color: TideTheme.of(ctx).surfaceVariant,
                    textColor: TideTheme.of(ctx).textStrong,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TideDialogs.glassButton(
                    '删除',
                    onTap: () => Navigator.pop(ctx, true),
                    color: TideTheme.of(ctx).primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await DBManager().deletePostComment(id);
      if (!mounted) return;
      setState(() {
        _comments.removeWhere((item) => item['id']?.toString() == id);
        widget.feed['comments'] = ((widget.feed['comments'] as int) - 1).clamp(
          0,
          1 << 30,
        );
      });
      widget.onUpdate();
    } catch (_) {
      if (mounted) GlobalNotice.show('删除评论失败，请重试');
    }
  }

  List<Widget> _commentTree() {
    final byParent = <String, List<Map<String, dynamic>>>{};
    for (final comment in _comments) {
      final key = comment['parent_id']?.toString() ?? '';
      (byParent[key] ??= []).add(comment);
    }
    List<Widget> buildNodes(String parentId, int depth) => [
      for (final comment
          in byParent[parentId] ?? const <Map<String, dynamic>>[]) ...[
        _commentNode(comment, depth),
        ...buildNodes(comment['id']?.toString() ?? '', depth + 1),
      ],
    ];
    return buildNodes('', 0);
  }

  String _commentAuthorName(Map<String, dynamic> comment) =>
      comment['author_id'] == 'me'
      ? _userName
      : comment['author_id']?.toString() ?? '匿名';

  Widget _commentNode(Map<String, dynamic> comment, int depth) {
    final theme = TideTheme.of(context);
    final inset = (depth * 18.0).clamp(0, 72).toDouble();
    final authorName = _commentAuthorName(comment);
    final avatar = comment['author_id'] == 'me'
        ? _userAvatar
        : comment['author_avatar']?.toString();
    return Padding(
      padding: EdgeInsets.only(left: inset, bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar?.isNotEmpty == true
              ? TideBotAvatar(name: authorName, path: avatar, size: 30)
              : CircleAvatar(
                  radius: 15,
                  backgroundColor: theme.primary.withValues(alpha: .12),
                  child: Icon(
                    Icons.person_rounded,
                    size: 16,
                    color: theme.primary,
                  ),
                ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: _canDeleteComment(comment)
                  ? () => _deleteComment(comment)
                  : null,
              onTap: () => setState(() {
                _replyTarget = comment;
                _commentCtrl.clear();
              }),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    authorName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.textStrong,
                      fontFamily: 'TideFont',
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    comment['content'] ?? '',
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.textWeak,
                      fontFamily: 'TideFont',
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '回复',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.primary,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final feed = widget.feed;
    // Keep the backdrop inside the page so it moves with the entire route.
    return TideBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(
            '动态详情',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontFamily: 'TideFont',
              color: theme.onBackgroundStrong,
            ),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: theme.onBackgroundWeak),
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Row(
                    children: [
                      feed['is_bot'] == true
                          ? TideBotAvatar(
                              name: feed['user']?.toString() ?? 'TA',
                              path: feed['bot_avatar']?.toString(),
                              size: 44,
                            )
                          : CircleAvatar(
                              radius: 22,
                              backgroundColor: theme.primary.withValues(
                                alpha: 0.15,
                              ),
                              child: Icon(
                                Icons.person_rounded,
                                size: 24,
                                color: theme.primary,
                              ),
                            ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            feed['user'] ?? '',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'TideFont',
                              color: theme.textStrong,
                            ),
                          ),
                          Text(
                            feed['time'] ?? '',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.textFaint,
                              fontFamily: 'TideFont',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if ((feed['image'] ?? '').toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(feed['image'] as String),
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  Text(
                    feed['content'] ?? '',
                    style: TextStyle(
                      fontSize: 16,
                      fontFamily: 'TideFont',
                      color: theme.textStrong,
                      height: 1.8,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      BouncyTap(
                        onTap: _toggleLike,
                        child: Row(
                          children: [
                            Icon(
                              feed['favorited'] == true
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              size: 22,
                              color: feed['favorited'] == true
                                  ? const Color(0xFFE74C3C)
                                  : theme.iconMuted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${feed['likes']} 点赞',
                              style: TextStyle(
                                fontSize: 14,
                                color: theme.textWeak,
                                fontFamily: 'TideFont',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 24),
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 22,
                        color: theme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${feed['comments']} 评论',
                        style: TextStyle(
                          fontSize: 14,
                          color: theme.primary,
                          fontFamily: 'TideFont',
                        ),
                      ),
                      const Spacer(),
                      BouncyTap(
                        onTap: _toggleCollect,
                        child: Icon(
                          feed['collected'] == true
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                          size: 22,
                          color: feed['collected'] == true
                              ? theme.primary
                              : theme.iconMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Text(
                    '全部评论',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'TideFont',
                      color: theme.textStrong,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_loading)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: CircularProgressIndicator(color: theme.primary),
                      ),
                    )
                  else if (_comments.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '还没有评论，来说点什么吧',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.textFaint,
                            fontFamily: 'TideFont',
                          ),
                        ),
                      ),
                    )
                  else
                    ..._commentTree(),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(
                  color: theme.surface,
                  border: Border(top: BorderSide(color: theme.border)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyTarget != null)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '回复 ${_commentAuthorName(_replyTarget!)}',
                              textAlign: TextAlign.start,
                              style: TextStyle(
                                color: theme.textWeak,
                                fontFamily: 'TideFont',
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () =>
                                setState(() => _replyTarget = null),
                          ),
                        ],
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            contextMenuBuilder: androidTextContextMenu,
                            controller: _commentCtrl,
                            textInputAction: TextInputAction.send,
                            onSubmitted: _sendingComment
                                ? null
                                : (_) => _sendComment(),
                            style: TextStyle(
                              color: theme.textStrong,
                              fontFamily: 'TideFont',
                            ),
                            decoration: InputDecoration(
                              hintText: '写评论...',
                              hintStyle: TextStyle(
                                color: theme.textFaint,
                                fontFamily: 'TideFont',
                              ),
                              filled: true,
                              fillColor: theme.surfaceVariant,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 9,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _sendingComment ? null : _sendComment,
                          icon: _sendingComment
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(Icons.send_rounded, color: theme.primary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
