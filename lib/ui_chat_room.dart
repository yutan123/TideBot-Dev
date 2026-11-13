import 'chat_header_color.dart';
import 'bot_avatar_crop_page.dart';
import 'image_detail_page.dart';
import 'proactive_request_gate.dart';
import 'media_storage_service.dart';
import 'chat_message_debounce.dart';
import 'photo_image_provider.dart';
import 'chat_image.dart';
import 'tide_popover.dart';
import 'video_input.dart';
import 'video_source_context.dart';
import 'chat_video.dart';
import 'video_poster.dart';
import 'android_selection_menu.dart';
import 'send_voice_cooldown.dart';
import 'chat_typing_state.dart';
import 'default_chat_background.dart';
import 'app_log_service.dart';
import 'chat_stream_pacing.dart';
import 'chat_message_display.dart';
import 'dart:io';
import 'dart:convert';
import 'code_card.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'log_text.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:flutter/services.dart';
import 'global_notice.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:heif_converter/heif_converter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'chat_event_bus.dart';
import 'db.dart';
import 'ai.dart';
import 'message_delivery_service.dart';
import 'app_state.dart';
import 'ui_components.dart';
import 'theme.dart';
import 'app_permissions.dart';
import 'media_preprocessor.dart';
import 'voice_call_card.dart';
import 'incoming_call_banner.dart';
// Device control has been removed; device context remains in the AI layer.
import 'emotion_state_service.dart';
import 'chat_protocol.dart';
import 'ui_call.dart';
import 'ui_space_square.dart';
import 'world_book_service.dart';
import 'link_preview_service.dart';
import 'link_preview_models.dart';
import 'link_preview_cards.dart';
import 'platform_video_resolver.dart';

class _EmojiAsset {
  final String asset;
  final String category;
  final String name;
  final String glyph;
  final int order;

  const _EmojiAsset({
    required this.asset,
    required this.category,
    required this.name,
    required this.glyph,
    required this.order,
  });
}

class _PendingExpression {
  const _PendingExpression._({
    required this.type,
    required this.name,
    required this.path,
  });

  factory _PendingExpression.sticker(Map<String, dynamic> sticker) =>
      _PendingExpression._(
        type: 'sticker',
        name: sticker['emotion']?.toString().trim().isNotEmpty == true
            ? sticker['emotion'].toString().trim()
            : '未分类',
        path: sticker['file_path']?.toString() ?? '',
      );

  final String type;
  final String name;
  final String path;

  bool get isEmoji => type == 'emoji';

  String get modelContext =>
      type == 'emoji' ? '[$name]' : '[对方发送了一个表情包，表情包类型：$name]';

  Map<String, dynamic> toMessage({
    required String botId,
    required int timestamp,
  }) => {
    'id': '${type}_$timestamp',
    'bot_id': botId,
    'role': 'user',
    'type': type,
    'content': name,
    'file_path': path,
    'timestamp': timestamp,
  };
}

final _emojiCategoryIcons = <String, (IconData, String)>{
  'people': (Icons.emoji_emotions_outlined, '表情和人物'),
  'nature': (Icons.pets_outlined, '动物和自然'),
  'food': (Icons.restaurant_outlined, '食物和饮料'),
  'activity': (Icons.sports_basketball_outlined, '活动'),
  'travel': (Icons.directions_car_outlined, '旅行和地点'),
  'objects': (Icons.lightbulb_outline_rounded, '物品'),
  'symbols': (Icons.sentiment_satisfied_alt_outlined, '符号'),
  // 国旗分组已移除
};

class _StableLinkPreviewCard extends StatefulWidget {
  const _StableLinkPreviewCard({
    super.key,
    required this.url,
    required this.isUser,
  });
  final String url;
  final bool isUser;

  @override
  State<_StableLinkPreviewCard> createState() => _StableLinkPreviewCardState();
}

class _StableLinkPreviewCardState extends State<_StableLinkPreviewCard> {
  late Future<LinkPreviewData> _future;

  @override
  void initState() {
    super.initState();
    _future = LinkPreviewService.instance.fetchPreview(widget.url);
  }

  @override
  void didUpdateWidget(covariant _StableLinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = LinkPreviewService.instance.fetchPreview(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LinkPreviewData>(
      future: _future,
      builder: (context, snapshot) {
        final theme = TideTheme.of(context);
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _previewLoading(theme);
        }
        if (!snapshot.hasData) return const SizedBox.shrink();
        final data = snapshot.data!;
        return data.type == LinkType.web
            ? WebLinkCard(data: data, isUser: widget.isUser)
            : VideoShareCard(data: data, isUser: widget.isUser);
      },
    );
  }

  Widget _previewLoading(TideTheme theme) {
    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * .75,
      ),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.buttonSecondary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.textWeak,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '正在加载链接预览...',
              style: TextStyle(
                fontSize: 12,
                color: theme.textWeak,
                fontFamily: 'TideFont',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatRoomPage extends StatefulWidget {
  final Map<String, dynamic> botData;
  final String? initialMessageId;
  final bool openModelSettings;
  const ChatRoomPage({
    super.key,
    required this.botData,
    this.initialMessageId,
    this.openModelSettings = false,
  });
  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  ModalRoute<dynamic>? _chatRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _chatRoute) return;
    AppState.chatRouteObserver.unsubscribe(this);
    _chatRoute = route;
    if (route != null) AppState.chatRouteObserver.subscribe(this, route);
  }

  void _showChat() {
    if (_chatRoute?.isCurrent != true) return;
    AppState.showChat(_bot['id']?.toString() ?? '', this);
    unawaited(_markReadIfVisible());
  }

  Future<void> _markReadIfVisible() async {
    final botId = _bot['id']?.toString() ?? '';
    if (AppState.isViewingChat(botId)) {
      await MessageDeliveryService.instance.markRead(botId);
    }
  }

  @override
  void didPush() => _showChat();

  @override
  void didPopNext() {
    _showChat();
    _loadChatPreferences();
    unawaited(_syncLatestMessages());
  }

  @override
  void didPushNext() => AppState.hideChat(this);

  @override
  void didPop() => AppState.hideChat(this);

  final TextEditingController _msgC = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scrollC = ScrollController();
  List<Map<String, dynamic>> _msgs = [];
  bool _isRecording = false;
  final _sendVoiceCooldown = SendVoiceCooldown();
  bool _loading = false;
  bool _typing = false;
  bool _msgsLoading = true;
  final AudioRecorder _rec = AudioRecorder();
  late final AudioPlayer _player;
  StreamSubscription<Duration>? _audioPositionSub;
  StreamSubscription<Duration>? _audioDurationSub;
  StreamSubscription<PlayerState>? _audioStateSub;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;
  String? _playingAudioPath;
  bool _audioPlaying = false;
  Timer? _recTimer;
  int _recSecs = 0;
  String? _customBg;
  bool _showMessageTime = true;
  bool _dimParentheticalText = true;
  bool _showChatAvatar = false;
  bool _showSearchSources = false;
  late Map<String, dynamic> _bot;
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  String? _highlightedMessageId;
  int _initialMessageLocateAttempts = 0;
  StreamSubscription<ChatEvent>? _chatEvents;

  late AnimationController _bottomBarCtrl;
  late AnimationController _emojiPanelCtrl;
  bool _emojiPanelMounted = false;
  bool _hasText = false;
  // Attachments are staged above the composer and sent together on confirmation.
  final List<String> _pendingImages = [];
  final List<String> _pendingDocuments = [];
  _PendingExpression? _pendingExpression;
  String? _pendingMediaContext;
  static const double _inputBarHeight = 76;
  static const double _emojiPanelHeight = 286;
  bool _showEmojiPanel = false;
  int _emojiTab = 0;
  String _emojiCategory = 'people';
  bool _emojiCatalogLoading = false;
  List<_EmojiAsset> _emojiCatalog = const <_EmojiAsset>[];
  List<Map<String, dynamic>> _stickers = const <Map<String, dynamic>>[];
  final Map<String, String> _emojiNamesByGlyph = <String, String>{};
  bool _stickersLoaded = false;

  // Collect consecutive sends before generation; input activity extends the
  // quiet window. Supersede only turns that have not committed a reply/tool.
  int _requestGen = 0;
  String _queuedText = '';
  final List<String> _queuedImages = [];
  final List<String> _queuedDocuments = [];
  String? _queuedMediaContext;

  bool _queued = false;

  final _messageDebounce = ChatMessageDebounce();
  final _debounceClock = Stopwatch()..start();
  final List<Map<String, dynamic>> _queuedMessages = [];
  int _pendingQueueWrites = 0;
  String _lastInputText = '';
  TextRange _lastComposing = TextRange.empty;
  AICancellationToken? _activeRequestToken;
  ChatTurnCommit? _activeTurn;
  String? _queuedAudioPath;
  bool _queuedForceSingleReply = false;

  Future<void> _waitForMessagePause() async {
    // A saved turn must still be sent if the user leaves this page. Navigation
    // ends the input wait, but queued inserts must finish before the snapshot.
    while ((mounted &&
            _messageDebounce.remaining(_debounceClock.elapsed) >
                Duration.zero) ||
        _pendingQueueWrites > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  ChatTypingLease? _typingLease;
  void _setTypingState(bool value) {
    final botId = _bot['id']?.toString() ?? '';
    if (botId.isEmpty) return;
    if (value) {
      if (_typingLease == null || _typingLease!.isClosed) {
        _typingLease = ChatTypingState.instance.begin(botId);
      }
    } else {
      _typingLease?.close();
      _typingLease = null;
    }
    _refreshTypingState();
  }

  void _refreshTypingState() {
    final active = ChatTypingState.instance.isTyping(
      _bot['id']?.toString() ?? '',
    );
    if (mounted && _typing != active) setState(() => _typing = active);
  }

  void _refreshVoiceCooldown() {
    if (mounted) setState(() {});
  }

  Future<void> _sendFromComposer() async {
    // Arm before _send clears the composer and swaps Send for the microphone.
    _sendVoiceCooldown.markSend();
    await _send();
  }

  void _msgChanged() {
    final value = _msgC.value;
    // Focus and cursor movement are not typing. Include IME composing changes.
    final changed =
        value.text != _lastInputText || value.composing != _lastComposing;
    _lastInputText = value.text;
    _lastComposing = value.composing;
    if (changed) {
      _messageDebounce.inputChanged(
        hasText: value.text.isNotEmpty,
        now: _debounceClock.elapsed,
      );
    }
    if (mounted) setState(() => _hasText = value.text.isNotEmpty);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bot = Map.from(widget.botData);
    _sendVoiceCooldown.addListener(_refreshVoiceCooldown);
    _highlightedMessageId = widget.initialMessageId;
    _msgC.addListener(_msgChanged);
    _inputFocus.addListener(_handleInputFocus);
    _player = AudioPlayer()
      ..positionUpdater = TimerPositionUpdater(
        interval: const Duration(milliseconds: 200),
        getPosition: () => _player.getCurrentPosition(),
      );
    _audioPositionSub = _player.onPositionChanged.listen((v) {
      if (!mounted) return;
      setState(() => _audioPosition = v);
    });
    _audioDurationSub = _player.onDurationChanged.listen((v) {
      if (!mounted) return;
      setState(() => _audioDuration = v);
    });
    _audioStateSub = _player.onPlayerStateChanged.listen((v) {
      if (!mounted) return;
      setState(() {
        _audioPlaying = v == PlayerState.playing;
        if (v == PlayerState.completed) {
          _audioPlaying = false;
          _playingAudioPath = null;
          _audioPosition = Duration.zero;
          _audioDuration = Duration.zero;
        }
      });
    });
    _chatEvents = ChatEventBus.instance.events.listen(_onChatEvent);
    _loadMsgs();
    ChatTypingState.instance.addListener(_refreshTypingState);
    _refreshTypingState();
    _loadBg();
    _loadChatPreferences();
    if (widget.openModelSettings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showModelSettings();
      });
    }
    // Proactive replies are scheduled by the persistent background service.
    // The chat page only refreshes persisted results.

    // 底部栏动画控制器
    _bottomBarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _emojiPanelCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    // 首帧后启动进场动画，否则 SlideTransition 会一直停在向下偏移 25% 的位置，
    // 这就是输入框一直偏下、"怎么调 padding 都不动"的根因。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bottomBarCtrl.forward();
    });
  }

  @override
  void dispose() {
    AppState.chatRouteObserver.unsubscribe(this);
    AppState.hideChat(this);
    _sendVoiceCooldown.removeListener(_refreshVoiceCooldown);
    _sendVoiceCooldown.dispose();
    ChatTypingState.instance.removeListener(_refreshTypingState);
    // A real request may still finish and persist its reply after navigation.
    // Its finally block releases the lease; a new process never inherits it.
    if (!_loading) {
      _typingLease?.close();
      _typingLease = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _chatEvents?.cancel();
    _deferredPersistedMessageIds.clear();
    _msgC.removeListener(_msgChanged);
    _inputFocus.removeListener(_handleInputFocus);
    _inputFocus.dispose();
    _msgC.dispose();
    _scrollC.dispose();
    _rec.dispose();
    _audioPositionSub?.cancel();
    _audioDurationSub?.cancel();
    _audioStateSub?.cancel();
    _player.dispose();
    _recTimer?.cancel();
    _bottomBarCtrl.dispose();
    _emojiPanelCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncLatestMessages();
    }
  }

  void _onChatEvent(ChatEvent event) {
    final botId = _bot['id']?.toString() ?? '';
    if (!mounted || event.botId != botId) return;
    final row = event.message == null
        ? null
        : Map<String, dynamic>.from(event.message!);
    final id = event.messageId ?? row?['id']?.toString() ?? '';
    if (row == null || id.isEmpty) return;
    // Persistence events arrive before sendMessage returns its final segments.
    // Foreground replies belong to the display queue until it finishes.
    if (_loading && row['role'] == 'assistant') return;
    final index = _msgs.indexWhere(
      (message) => message['id']?.toString() == id,
    );
    if (index < 0 && event.type != ChatEventType.inserted) return;
    setState(() {
      if (index >= 0) {
        row['_thought_expanded'] = _msgs[index]['_thought_expanded'];
        _msgs[index] = row;
      } else {
        _msgs.add(row);
      }
      _msgs = normalizeChatMessages(_msgs);
    });
    if (row['role'] == 'assistant') {
      unawaited(_markReadIfVisible());
    }
    _scrollDown();
  }

  bool _chatBackgroundCleared = false;
  void _loadBg() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bg = prefs.getString('chat_bg_${_bot['id']}');
      final exists = bg != null && bg.isNotEmpty && await File(bg).exists();
      if (mounted)
        setState(() {
          _customBg = exists ? bg : null;
          _chatBackgroundCleared = bg == '';
        });
    } catch (error) {
      AppLogService.instance.add('ERROR', '读取聊天背景失败：$error');
    }
  }

  void _loadChatPreferences() async {
    final db = DBManager();
    final showTime = await db.getKV('show_message_time');
    final dimParentheticalText = await db.getKV('dim_parenthetical_text');
    final showAvatar = await db.getKV('show_chat_avatar');
    final showSources = await db.getKV('show_web_search_sources');
    if (mounted) {
      setState(() {
        _showMessageTime = showTime != 'false';
        _dimParentheticalText = dimParentheticalText != 'false';
        _showChatAvatar = showAvatar == 'true';
        _showSearchSources = showSources == 'true';
      });
    }
  }

  void _loadMsgs() async {
    final revision = _messagesRevision;
    print('_loadMsgs called with bot ID: ${_bot['id']}');
    try {
      final db = DBManager();
      // 不要用 limit 截断历史：导出记录里明明存在，但前端只加载最近 100 条，
      // 导致打开长聊天后大量消息“消失”。这里拿全量，UI 侧用 reverse 只渲染最近一段。
      final msgs = await db.queryMessages(_bot['id'] as String);
      // 引用功能已废弃：不再为 reply_to_id 逐条补查历史消息，避免打开长聊天时
      // 触发大量顺序数据库查询并造成列表首帧卡顿。
      print('_loadMsgs success: got ${msgs.length} messages');
      // 初始数据库查询可能在用户已发送消息后才返回。不能直接覆盖 _msgs，      // 否则刚刚上屏的用户气泡会被旧查询结果抹掉，界面只剩“正在输入中”。
      if (mounted && !_loading && revision == _messagesRevision) {
        setState(() {
          final normalized = editableChatHistory(msgs);
          final byId = <String, Map<String, dynamic>>{
            for (final m in normalized)
              m['id']?.toString() ?? 'db_${m['timestamp']}': m,
          };
          for (final m in _msgs) {
            byId.putIfAbsent(
              m['id']?.toString() ?? 'local_${m['timestamp']}',
              () => m,
            );
          }
          _msgs = normalizeChatMessages(byId.values);
          _msgsLoading = false;
        });
        _locateInitialMessage();
      }
    } catch (e) {
      print('_loadMsgs error: $e');
      if (mounted) setState(() => _msgsLoading = false);
    }
    // The list uses reverse layout, so its initial scroll position is already at
    // the newest message. Do not schedule a visible post-frame jump here.
  }

  void _locateInitialMessage() {
    final id = _highlightedMessageId;
    if (id == null || id.isEmpty || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _highlightedMessageId != id) return;
      final context = _messageKeys[id]?.currentContext;
      if (context == null) {
        // ListView builds lazily. Move toward the target's reverse-list index,
        // then retry after that range has been laid out.
        final messageIndex = _msgs.indexWhere(
          (message) => message['id']?.toString() == id,
        );
        if (messageIndex < 0 ||
            !_scrollC.hasClients ||
            _initialMessageLocateAttempts >= 2) {
          return;
        }
        _initialMessageLocateAttempts++;
        final reverseIndex = _msgs.length - 1 - messageIndex;
        final estimatedOffset = (reverseIndex * 96.0).clamp(
          _scrollC.position.minScrollExtent,
          _scrollC.position.maxScrollExtent,
        );
        _scrollC
            .animateTo(
              estimatedOffset,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(_locateInitialMessage);
        return;
      }
      _initialMessageLocateAttempts = 0;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 280),
        alignment: 0.45,
      );
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted && _highlightedMessageId == id) {
          setState(() => _highlightedMessageId = null);
        }
      });
    });
  }

  void _handleInputFocus() {
    if (_inputFocus.hasFocus && _showEmojiPanel) {
      _setEmojiPanel(false);
    }
    // Emoji 键盘逻辑：有内容时不自动收起，无内容时自动收起
    if (!_inputFocus.hasFocus && !_hasText && _showEmojiPanel) {
      _setEmojiPanel(false);
    }
  }

  void _setEmojiPanel(bool visible) {
    if (visible) {
      if (_showEmojiPanel) return;
      _emojiPanelCtrl.stop();
      setState(() {
        _showEmojiPanel = true;
        _emojiPanelMounted = true;
      });
      unawaited(_emojiPanelCtrl.forward(from: 0));
    } else {
      if (!_showEmojiPanel && !_emojiPanelMounted) return;
      _emojiPanelCtrl.stop();
      setState(() => _showEmojiPanel = false);
      unawaited(
        _emojiPanelCtrl.reverse().whenComplete(() {
          if (mounted && !_showEmojiPanel && _emojiPanelCtrl.isDismissed) {
            setState(() => _emojiPanelMounted = false);
          }
        }),
      );
    }
    _scrollDown(animated: false);
  }

  void _scrollDown({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollC.hasClients) return;
      final target = _scrollC.position.minScrollExtent;
      if (animated) {
        _scrollC.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollC.jumpTo(target);
      }
    });
  }

  int _messagesRevision = 0;
  // IDs already persisted for the current foreground reply but not yet owned by
  // a visible bubble. The periodic database refresh must not append them early.
  final Set<String> _deferredPersistedMessageIds = <String>{};

  Future<void> _syncLatestMessages() async {
    if (!mounted || _loading) return;
    try {
      final botId = _bot['id']?.toString() ?? '';
      if (botId.isEmpty) return;
      final revision = _messagesRevision;
      final fresh = editableChatHistory(await DBManager().queryMessages(botId));
      if (!mounted || _loading || revision != _messagesRevision) return;
      final freshById = <String, Map<String, dynamic>>{
        for (final message in fresh) message['id']?.toString() ?? '': message,
      };
      final existingIds = <String>{
        for (final message in _msgs) message['id']?.toString() ?? '',
      };
      final additions = fresh.where((message) {
        final id = message['id']?.toString() ?? '';
        return !existingIds.contains(id) &&
            !_deferredPersistedMessageIds.contains(id);
      }).toList();
      var changed = false;
      setState(() {
        for (final message in _msgs) {
          final replacement = freshById[message['id']?.toString()];
          if (replacement != null &&
              message['is_streaming'] != true &&
              replacement['content']?.toString() !=
                  message['content']?.toString()) {
            message['content'] = replacement['content'];
            changed = true;
          }
        }
        if (additions.isNotEmpty) {
          _msgs.addAll(additions);
          _msgs = normalizeChatMessages(_msgs);
          changed = true;
        }
      });
      if (changed) _scrollDown(animated: false);
      await _markReadIfVisible();
    } catch (_) {}
  }

  /// 分段回复的句间自然等待。
  /// 基础延迟固定 500–1000ms（每句随机，模拟真人打字/阅读节奏）。
  /// 若用户在设置中开启了全局随机延迟（random_reply_delay_enabled），则在
  /// 基础延迟之上再叠加一段自定义随机延迟。
  Future<void> _applyRandomReplyDelay(DBManager db) async {
    // 基础分段延迟：500–1000ms。
    final baseMs = 500 + DateTime.now().microsecond.remainder(1000 - 500 + 1);
    var totalMs = baseMs;
    final enabled = await db.getKV('random_reply_delay_enabled') == 'true';
    if (enabled) {
      var minS =
          int.tryParse(
            await db.getKV('random_reply_delay_min_seconds') ?? '',
          ) ??
          0;
      var maxS =
          int.tryParse(
            await db.getKV('random_reply_delay_max_seconds') ?? '',
          ) ??
          2;
      final extraMin = (minS.clamp(0, 60)) * 1000;
      var extraMax = (maxS.clamp(minS, 60)) * 1000;
      if (extraMax < extraMin) extraMax = extraMin;
      final extraDelay =
          extraMin +
          DateTime.now().microsecond.remainder(extraMax - extraMin + 1);
      totalMs += extraDelay;
    }
    final generation = _requestGen;
    for (var elapsed = 0; elapsed < totalMs; elapsed += 50) {
      if (!mounted || generation != _requestGen) return;
      final remaining = totalMs - elapsed;
      await Future<void>.delayed(
        Duration(milliseconds: remaining < 50 ? remaining : 50),
      );
    }
  }

  bool get _hasBg => _customBg != null && _customBg!.isNotEmpty;

  Future<void> _onUserInteracted() async {
    final botId = _bot['id']?.toString() ?? '';
    if (botId.isEmpty) return;
    final db = await DBManager().database;
    await db.transaction(
      (txn) => ProactiveRequestGate.userActivity(txn, botId),
    );
  }

  // 手机操控确认流程已移除。
  Future<void> _sendEmoji(_EmojiAsset emoji) async {
    if (_loading) return;
    final botId = _bot['id']?.toString() ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    final message = <String, dynamic>{
      'id': 'emoji_$now',
      'bot_id': botId,
      'role': 'user',
      'type': 'emoji',
      'content': emoji.name,
      'file_path': emoji.asset,
      'timestamp': now,
    };
    setState(() => _msgs.add(message));
    _scrollDown();
    try {
      await MessageDeliveryService.instance.insert(message);
      await _send(noUserBubble: true, mediaContext: '[${emoji.name}]');
    } catch (error) {
      if (mounted) setState(() => _msgs.remove(message));
      GlobalNotice.show('发送表情失败：$error');
    }
  }

  Future<void> _sendSticker(Map<String, dynamic> sticker) async {
    if (_loading) return;
    final path = sticker['file_path']?.toString() ?? '';
    if (path.isEmpty || !File(path).existsSync()) {
      GlobalNotice.show('表情包文件不可用');
      return;
    }
    final botId = _bot['id']?.toString() ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    final message = <String, dynamic>{
      'id': 'sticker_$now',
      'bot_id': botId,
      'role': 'user',
      'type': 'sticker',
      'content': sticker['emotion']?.toString().trim() ?? '',
      'file_path': path,
      'timestamp': now,
    };
    setState(() => _msgs.add(message));
    _scrollDown();
    try {
      await MessageDeliveryService.instance.insert(message);
      await _send(
        noUserBubble: true,
        mediaContext:
            '[对方发送了一个表情包，表情包类型：${message['content'].toString().isEmpty ? '未分类' : message['content']}]',
      );
    } catch (error) {
      if (mounted) setState(() => _msgs.remove(message));
      GlobalNotice.show('发送表情包失败：$error');
    }
  }

  Future<void> _loadEmojiCatalog() async {
    if (_emojiCatalogLoading || _emojiCatalog.isNotEmpty) return;
    setState(() => _emojiCatalogLoading = true);
    try {
      final raw = await rootBundle.loadString('assets/emojitwo/emoji.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final chineseNames =
          jsonDecode(
                await rootBundle.loadString('assets/emojitwo/zh_names.json'),
              )
              as Map<String, dynamic>;
      final catalog = <_EmojiAsset>[];
      data.forEach((code, value) {
        final entry = value as Map<String, dynamic>;
        final category = entry['category']?.toString() ?? '';
        if (!_emojiCategoryIcons.containsKey(category)) return;
        final asset = 'assets/emojitwo/$code.png';
        final codePoints = (entry['code_points'] as Map?)
            ?.cast<String, dynamic>();
        final baseCode = codePoints?['base']?.toString() ?? code;
        final glyph = String.fromCharCodes(
          baseCode
              .split('-')
              .map((part) => int.tryParse(part, radix: 16) ?? 0)
              .where((point) => point > 0),
        );
        final name = chineseNames[code]?.toString().trim() ?? '';
        if (name.isEmpty) throw FormatException('表情缺少中文名称：$code');
        if (glyph.isNotEmpty) _emojiNamesByGlyph[glyph] = name;
        catalog.add(
          _EmojiAsset(
            asset: asset,
            category: category,
            name: name,
            glyph: glyph,
            order:
                int.tryParse(entry['emoji_order']?.toString() ?? '') ?? 99999,
          ),
        );
      });
      catalog.sort((a, b) => a.order.compareTo(b.order));
      if (mounted) setState(() => _emojiCatalog = catalog);
    } catch (error) {
      debugPrint('[emoji] catalog load failed: $error');
      if (mounted) GlobalNotice.show('表情资源加载失败');
    } finally {
      if (mounted) setState(() => _emojiCatalogLoading = false);
    }
  }

  void _toggleEmojiPanel() {
    final opening = !_showEmojiPanel;
    if (opening) {
      _inputFocus.unfocus();
      unawaited(_loadEmojiCatalog());
      if (!_stickersLoaded) unawaited(_loadStickers());
    }
    _setEmojiPanel(opening);
  }

  Future<void> _loadStickers() async {
    try {
      final stickers = await DBManager().queryStickers();
      if (mounted) {
        setState(() {
          _stickers = stickers;
          _stickersLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _stickersLoaded = true);
    }
  }

  Widget _localStickerPreview(
    String path, {
    required BoxFit fit,
    int? cacheWidth,
  }) {
    if (path.isEmpty || !File(path).existsSync()) {
      return const ColoredBox(
        color: Colors.transparent,
        child: Center(child: Icon(Icons.broken_image_outlined)),
      );
    }
    if (path.toLowerCase().endsWith('.svg')) {
      return SvgPicture.file(File(path), fit: fit);
    }
    return Image.file(File(path), fit: fit, cacheWidth: cacheWidth);
  }

  String _emojiToModelText(String text) {
    var result = text;
    final entries = _emojiNamesByGlyph.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final entry in entries) {
      result = result.replaceAll(entry.key, '[${entry.value}]');
    }
    return result;
  }

  void _selectEmoji(_EmojiAsset emoji) {
    final text = _msgC.text;
    if (text.isNotEmpty) {
      final selection = _msgC.selection;
      final offset = selection.isValid ? selection.start : text.length;
      final end = selection.isValid ? selection.end : text.length;
      final next = text.replaceRange(offset, end, emoji.glyph);
      _msgC.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: offset + emoji.glyph.length),
      );
      _setEmojiPanel(false);
      return;
    }
    _setEmojiPanel(false);
    unawaited(_sendEmoji(emoji));
  }

  void _selectSticker(Map<String, dynamic> sticker) {
    if (_msgC.text.trim().isNotEmpty) {
      setState(() {
        _pendingExpression = _PendingExpression.sticker(sticker);
      });
      _setEmojiPanel(false);
      return;
    }
    _setEmojiPanel(false);
    unawaited(_sendSticker(sticker));
  }

  Widget _emojiPicker(TideTheme theme) {
    final items = _emojiCatalog
        .where((emoji) => emoji.category == _emojiCategory)
        .toList(growable: false);
    return Material(
      color: theme.surfaceVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 286,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: _EmojiPanelTab(
                        selected: _emojiTab == 0,
                        icon: Icons.emoji_emotions_outlined,
                        label: 'Emoji',
                        primary: theme.primary,
                        muted: theme.iconMuted,
                        onTap: () => setState(() => _emojiTab = 0),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _EmojiPanelTab(
                        selected: _emojiTab == 1,
                        icon: Icons.sticky_note_2_outlined,
                        label: '我的表情',
                        primary: theme.primary,
                        muted: theme.iconMuted,
                        onTap: () => setState(() => _emojiTab = 1),
                      ),
                    ),
                    IconButton(
                      tooltip: '收起表情',
                      onPressed: _toggleEmojiPanel,
                      icon: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: theme.iconMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _emojiTab == 0
                    ? _emojiCatalogLoading
                          ? Center(
                              child: CircularProgressIndicator(
                                color: theme.primary,
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 7,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                  ),
                              itemCount: items.length,
                              itemBuilder: (_, index) {
                                final emoji = items[index];
                                return Tooltip(
                                  message: emoji.name,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () => _selectEmoji(emoji),
                                    child: Text(
                                      emoji.glyph.isEmpty
                                          ? emoji.name
                                          : emoji.glyph,
                                      style: const TextStyle(fontSize: 25),
                                    ),
                                  ),
                                );
                              },
                            )
                    : !_stickersLoaded
                    ? Center(
                        child: CircularProgressIndicator(color: theme.primary),
                      )
                    : _stickers.isEmpty
                    ? Center(
                        child: Text(
                          '暂无我的表情',
                          style: TextStyle(
                            color: theme.textWeak,
                            fontFamily: 'TideFont',
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 5,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                            ),
                        itemCount: _stickers.length,
                        itemBuilder: (_, index) {
                          final sticker = _stickers[index];
                          final path = sticker['file_path']?.toString() ?? '';
                          return InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => _selectSticker(sticker),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: _localStickerPreview(
                                path,
                                fit: BoxFit.cover,
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (_emojiTab == 0)
                SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    children: _emojiCategoryIcons.entries
                        .map((entry) {
                          final selected = _emojiCategory == entry.key;
                          return IconButton(
                            tooltip: entry.value.$2,
                            onPressed: () =>
                                setState(() => _emojiCategory = entry.key),
                            icon: Icon(
                              entry.value.$1,
                              color: selected ? theme.primary : theme.iconMuted,
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _send({
    List<String>? images,
    List<String>? documents,
    String? mediaContext,
    String? audioPath,
    _PendingExpression? expression,
    bool forceSingleReply = false,
    // 合并防抖重发时置 true：不再新增用户气泡/入库，仅用当前文本向模型统一请求。
    bool noUserBubble = false,
    String? queuedText,
    Map<String, dynamic>? retryTarget,
    List<Map<String, dynamic>>? batchedMessages,
  }) async {
    final inputImages = images;
    final inputDocuments = documents;
    final inputAudioPath = audioPath;
    final inputExpression = expression;
    final inputBatchedMessages = batchedMessages;
    final inputMediaContext = mediaContext;
    return await MediaStorageService.instance.withMediaUse(() async {
      var images = inputImages;
      var documents = inputDocuments;
      var audioPath = inputAudioPath;
      var expression = inputExpression;
      var batchedMessages = inputBatchedMessages;
      var mediaContext = inputMediaContext;

      images = await Future.wait(
        (images ?? (noUserBubble ? <String>[] : _pendingImages)).map(
          MediaStorageService.instance.resolve,
        ),
      );
      documents = await Future.wait(
        (documents ?? (noUserBubble ? <String>[] : _pendingDocuments)).map(
          MediaStorageService.instance.resolve,
        ),
      );
      if (audioPath != null)
        audioPath = await MediaStorageService.instance.resolve(audioPath);
      if (batchedMessages != null) {
        batchedMessages = await Future.wait(
          batchedMessages.map((message) async {
            final copy = Map<String, dynamic>.from(message);
            if (copy['file_path'] is String)
              copy['file_path'] = await MediaStorageService.instance.resolve(
                copy['file_path'] as String,
              );
            return copy;
          }),
        );
      }

      var text = queuedText ?? (noUserBubble ? '' : _msgC.text.trim());
      final preparedVideos = <PreparedVideoInput>[];
      final unregisteredSharedVideos = <String>{};
      AppLogService.instance.add(
        'AI_TRACE',
        '发送入口 bot=${_bot['id']} loading=$_loading queued=$_queued generation=$_requestGen',
      );

      images = List<String>.from(images);
      documents = List<String>.from(documents);
      if (!noUserBubble) {
        mediaContext ??= _pendingMediaContext;
        expression ??= _pendingExpression;
      }
      if (text.isEmpty &&
          images.isEmpty &&
          documents.isEmpty &&
          mediaContext == null &&
          expression == null) {
        if (mounted) setState(() => _hasText = false);
        return;
      }
      // Reserve the user turn before attachment work, debounce or history writes.
      await _onUserInteracted();
      if (!noUserBubble && images.isNotEmpty) {
        try {
          images = await _persistChatImages(images);
        } catch (error) {
          if (mounted) GlobalNotice.show('图片保存失败：$error');
          return;
        }
      }
      if (!noUserBubble && documents.any(isVideoAttachment)) {
        try {
          documents = await _persistChatVideos(documents);
        } catch (error) {
          if (mounted) GlobalNotice.show('视频保存失败：$error');
          return;
        }
        if (!mounted) return;
      }
      final botId = _bot['id']?.toString() ?? '';
      final now = DateTime.now().millisecondsSinceEpoch;
      final userMessages =
          batchedMessages ??
          _buildAttachmentMessages(
            botId: botId,
            timestamp: now,
            text: text,
            images: images,
            documents: documents,
          );
      if (expression != null) {
        userMessages.add(
          expression.toMessage(botId: botId, timestamp: now + 1),
        );
        final expressionContext = expression.modelContext;
        mediaContext = mediaContext == null
            ? expressionContext
            : '$mediaContext\n$expressionContext';
      }

      unawaited(EmotionStateService.instance.observeUserMessage(botId, text));

      // 检测告别词，立即触发世界书判断；否则重置5分钟计时器
      final farewellWords = ['再见', '拜拜', '晚安', '早点休息', 'bye', 'goodbye', '886'];
      // Keep the idle fallback; farewell review runs after this reply is persisted.
      WorldBookService.instance.resetConversationTimer(botId);

      // Save each bubble immediately; collect the turn before requesting.
      if (batchedMessages == null || !_messageDebounce.hasMessages) {
        _messageDebounce.addMessage(text, _debounceClock.elapsed);
      }
      if (_loading) {
        final queuedMessages = userMessages;
        if (_queued) {
          // 已有待重发队列，合并进同一批文本，避免产生多余第三次请求。
          final prev = _queuedText;
          _queuedText = text.isEmpty
              ? prev
              : (prev.isEmpty ? text : '$prev\n$text');
        } else {
          _queuedText = text;
        }
        _queuedImages.addAll(images);
        _queuedDocuments.addAll(documents);
        if (mediaContext != null) {
          _queuedMediaContext = [
            if (_queuedMediaContext != null) _queuedMediaContext,
            mediaContext,
          ].join('\n');
        }
        _queuedMessages.addAll(userMessages);
        _queuedAudioPath = audioPath ?? _queuedAudioPath;
        _queuedForceSingleReply |= forceSingleReply;
        _queued = true;
        if (_activeTurn?.supersede() ?? true) {
          _requestGen++;
          _activeRequestToken?.cancel();
        }
        _pendingQueueWrites++;
        if (mounted && !noUserBubble) {
          setState(() {
            _msgs.addAll(queuedMessages);
            _msgC.clear();
            _pendingImages.clear();
            _pendingDocuments.clear();
            _pendingExpression = null;
            _pendingMediaContext = null;
            _hasText = false;
          });
          _scrollDown();
        }
        try {
          for (final queuedMessage
              in noUserBubble ? <Map<String, dynamic>>[] : queuedMessages) {
            await MessageDeliveryService.instance
                .insert({
                  'id': queuedMessage['id'],
                  'bot_id': botId,
                  'role': 'user',
                  'type': queuedMessage['type'],
                  'content': queuedMessage['content'],
                  'file_path': queuedMessage['file_path'],
                  'mood': null,
                  'timestamp': queuedMessage['timestamp'],
                })
                .timeout(const Duration(seconds: 12));
          }
        } catch (e) {
          debugPrint('[send] persist queued user message failed: $e');
        } finally {
          _pendingQueueWrites--;
        }
        return;
      }

      // 本次请求的代次快照；若请求期间用户又发了新消息（_requestGen 变化），
      // 渲染前检测到过期则拦截本次结果，交由 finally 用合并文本统一重发。
      var myGen = _requestGen;
      var turn = ChatTurnCommit();
      _activeTurn = turn;
      var batchText = text;
      var batchImages = [...images];
      var batchDocuments = [...documents];
      var batchContext = mediaContext;

      if (!noUserBubble) {
        setState(() {
          _loading = true;
          _msgsLoading = false;
          for (final item in userMessages) {
            item['send_status'] = 'sending';
          }
          _msgs.addAll(userMessages);
          _msgC.clear();
          _pendingImages.clear();
          _pendingDocuments.clear();
          _pendingExpression = null;
          _pendingMediaContext = null;
          _hasText = false;
        });
      } else if (mounted) {
        setState(() {
          _loading = true;
          _msgsLoading = false;
        });
      }
      _scrollDown();

      try {
        if (!noUserBubble) {
          try {
            // chat_history 的真实字段是 type / file_path，不能把 UI 专用 image
            // 字段直接写库；否则 SQLite 会因“no column named image”静默失败。
            for (final userMessage in userMessages) {
              await MessageDeliveryService.instance
                  .insert({
                    'id': userMessage['id'],
                    'bot_id': botId,
                    'role': 'user',
                    'type': userMessage['type'],
                    'content': userMessage['content'],
                    'file_path': userMessage['file_path'],
                    'mood': null,
                    'timestamp': userMessage['timestamp'],
                  })
                  .timeout(const Duration(seconds: 12));
            }
          } catch (e) {
            debugPrint('[send] persist user message failed: $e');
          }
        }
        await _waitForMessagePause();
        if (_queued) {
          text = [
            text,
            _queuedText,
          ].where((part) => part.isNotEmpty).join('\n');
          images.addAll(_queuedImages);
          documents.addAll(_queuedDocuments);
          mediaContext = [
            if (mediaContext != null) mediaContext,
            if (_queuedMediaContext != null) _queuedMediaContext,
          ].join('\n');
          userMessages.addAll(_queuedMessages);
          audioPath = _queuedAudioPath ?? audioPath;
          forceSingleReply |= _queuedForceSingleReply;
          _clearMessageQueue();
        }
        myGen = _requestGen;
        turn = ChatTurnCommit();
        _activeTurn = turn;
        batchText = text;
        batchImages = [...images];
        batchDocuments = [...documents];
        batchContext = mediaContext;
        _messageDebounce.reset();
        _activeRequestToken = AICancellationToken();
        _setTypingState(true);
        AppLogService.instance.add(
          'AI_TRACE',
          '连续消息结算 bot=$botId messages=${userMessages.length} generation=$myGen',
        );
        final cm = _bot['chat_model']?.toString().trim() ?? '';
        if (cm.isEmpty) {
          final providers = await DBManager().queryChatProviders();
          if (providers.isEmpty) {
            throw StateError('未配置聊天模型，请先在 API 设置中添加远程模型');
          }
        }

        final documentNotices = <String>[];
        final framePaths = <String>[];
        final sharedVideos = <String, String>{};
        // The original message is already visible and saved. Media is only prepared
        // for the model, without extra user bubbles or download notifications.
        final resolver = PlatformVideoResolver();
        for (final link in resolver.extractLinks(text)) {
          if (myGen != _requestGen) return;
          try {
            final result = await resolver
                .parse(link)
                .timeout(const Duration(seconds: 45));
            if (result == null) continue;
            if (result.videoUrl != null) {
              final temporaryPath = await resolver.downloadVideo(
                result.videoUrl!,
                result.headers,
                audioUrl: result.audioUrl,
              );
              if (temporaryPath == null) {
                throw StateError('视频下载失败');
              }
              try {
                final directory = await getApplicationDocumentsDirectory();
                final folder = Directory('${directory.path}/chat_media/videos');
                await folder.create(recursive: true);
                final saved = await File(temporaryPath).copy(
                  p.join(
                    folder.path,
                    '${DateTime.now().microsecondsSinceEpoch}_share.mp4',
                  ),
                );
                unregisteredSharedVideos.add(saved.path);
                documents.add(saved.path);
                sharedVideos[saved.path] = link;
              } finally {
                try {
                  await File(temporaryPath).delete();
                } catch (_) {}
              }
            } else if (result.isGallery && result.imageUrls.isNotEmpty) {
              final downloaded = await resolver.downloadImages(result);
              try {
                images.addAll(await _persistChatImages(downloaded));
              } finally {
                for (final path in downloaded) {
                  try {
                    await File(path).delete();
                  } catch (_) {}
                }
              }
            } else {
              documentNotices.add('分享链接 $link 的媒体暂不可读取；仅可依据原文回应，不得声称已观看视频。');
            }
            if (result.title.isNotEmpty ||
                result.description?.isNotEmpty == true) {
              documentNotices.add(
                '分享内容（$link）：${result.title}\n${result.description ?? ''}',
              );
            }
          } catch (error) {
            AppLogService.instance.add('PLATFORM_MEDIA', '$link 处理失败：$error');
            documentNotices.add('分享链接 $link 的媒体获取失败；原文和链接仍有效，不得声称已观看视频。');
          }
        }
        if (myGen != _requestGen) return;
        for (final path in documents) {
          if (isVideoAttachment(path)) {
            final prefs = await SharedPreferences.getInstance();
            final modelId =
                (prefs.getString('video_model_$botId') ??
                        _bot['video_model']?.toString() ??
                        '')
                    .trim();
            try {
              AppLogService.instance.add(
                'VIDEO',
                '开始处理视频 mode=${modelId.isEmpty ? 'frames_audio' : 'original'}',
              );
              final videoId = 'VID${DateTime.now().microsecondsSinceEpoch}';
              final prepared = await prepareVideoInput(
                path: path,
                botId: botId,
                modelId: modelId,
                userText: text,
                videoId: videoId,
              );
              preparedVideos.add(prepared);
              final history = prefs.getStringList('video_history_$botId') ?? [];
              history.add(
                json.encode({
                  'id': videoId,
                  'timestamp': DateTime.now().millisecondsSinceEpoch,
                  'duration':
                      prepared.temporaryMedia?.duration ?? prepared.duration,
                  'analysis_context': prepared.context,
                  'frame_paths': prepared.frames,
                  'original_video_path': path,
                  'chat_attachment': !sharedVideos.containsKey(path),
                  if (sharedVideos.containsKey(path))
                    'platform_link': sharedVideos[path],
                  'is_preview': prepared.temporaryMedia?.isPreview ?? false,
                }),
              );
              if (history.length > 50)
                history.removeRange(0, history.length - 50);
              await prefs.setStringList('video_history_$botId', history);
              AppLogService.instance.add(
                'VIDEO',
                '视频上下文已准备 video=$videoId characters=${prepared.context.length} frames=${prepared.frames.length}',
              );
              unregisteredSharedVideos.remove(path);
              documentNotices.add(
                [
                  '[视频编号：$videoId]',
                  if (prepared.frames.isNotEmpty)
                    videoFrameSourceContext(
                      videoId,
                      firstImageNumber: images.length + framePaths.length + 1,
                      frameCount: prepared.frames.length,
                    ),
                  prepared.context,
                ].join('\n'),
              );
              framePaths.addAll(prepared.frames);
            } catch (error) {
              AppLogService.instance.add('VIDEO', '视频处理失败：$error');
              if (!sharedVideos.containsKey(path)) rethrow;
              AppLogService.instance.add('PLATFORM_MEDIA', '分享视频分析失败：$error');
              documentNotices.add(
                '分享链接 ${sharedVideos[path]} 的视频无法分析，不得声称已观看视频。',
              );
            }
          } else {
            documentNotices.add(await MediaPreprocessor().documentText(path));
          }
        }
        final contextParts = [
          if (mediaContext != null) mediaContext,
          ...documentNotices,
        ];
        final preparedContext = contextParts.isEmpty
            ? null
            : contextParts.join('\n\n');
        final modelText = preparedContext == null
            ? _emojiToModelText(text)
            : (text.isEmpty
                  ? preparedContext
                  : '${_emojiToModelText(text)}\n$preparedContext');

        if (myGen != _requestGen) {
          AppLogService.instance.add(
            'AI_TRACE',
            '媒体处理后停止发送 mounted=$mounted generation=$myGen current=$_requestGen queued=$_queued',
          );
          return;
        }
        AppLogService.instance.add(
          'AI_TRACE',
          '媒体上下文交给聊天模型 bot=$botId videos=${preparedVideos.length} characters=${modelText.length}',
        );
        // AIManager reads persisted, role-typed history. Partially revealed UI
        // rows must never be reused as a model transcript.
        debugPrint('[send] request start bot=$botId model=$cm');
        final db = DBManager();
        final streamEnabled = (await db.getKV('streaming_output')) != 'false';
        final streamSpeed =
            (int.tryParse(await db.getKV('streaming_speed') ?? '') ?? 50).clamp(
              1,
              100,
            );
        // Remote provider cold starts and tool calls can legitimately exceed 30 seconds.
        const requestTimeout = Duration(minutes: 5);
        final requestToken = _activeRequestToken!;
        final result = await AIManager()
            .sendMessage(
              botId: botId,
              text: modelText,
              imagePaths: [...images, ...framePaths],
              audioPath: audioPath,
              currentMessageIds: userMessages
                  .map((row) => row['id'].toString())
                  .toSet(),
              beginResponseCommit: () {
                if (myGen != _requestGen || requestToken.isCancelled)
                  return false;
                return turn.beginCommit();
              },
              forceSingleReply: forceSingleReply,
              notifyResponse: true,
              useJarvis: (await DBManager().getKV('jarvis_enabled')) == 'true',
              cancellationToken: requestToken,
              deferPluginDelivery: true,
              // Display timing is client-owned, including non-SSE providers and tools.
            )
            .timeout(
              requestTimeout,
              onTimeout: () {
                requestToken.cancel();
                throw TimeoutException('请求超过5分钟，已停止');
              },
            )
            .whenComplete(() => _setTypingState(false));

        if (myGen != _requestGen && !turn.isCommitted) return;
        if (result['success'] == true) {
          if (farewellWords.any((word) => text.toLowerCase().contains(word)) &&
              myGen == _requestGen &&
              turn.isCommitted) {
            unawaited(WorldBookService.instance.triggerMemoryJudgment(botId));
          }
          for (final item in userMessages) {
            item['send_status'] = 'sent';
          }
        }
        if (result['success'] != true) {
          final errorText = result['error']?.toString() ?? '模型请求失败，请检查配置和网络';
          final errorLog = result['error_log']?.toString() ?? errorText;
          AppLogService.instance.add('ERROR', '聊天请求失败：$errorLog');
          if (mounted) GlobalNotice.show(errorText);
          await _markTurnFailed(
            retryTarget == null ? userMessages : [retryTarget],
            errorLog: errorLog,
            errorText: errorText,
            errorCode: result['error_code']?.toString(),
          );
          return;
        }

        if (result['silent'] == true) {
          return;
        }
        if (retryTarget != null) {
          await DBManager().clearMessageError(retryTarget['id'].toString());
          retryTarget.remove('is_retrying');
          retryTarget.remove('error_log');
          retryTarget.remove('error_code');
          retryTarget.remove('error_text');
          retryTarget['send_status'] = 'sent';
          retryTarget['retry_status'] = 'none';
          if (mounted) setState(() {});
        }
        final persisted = (result['messages'] as List? ?? const [])
            .whereType<Map>()
            .map((message) => Map<String, dynamic>.from(message))
            .toList();
        final persistedIds = persisted
            .map((message) => message['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
        _deferredPersistedMessageIds.addAll(persistedIds);
        if (myGen != _requestGen || requestToken.isCancelled) {
          _deferredPersistedMessageIds.removeAll(persistedIds);
          return;
        }

        if (!mounted || myGen != _requestGen) return;
        for (var index = 0; index < persisted.length; index++) {
          if (!mounted || myGen != _requestGen) break;
          if (index > 0 && persisted[index]['reply_group_id'] != null) {
            await _applyRandomReplyDelay(db);
          }
          if (!mounted || myGen != _requestGen) break;
          final row = persisted[index];
          final fullContent = row['content']?.toString() ?? '';
          final reveal =
              streamEnabled &&
              (row['type'] == 'text' || row['type'] == 'inner_thought') &&
              fullContent.isNotEmpty;
          if (reveal) {
            row['content'] = '';
            row['is_streaming'] = true;
          }

          // 内心独白流式输出开始时自动展开
          final thoughtId = row['id']?.toString() ?? '';
          final isInnerThought = row['type'] == 'inner_thought';
          if (isInnerThought && reveal && thoughtId.isNotEmpty) {
            _expandedThoughtIds.add(thoughtId);
          }

          setState(() {
            final existing = _msgs.indexWhere((m) => m['id'] == row['id']);
            if (existing >= 0) {
              row['_thought_expanded'] = _msgs[existing]['_thought_expanded'];
              _msgs[existing] = row;
            } else {
              _msgs.add(row);
            }
            _msgs = normalizeChatMessages(_msgs);
          });
          _scrollDown();
          if (reveal) {
            await for (final content in chatStreamText(
              fullContent,
              streamSpeed,
            )) {
              if (!mounted || myGen != _requestGen) break;
              setState(() => row['content'] = content);
              _scrollDown(animated: false);
            }
            if (!mounted || myGen != _requestGen) return;
            setState(() => row.remove('is_streaming'));

            // 内心独白流式输出完成后自动折叠
            if (isInnerThought && thoughtId.isNotEmpty) {
              setState(() => _expandedThoughtIds.remove(thoughtId));
            }
          }
        }
        _deferredPersistedMessageIds.removeAll(persistedIds);
        await _syncLatestMessages();
        // Images and stickers are included in `messages` after being persisted by
        // AIManager. Rendering result metadata again would duplicate the same
        // media in the visible conversation.
        if (mounted) {
          unawaited(_markReadIfVisible());
        }
      } on AICancelledException {
        // Superseded turns are replayed without an error notice.
      } catch (e, st) {
        if (myGen != _requestGen && !turn.isCommitted) return;
        debugPrint('[send] failed: $e');
        debugPrint(st.toString());
        AppLogService.instance.add('ERROR', '发送流程失败：$e\n$st');
        final errorText = e is TimeoutException
            ? '请求超过5分钟，已停止'
            : e is StateError
            ? e.message.toString()
            : '处理或请求失败：$e';
        if (mounted) GlobalNotice.show(errorText);
        final errorLog = '${e.toString()}\n${st.toString()}';
        await _markTurnFailed(
          retryTarget == null ? userMessages : [retryTarget],
          errorLog: errorLog,
          errorText: errorText,
          errorCode: 'local',
        );
      } finally {
        for (final path in unregisteredSharedVideos) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
        for (final video in preparedVideos) {
          try {
            await video.cleanup();
          } catch (e) {
            debugPrint('[video] temporary media cleanup failed: $e');
          }
        }
        // Release synchronously, even if UI cleanup throws. No old request may
        // clear a lock owned by the queued request after the handoff.
        await MessageDeliveryService.instance.flushPluginMessages(botId);
        _loading = false;
        AppLogService.instance.add(
          'AI_TRACE',
          '发送流程释放 bot=$botId generation=$myGen queued=$_queued',
        );
        for (final message in _msgs) {
          message.remove('is_streaming');
        }
        _setTypingState(false);
        _deferredPersistedMessageIds.clear();
        if (mounted) setState(() {});
        _activeRequestToken = null;
        if (_queued && myGen != _requestGen && !turn.isCommitted) {
          // Replay the complete uncommitted turn, including its original photos.
          _queuedText = [
            batchText,
            _queuedText,
          ].where((part) => part.isNotEmpty).join('\n');
          _queuedImages.insertAll(0, batchImages);
          _queuedDocuments.insertAll(0, batchDocuments);
          _queuedMediaContext = [
            if (batchContext != null) batchContext,
            if (_queuedMediaContext != null) _queuedMediaContext,
          ].join('\n');
          _queuedMessages.insertAll(0, userMessages);
          _queuedAudioPath ??= audioPath;
          _queuedForceSingleReply |= forceSingleReply;
        }
        if (_queued) {
          _loading = true;
          while (_pendingQueueWrites > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          final mergedText = _queuedText;
          final mergedImages = [..._queuedImages];
          final mergedDocuments = [..._queuedDocuments];
          final mergedContext = _queuedMediaContext;
          final mergedMessages = [..._queuedMessages];
          final mergedAudio = _queuedAudioPath;
          final singleReply = _queuedForceSingleReply;
          _clearMessageQueue();
          _loading = false;
          await _send(
            noUserBubble: true,
            queuedText: mergedText,
            images: mergedImages,
            documents: mergedDocuments,
            mediaContext: mergedContext,
            audioPath: mergedAudio,
            forceSingleReply: singleReply,
            batchedMessages: mergedMessages,
          );
        } else {
          await _syncLatestMessages();
          if (mounted) _scrollDown();
        }
      }
    });
  }

  Future<void> _markTurnFailed(
    List<Map<String, dynamic>> messages, {
    required String errorLog,
    required String errorText,
    String? errorCode,
  }) async {
    for (final message in messages) {
      final id = message['id'].toString();
      final rows = [
        message,
        ..._msgs.where((row) => row['id'].toString() == id),
      ];
      for (final row in rows) {
        row['error_log'] = errorLog;
        row['error_code'] = errorCode;
        row['error_text'] = errorText;
        row['send_status'] = 'failed';
        row.remove('is_retrying');
      }
      try {
        await DBManager()
            .updateMessageError(
              id,
              errorLog: errorLog,
              errorCode: errorCode,
              errorMessage: errorText,
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  void _clearMessageQueue() {
    _queuedText = '';
    _queuedImages.clear();
    _queuedDocuments.clear();
    _queuedMessages.clear();
    _queuedMediaContext = null;
    _queuedAudioPath = null;
    _queuedForceSingleReply = false;
    _queued = false;
  }

  Future<void> _retryMessage(Map<String, dynamic> message) async {
    if (_loading) return;
    if (message['type'] == 'audio') {
      final path =
          message['audio']?.toString() ??
          message['file_path']?.toString() ??
          '';
      if (path.isEmpty) {
        GlobalNotice.show('语音文件不存在，请重新发送');
        return;
      }
      await _transcribeRecordedAudio(message, path);
      return;
    }

    final messageId = message['id'].toString();
    final text = message['content']?.toString().trim() ?? '';

    try {
      // 查找同一批次的所有消息（通过时间戳前缀匹配）
      final idPrefix = messageId.split('_').sublist(0, 2).join('_');
      final batchMessages = _msgs.where((m) {
        final id = m['id'].toString();
        return id.startsWith(idPrefix) && m['role'] == 'user';
      }).toList();

      // 删除失败的消息批次
      for (final msg in batchMessages) {
        await DBManager().deleteMessage(msg['id'].toString());
      }

      // 收集该批次的图片和文档
      final images = <String>[];
      final documents = <String>[];
      for (final msg in batchMessages) {
        final type = msg['type']?.toString() ?? 'text';
        final path = msg['file_path']?.toString();
        if (path != null && path.isNotEmpty) {
          if (type == 'image') {
            images.add(path);
          } else if (type == 'document' || type == 'video') {
            documents.add(path);
          }
        }
      }

      if (mounted) {
        setState(() {
          _msgs.removeWhere((m) {
            final id = m['id'].toString();
            return id.startsWith(idPrefix) && m['role'] == 'user';
          });
          _msgC.text = text;
          _hasText = text.isNotEmpty;
          _pendingImages.addAll(images);
          _pendingDocuments.addAll(documents);
        });
      }

      // 发送新消息
      await _send();
    } catch (e) {
      if (mounted) {
        GlobalNotice.show('重新发送失败：$e');
      }
    }
  }

  List<Map<String, dynamic>> _buildAttachmentMessages({
    required String botId,
    required int timestamp,
    required String text,
    required List<String> images,
    required List<String> documents,
  }) {
    final attachments = <Map<String, String>>[
      for (final path in images) {'type': 'image', 'path': path},
      for (final path in documents)
        {'type': isVideoAttachment(path) ? 'video' : 'document', 'path': path},
    ];
    if (attachments.isEmpty) {
      return [
        {
          'id': 'm_$timestamp',
          'bot_id': botId,
          'role': 'user',
          'type': 'text',
          'content': text,
          'file_path': null,
          'timestamp': timestamp,
        },
      ];
    }
    return [
      for (var index = 0; index < attachments.length; index++)
        {
          'id':
              'm_$timestamp'
              '_$index',
          'bot_id': botId,
          'role': 'user',
          'type': attachments[index]['type'],
          // Keep user text exactly once so history and model context do not repeat it.
          'content': index == 0 ? text : '',
          'file_path': attachments[index]['path'],
          'document_name': attachments[index]['type'] == 'document'
              ? attachments[index]['path']!.split(Platform.pathSeparator).last
              : null,
          'timestamp': timestamp + index,
        },
    ];
  }

  Future<void> _transcribeRecordedAudio(
    Map<String, dynamic> message,
    String audioPath,
  ) async {
    return await MediaStorageService.instance.withMediaUse(() async {
      audioPath = await MediaStorageService.instance.resolve(audioPath);

      final botId = _bot['id']?.toString() ?? '';
      if (botId.isEmpty || _loading) return;
      if (mounted) {
        setState(() => _loading = true);
        _scrollDown();
      }
      _activeTurn = null;
      _setTypingState(true);

      try {
        // Both primary-model STT and dedicated STT must persist the same text
        // that the reply and subsequent turns will read from chat history.
        final savedTranscript = message['content']?.toString().trim() ?? '';
        final transcript = savedTranscript.isNotEmpty
            ? savedTranscript
            : await AIManager()
                  .transcribeAudio(botId: botId, audioPath: audioPath)
                  .timeout(const Duration(seconds: 50), onTimeout: () => null);
        if (transcript == null || transcript.trim().isEmpty) {
          await _markTurnFailed(
            [message],
            errorLog: '语音转写失败或未配置可用的语音识别模型',
            errorText: '语音未识别成功，请检查模型配置后重新发送',
            errorCode: 'stt_failed',
          );
          if (mounted) GlobalNotice.show('语音未识别成功，可长按语音重新发送');
          return;
        }
        final recognizedText = transcript.trim();
        await DBManager().updateMessageContent(
          message['id'].toString(),
          recognizedText,
        );
        message['content'] = recognizedText;
        if (mounted) {
          setState(() {
            for (final row in _msgs) {
              if (row['id'] == message['id']) row['content'] = recognizedText;
            }
          });
        }
        if (mounted) setState(() => _loading = false);
        // The persisted user audio row is the current turn, including on retry.
        // Do not add a second user message or send the audio for another reading.
        await _send(
          queuedText: recognizedText,
          batchedMessages: [message],
          retryTarget: message,
          noUserBubble: true,
          forceSingleReply: true,
        );
      } catch (error, stack) {
        AppLogService.instance.add('STT', '语音处理失败：$error\n$stack');
        await _markTurnFailed(
          [message],
          errorLog: '$error\n$stack',
          errorText: '语音处理失败，请重新发送',
          errorCode: 'stt_failed',
        );
        if (mounted) GlobalNotice.show('语音处理失败，可长按语音重新发送');
      } finally {
        // Always release, including an early return/failed handoff to _send.
        // Closing an already released lease is safe and never clears another owner.
        _setTypingState(false);
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  // ========== 录音 ==========
  Future<void> _toggleRec() async {
    if (!_isRecording && _sendVoiceCooldown.isBlocked) return;
    try {
      if (_isRecording) {
        _recTimer?.cancel();
        final duration = _recSecs;
        final path = await _rec.stop();
        if (mounted) {
          setState(() {
            _isRecording = false;
            _recSecs = 0;
          });
        }
        if (path != null && path.isNotEmpty) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final m = <String, dynamic>{
            'id': 'm_$now',
            'bot_id': _bot['id'],
            'role': 'user',
            'type': 'audio',
            'content': '',
            'audio': path,
            'file_path': path,
            'mood': null,
            'duration': duration,
            'timestamp': now,
          };
          try {
            await MessageDeliveryService.instance
                .insert({
                  'id': m['id'],
                  'bot_id': m['bot_id'],
                  'role': 'user',
                  'type': 'audio',
                  'content': '',
                  'file_path': path,
                  'mood': null,
                  'duration': duration,
                  'timestamp': now,
                })
                .timeout(const Duration(seconds: 5));
          } catch (e) {
            debugPrint('[record] persist failed: $e');
          }
          if (mounted) {
            setState(() => _msgs.add(m));
            _scrollDown();
          }
          // A missing/failed STT setup simply leaves a playable audio message.
          unawaited(_transcribeRecordedAudio(m, path));
        }
        return;
      }

      if (!await AppPermissions.microphone(context)) return;
      // Permission dialogs can outlive a Send tap; recheck before starting.
      if (!mounted || _sendVoiceCooldown.isBlocked) return;

      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.wav, bitRate: 128000),
        path: path,
      );
      if (!mounted) return;
      setState(() => _isRecording = true);
      _recTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (mounted && _isRecording) {
          setState(() => _recSecs++);
        } else {
          t.cancel();
        }
      });
    } catch (e, st) {
      debugPrint('[record] failed: $e');
      debugPrint(st.toString());
      _recTimer?.cancel();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recSecs = 0;
        });
        GlobalNotice.show('[X] 录音不可用：$e', color: const Color(0xFFE74C3C));
      }
    }
  }

  Future<void> _sendPickedAudio(String path) async {
    final botId = _bot['id']?.toString() ?? '';
    if (botId.isEmpty || _loading) return;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(directory.path, 'chat_media', 'audio'));
      await folder.create(recursive: true);
      final destination = p.join(
        folder.path,
        '${DateTime.now().microsecondsSinceEpoch}_${p.basename(path)}',
      );
      await File(path).copy(destination);
      path = destination;
    } catch (error) {
      if (mounted) GlobalNotice.show('音频保存失败：$error');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final message = <String, dynamic>{
      'id': 'm_$now',
      'bot_id': botId,
      'role': 'user',
      'type': 'audio',
      'content': '',
      'audio': path,
      'file_path': path,
      'mood': null,
      'duration': 0,
      'timestamp': now,
    };
    try {
      await MessageDeliveryService.instance
          .insert({
            'id': message['id'],
            'bot_id': botId,
            'role': 'user',
            'type': 'audio',
            'content': '',
            'file_path': path,
            'mood': null,
            'duration': 0,
            'timestamp': now,
          })
          .timeout(const Duration(seconds: 5));
      if (mounted) {
        setState(() => _msgs.add(message));
        _scrollDown();
      }
      // Files chosen from the picker follow the same presentation path as
      // recordings: the source audio is never rendered as a document bubble.
      unawaited(_transcribeRecordedAudio(message, path));
    } catch (e) {
      debugPrint('[audio] persist selected file failed: $e');
      if (mounted) GlobalNotice.show('发送音频失败', color: const Color(0xFFE74C3C));
    }
  }

  // ========== 选择图片/文件 ==========
  void _pickMedia(BuildContext triggerContext) async {
    final r = await showTidePopover<String>(
      context: triggerContext,
      preferAbove: true,
      builder: (_) => const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TidePopoverItem(
            icon: Icons.camera_alt_outlined,
            label: '相机',
            value: 'camera',
          ),
          TidePopoverItem(
            icon: Icons.image_outlined,
            label: '照片',
            value: 'img',
          ),
          TidePopoverItem(
            icon: Icons.play_circle_outline_rounded,
            label: '视频',
            value: 'video',
          ),
          TidePopoverItem(
            icon: Icons.attach_file_rounded,
            label: '文件',
            value: 'file',
          ),
        ],
      ),
    );
    if (!mounted || r == null) return;
    if (r == 'camera') {
      try {
        final photo = await ImagePicker().pickImage(source: ImageSource.camera);
        if (photo == null || !mounted) return;
        final fixed = photo.path;
        if (mounted) setState(() => _pendingImages.add(fixed));
      } catch (error) {
        debugPrint('[camera] capture failed: $error');
        if (mounted) GlobalNotice.show('拍照失败，请重试');
      }
    } else if (r == 'img') {
      if (!await AppPermissions.photos(context, feature: '选择图片')) return;
      final selected = await ImagePicker().pickMultiImage();
      if (selected.isNotEmpty) {
        final fixed = <String>[];
        for (final image in selected) {
          fixed.add(image.path);
        }
        if (mounted) setState(() => _pendingImages.addAll(fixed));
      }
    } else if (r == 'video') {
      if (!await AppPermissions.photos(context, feature: '选择视频')) return;
      await _pickAndProcessVideo();
    } else if (r == 'file') {
      try {
        await Permission.storage.request();
      } catch (_) {}
      final fp = await FilePicker.platform.pickFiles(allowMultiple: true);
      final paths =
          fp?.files
              .map((file) => file.path)
              .whereType<String>()
              .where((path) => path.isNotEmpty)
              .toList() ??
          const <String>[];
      if (paths.isEmpty) return;
      final stagedImages = <String>[];
      final stagedDocuments = <String>[];
      for (final path in paths) {
        final extension = path.split('.').last.toLowerCase();
        const imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'};
        const audioExtensions = {'m4a', 'mp3', 'wav', 'aac', 'ogg', 'opus'};
        if (imageExtensions.contains(extension)) {
          stagedImages.add(path);
        } else if (audioExtensions.contains(extension)) {
          await _sendPickedAudio(path);
        } else {
          stagedDocuments.add(path);
        }
      }
      if (mounted && (stagedImages.isNotEmpty || stagedDocuments.isNotEmpty)) {
        setState(() {
          _pendingImages.addAll(stagedImages);
          _pendingDocuments.addAll(stagedDocuments);
        });
      }
    }
  }

  // ========== 视频处理 ==========
  Future<void> _pickAndProcessVideo() async {
    try {
      final video = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (video == null || !mounted) return;
      final directory = await getApplicationDocumentsDirectory();
      final folder = Directory('${directory.path}/chat_media/videos');
      await folder.create(recursive: true);
      final destination = p.join(
        folder.path,
        '${DateTime.now().microsecondsSinceEpoch}_${p.basename(video.path)}',
      );
      await File(video.path).copy(destination);
      if (!mounted) return;
      setState(() => _pendingDocuments.add(destination));
      unawaited(
        VideoPosterService.load(
          destination,
        ).then<void>((_) {}, onError: (Object error, StackTrace stack) {}),
      );
    } catch (error) {
      if (mounted) GlobalNotice.show('添加视频失败：$error');
    }
  }

  Future<List<String>> _persistChatVideos(List<String> paths) async {
    final directory = await getApplicationDocumentsDirectory();
    final folder = Directory('${directory.path}/chat_media/videos');
    await folder.create(recursive: true);
    final stored = <String>[];
    for (final path in paths) {
      if (!isVideoAttachment(path)) {
        stored.add(path);
        continue;
      }
      final source = File(path);
      if (!await source.exists()) throw FileSystemException('所选视频不可访问', path);
      final destination = source.parent.path == folder.path
          ? path
          : p.join(
              folder.path,
              '${DateTime.now().microsecondsSinceEpoch}_${p.basename(path)}',
            );
      if (destination != path) await source.copy(destination);
      stored.add(destination);
      unawaited(
        VideoPosterService.load(destination).then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            AppLogService.instance.add('VIDEO', '视频封面生成失败：$error');
          },
        ),
      );
    }
    return stored;
  }

  Future<List<String>> _persistChatImages(List<String> paths) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory('${documents.path}/chat_media/images');
    await directory.create(recursive: true);
    final stored = <String>[];
    for (var index = 0; index < paths.length; index++) {
      final source = File(paths[index]);
      if (!await source.exists()) {
        throw FileSystemException('所选图片不可访问', source.path);
      }
      // 直接复制原图，不做格式转换（转换留给 AI 请求时处理）
      final extension = paths[index].split('.').last.toLowerCase();
      final fileName =
          'chat_${DateTime.now().microsecondsSinceEpoch}_${index + 1}.$extension';
      final destination = File(p.join(directory.path, fileName));
      await source.copy(destination.path);
      stored.add(destination.path);
    }
    return stored;
  }

  final Set<String> _expandedThoughtIds = {};

  Widget _buildInnerThoughtBubble(TideTheme theme, Map<String, dynamic> msg) {
    final content = msg['content']?.toString() ?? '';
    final thoughtId = msg['id']?.toString() ?? '';
    final isExpanded = _expandedThoughtIds.contains(thoughtId);

    return GestureDetector(
      onTap: () {
        setState(() {
          if (isExpanded) {
            _expandedThoughtIds.remove(thoughtId);
          } else {
            _expandedThoughtIds.add(thoughtId);
          }
        });
      },
      onLongPress: () => _msgLongPress(msg), // 增加长按支持
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.bubbleAi,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '内心独白',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.textWeak,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 16,
                  color: theme.textWeak,
                ),
              ],
            ),
            if (isExpanded) ...[
              const SizedBox(height: 6),
              Text(
                content,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.textWeak.withValues(alpha: 0.8),
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ========== 图片预览 ==========
  Future<void> _saveImageToGallery(String path) async {
    try {
      final permission = await Permission.photos.request();
      if (!permission.isGranted && !permission.isLimited) {
        GlobalNotice.show('没有相册保存权限');
        return;
      }
      final dir = Directory('/storage/emulated/0/Pictures/TideBot');
      await dir.create(recursive: true);
      final ext = path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
      final target = File(
        '${dir.path}/tidebot_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await File(path).copy(target.path);
      GlobalNotice.show('图片已保存到手机相册');
    } catch (e) {
      GlobalNotice.show('保存图片失败');
    }
  }

  void _previewImg(String path) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (c, a, s) => ImageDetailPage(
          path: path,
          onSave: () => _saveImageToGallery(path),
        ),
        transitionsBuilder: (c, a, s, child) =>
            FadeTransition(opacity: a, child: child),
      ),
    );
  }

  // ========== 机器人信息弹窗 ==========
  void _showBotInfo() {
    final n = TextEditingController(text: _bot['name']);
    final d = TextEditingController(text: _bot['desc']);
    final p = TextEditingController(text: _bot['prompt']);
    String avatar = _bot['avatar']?.toString() ?? '';
    TideDialogs.show(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          // 更换头像：从相册选择并复制到应用目录
          Future<void> pickNewAvatar() async {
            try {
              final picker = ImagePicker();
              final img = await picker.pickImage(
                source: ImageSource.gallery,
                maxWidth: 512,
              );
              if (img != null) {
                String path = img.path;
                if (path.toLowerCase().endsWith('.heic') ||
                    path.toLowerCase().endsWith('.heif')) {
                  try {
                    final converted = await HeifConverter.convert(path);
                    if (converted != null) path = converted;
                  } catch (_) {}
                }
                if (!mounted) return;
                final dest = await selectBotAvatarCrop(context, path);
                if (mounted && dest != null) setSt(() => avatar = dest);
              }
            } catch (_) {}
          }

          return TideDialogSurface(
            backgroundColor: Colors.transparent,
            contentPadding: EdgeInsets.zero,
            content: TideDialogs.glassContent(
              context: ctx,
              children: [
                const Center(
                  child: Text(
                    '机器人信息',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 头像更换
                Center(
                  child: GestureDetector(
                    onTap: pickNewAvatar,
                    child: Stack(
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(36),
                            color: TideTheme.of(ctx).surfaceVariant,
                          ),
                          child: avatar.isNotEmpty
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(36),
                                  child: Image.file(
                                    File(avatar),
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : Center(
                                  child: Icon(
                                    Icons.person_rounded,
                                    color: TideTheme.of(ctx).iconMuted,
                                    size: 30,
                                  ),
                                ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: TideTheme.of(ctx).primary,
                            ),
                            child: const Icon(
                              Icons.edit_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    '点按头像可更换',
                    style: TextStyle(
                      fontSize: 11,
                      color: TideTheme.of(ctx).textWeak,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _mLabel('名字'), _mField(n),
                const SizedBox(height: 10), _mLabel('人格设定'),
                _mField(d, h: 80),
                const SizedBox(height: 10), _mLabel('说话方式'),
                _mField(p, h: 100),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: TideDialogs.glassButton(
                    '保存',
                    onTap: () async {
                      final botId = _bot['id'] as String;
                      _bot['name'] = n.text;
                      _bot['desc'] = d.text;
                      _bot['prompt'] = p.text;
                      _bot['avatar'] = avatar;
                      await DBManager().updateBot(botId, {
                        'name': n.text,
                        'desc': d.text,
                        'prompt': p.text,
                        'avatar': avatar,
                      });
                      Navigator.pop(ctx);
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ========== 模型设置弹窗 ==========
  // 需求#5显示模型名 / #6 TTS分开+音色 / #7 token实时反馈：统一改为 StatefulBuilder + 本地状态，点击即刷新
  void _showModelSettings() async {
    final providers = await DBManager().queryChatProviders();
    final sttProviders = await DBManager().querySttProviders();
    final ttsProviders = await DBManager().queryTtsProviders();
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final botId = _bot['id'] as String;
    // 当前选择（只读读取 DB，作为初始值；弹窗内实时状态交给 setSt 维护）
    // 聊天模型必须由用户明确选择；不能因为列表有 provider 就静默选中第一个。
    String curChat =
        prefs.getString('chat_model_$botId') ??
        ((_bot['chat_model'] as String?)?.trim() ?? '');
    String curBak = prefs.getString('backup_model_$botId') ?? '';
    String curVision = prefs.getString('vision_model_$botId') ?? '';
    String curImageGen = prefs.getString('image_gen_model_$botId') ?? '';
    String curStt =
        prefs.getString('stt_model_$botId') ??
        ((_bot['stt_model'] as String?)?.trim() ?? '');
    String curVideo =
        prefs.getString('video_model_$botId') ??
        ((_bot['video_model'] as String?)?.trim() ?? '');
    final jarvisOn = (await DBManager().getKV('jarvis_enabled')) == 'true';
    String curJarvis = prefs.getString('jarvis_model_$botId') ?? '';
    String curTts =
        prefs.getString('tts_model_$botId') ??
        ((_bot['tts_model'] as String?)?.isNotEmpty == true
            ? _bot['tts_model'] as String
            : '');
    int curTok =
        prefs.getInt('max_token_$botId') ??
        (_bot['max_tokens'] as int? ?? 10000);

    TideDialogs.show(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          // 选中项实时更新到内存 & 持久化，让界面即时刷新
          Future<void> pickModel(
            String key,
            String val, {
            bool isTts = false,
          }) async {
            setSt(() {});
            await prefs.setString(key, val);
            if (!isTts && key == 'chat_model_$botId') {
              _bot['chat_model'] = val;
              await DBManager().updateBot(botId, {'chat_model': val});
            }
            if (isTts && key == 'tts_model_$botId') {
              _bot['tts_model'] = val;
              await DBManager().updateBot(botId, {'tts_model': val});
            }
            if (key == 'stt_model_$botId') {
              _bot['stt_model'] = val;
              await DBManager().updateBot(botId, {'stt_model': val});
            }
            if (key == 'video_model_$botId') {
              _bot['video_model'] = val;
              await DBManager().updateBot(botId, {'video_model': val});
            }
            setSt(() {});
          }

          return TideDialogSurface(
            backgroundColor: Colors.transparent,
            contentPadding: EdgeInsets.zero,
            content: TideDialogs.glassContent(
              context: ctx,
              maxWidth: 0.9,
              children: [
                const Center(
                  child: Text(
                    '模型设置',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _mLabel('聊天模型'),
                        _modelPicker(ctx, providers, curChat, (v) async {
                          curChat = v;
                          await pickModel('chat_model_$botId', v);
                        }),
                        if (jarvisOn) ...[
                          _mLabel('AI军师辅助模型'),
                          _modelPicker(
                            ctx,
                            providers,
                            curJarvis.isEmpty ? curChat : curJarvis,
                            (v) async {
                              curJarvis = v;
                              await pickModel('jarvis_model_$botId', v);
                            },
                          ),
                        ],
                        _mLabel('备用模型'),
                        _modelPicker(ctx, providers, curBak, (v) async {
                          curBak = v;
                          await pickModel('backup_model_$botId', v);
                        }),
                        _mLabel('识图模型'),
                        _modelPicker(ctx, providers, curVision, (v) async {
                          curVision = v;
                          await pickModel('vision_model_$botId', v);
                        }, includePrimaryVision: true),
                        _mLabel('生图模型'),
                        _modelPicker(ctx, providers, curImageGen, (v) async {
                          curImageGen = v;
                          await pickModel('image_gen_model_$botId', v);
                        }),
                        // TTS 模型独立：从 tts_provider_list 读取，额外展示音色字段（可选，不配置则纯文字回复）
                        _mLabel('STT模型'),
                        _modelPicker(ctx, sttProviders, curStt, (v) async {
                          curStt = v;
                          await pickModel('stt_model_$botId', v);
                        }, includePrimaryStt: true),
                        _mLabel('视频解析模型'),
                        _modelPicker(ctx, providers, curVideo, (v) async {
                          curVideo = v;
                          await pickModel('video_model_$botId', v);
                        }, includePrimaryVideo: true),
                        _mLabel('TTS模型'),
                        _modelPicker(ctx, ttsProviders, curTts, (v) async {
                          curTts = v;
                          await pickModel('tts_model_$botId', v, isTts: true);
                        }),
                        _mLabel('最大上下文Token'),
                        _tokenField(ctx, curTok, (v) async {
                          curTok = v;
                          await prefs.setInt('max_token_$botId', v);
                          await DBManager().updateBot(botId, {'max_tokens': v});
                          setSt(() {});
                        }),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TideDialogs.glassButton('确定', onTap: () => Navigator.pop(ctx)),
              ],
            ),
          );
        },
      ),
    );
  }

  // token 选择字段，点击弹底部选择，选中后立即回调更新
  Widget _tokenField(
    BuildContext parentCtx,
    int cur,
    Future<void> Function(int) onPick,
  ) {
    Future<void> choose(int v) async {
      await onPick(v);
      if (mounted) setState(() {});
    }

    return GestureDetector(
      onTap: () {
        final c = TextEditingController(text: cur.toString());
        showTideSheet(
          context: parentCtx,
          height: 260,
          child: Column(
            children: [
              const SizedBox(height: 10),
              const Text(
                '最大上下文',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'TideFont',
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                title: const Text(
                  '10,000 token',
                  style: TextStyle(fontFamily: 'TideFont'),
                ),
                trailing: cur == 10000
                    ? Icon(Icons.check, color: TideTheme.of(parentCtx).primary)
                    : null,
                onTap: () {
                  Navigator.pop(parentCtx);
                  choose(10000);
                },
              ),
              ListTile(
                title: const Text(
                  '20,000 token',
                  style: TextStyle(fontFamily: 'TideFont'),
                ),
                trailing: cur == 20000
                    ? Icon(Icons.check, color: TideTheme.of(parentCtx).primary)
                    : null,
                onTap: () {
                  Navigator.pop(parentCtx);
                  choose(20000);
                },
              ),
              ListTile(
                title: const Text(
                  '自定义...',
                  style: TextStyle(fontFamily: 'TideFont'),
                ),
                onTap: () {
                  Navigator.pop(parentCtx);
                  TideDialogs.show(
                    context: parentCtx,
                    builder: (c2) => TideDialogSurface(
                      backgroundColor: Colors.transparent,
                      contentPadding: EdgeInsets.zero,
                      content: TideDialogs.glassContent(
                        context: c2,
                        children: [
                          const Text(
                            '自定义Token',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'TideFont',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            contextMenuBuilder: androidTextContextMenu,
                            controller: c,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              hintText: '输入token数量',
                              hintStyle: TextStyle(fontFamily: 'TideFont'),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(10),
                                ),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(10),
                                ),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(10),
                                ),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TideDialogs.glassButton(
                            '确定',
                            onTap: () {
                              final v = int.tryParse(c.text);
                              if (v != null && v > 0) choose(v);
                              Navigator.pop(c2);
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: TideTheme.of(parentCtx).surfaceVariant,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            cur >= 1000
                ? '${cur.toString().replaceAllMapped(RegExp(r'(?=(\d{3})+(?!\d))'), (m) => ',')} token'
                : '$cur token',
            style: TextStyle(
              fontSize: 14,
              color: TideTheme.of(parentCtx).textStrong,
              fontFamily: 'TideFont',
            ),
          ),
        ),
      ),
    );
  }

  // 模型选择器：普通模型显示「名字 · 模型名」，TTS 额外显示「音色」
  Widget _modelPicker(
    BuildContext ctx,
    List<Map<String, dynamic>> providers,
    String cur,
    Function(String) onPick, {
    bool includePrimaryVision = false,
    bool includePrimaryVideo = false,
    bool includePrimaryStt = false,
  }) {
    final sel = providers.firstWhereOrNull((p) => p['id'] == cur);
    final String disp;
    if (cur == '__use_primary_vision__') {
      disp = includePrimaryVideo ? '使用主模型解析' : '使用主模型识图';
    } else if (cur == '__use_primary_stt__') {
      disp = '使用主模型识别';
    } else if (sel != null) {
      final name = sel['name']?.toString() ?? '未选择';
      final model = sel['model']?.toString().trim() ?? '';
      final voice = sel['voice']?.toString().trim() ?? '';
      if (voice.isNotEmpty) {
        disp = '$name · $model · 音色:$voice';
      } else {
        disp = model.isNotEmpty ? '$name · $model' : name;
      }
    } else {
      disp = providers.isEmpty ? '无可用模型' : '未选择';
    }
    return GestureDetector(
      onTap: () {
        showTideSheet(
          context: ctx,
          height: 380,
          child: ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.block_rounded),
                title: const Text(
                  '不选择',
                  style: TextStyle(fontFamily: 'TideFont', fontSize: 14),
                ),
                subtitle: const Text(
                  '清除当前模型配置',
                  style: TextStyle(fontSize: 12, fontFamily: 'TideFont'),
                ),
                trailing: cur.isEmpty
                    ? Icon(Icons.check, color: TideTheme.of(ctx).primary)
                    : null,
                onTap: () {
                  onPick('');
                  Navigator.pop(ctx);
                },
              ),
              if (includePrimaryVision || includePrimaryVideo)
                ListTile(
                  leading: const Icon(Icons.visibility_rounded),
                  title: Text(
                    includePrimaryVideo ? '使用主模型解析' : '使用主模型识图（需要主模型支持识图）',
                    style: const TextStyle(
                      fontFamily: 'TideFont',
                      fontSize: 14,
                    ),
                  ),
                  trailing: cur == '__use_primary_vision__'
                      ? Icon(Icons.check, color: TideTheme.of(ctx).primary)
                      : null,
                  onTap: () {
                    onPick('__use_primary_vision__');
                    Navigator.pop(ctx);
                  },
                ),
              if (includePrimaryStt)
                ListTile(
                  leading: const Icon(Icons.mic_rounded),
                  title: const Text(
                    '使用主模型识别（需要主模型支持语音）',
                    style: TextStyle(fontFamily: 'TideFont', fontSize: 14),
                  ),
                  trailing: cur == '__use_primary_stt__'
                      ? Icon(Icons.check, color: TideTheme.of(ctx).primary)
                      : null,
                  onTap: () {
                    onPick('__use_primary_stt__');
                    Navigator.pop(ctx);
                  },
                ),
              for (var pv in providers)
                ListTile(
                  title: Text(
                    _providerTitle(pv),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'TideFont',
                      fontSize: 14,
                    ),
                  ),
                  subtitle: Text(
                    _providerSub(pv),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'TideFont',
                    ),
                  ),
                  trailing: cur == pv['id']
                      ? Icon(Icons.check, color: TideTheme.of(ctx).primary)
                      : null,
                  onTap: () {
                    onPick(pv['id'] as String);
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        );
      },
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: TideTheme.of(ctx).surfaceVariant,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            disp,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: TideTheme.of(ctx).textStrong,
              fontFamily: 'TideFont',
            ),
          ),
        ),
      ),
    );
  }

  String _providerTitle(Map<String, dynamic> p) {
    final name = p['name']?.toString() ?? '';
    return name;
  }

  String _providerSub(Map<String, dynamic> p) {
    final model = p['model']?.toString().trim() ?? '';
    final voice = p['voice']?.toString().trim() ?? '';
    if (voice.isNotEmpty) return '$model · 音色:$voice';
    return model;
  }

  // ========== 删除选项 ==========
  void _showDeleteOptions() {
    bool delMsgs = false;
    bool delMem = false;
    TideDialogs.show(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => TideDialogSurface(
          backgroundColor: Colors.transparent,
          contentPadding: EdgeInsets.zero,
          content: TideDialogs.glassContent(
            context: ctx,
            children: [
              const Text(
                '清理数据',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'TideFont',
                ),
              ),
              const SizedBox(height: 14),
              CheckboxListTile(
                value: delMsgs,
                onChanged: (v) => setSt(() => delMsgs = v ?? false),
                title: const Text(
                  '删除聊天记录',
                  style: TextStyle(fontFamily: 'TideFont'),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: delMem,
                onChanged: (v) => setSt(() => delMem = v ?? false),
                title: const Text(
                  '删除底层记忆',
                  style: TextStyle(fontFamily: 'TideFont'),
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TideDialogs.glassButton(
                      '取消',
                      onTap: () => Navigator.pop(ctx),
                      color: const Color(0xFFE8E8F0),
                      textColor: const Color(0xFF1C1C1E),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TideDialogs.glassButton(
                      '确认清除',
                      onTap: () async {
                        if (delMsgs) {
                          _messagesRevision++;
                          await DBManager().deleteMessages(
                            _bot['id'] as String,
                          );
                          if (mounted) {
                            setState(() {
                              _msgs.clear();
                              _deferredPersistedMessageIds.clear();
                            });
                          }
                        }
                        if (delMem) {
                          await DBManager().deleteMemories(
                            _bot['id'] as String,
                          );
                        }
                        Navigator.pop(ctx);
                        _loadMsgs();
                      },
                      color: const Color(0xFFE74C3C),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleAudio(String path) async {
    return await MediaStorageService.instance.withMediaUse(() async {
      path = await MediaStorageService.instance.resolve(path);
      try {
        if (_playingAudioPath != path) {
          setState(() {
            _playingAudioPath = path;
            _audioPosition = Duration.zero;
            _audioDuration = Duration.zero;
          });
          await _player.setSource(DeviceFileSource(path));
          final duration = await _player.getDuration();
          if (duration != null && duration > Duration.zero && mounted) {
            setState(() => _audioDuration = duration);
          }
          await _player.resume();
          return;
        }
        if (_audioPlaying) {
          await _player.pause();
        } else {
          await _player.resume();
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _playingAudioPath = null;
          _audioPlaying = false;
          _audioPosition = Duration.zero;
          _audioDuration = Duration.zero;
        });
        GlobalNotice.show(
          '无法播放这条语音：$e',
          color: Theme.of(context).colorScheme.error,
        );
      }
    });
  }

  String _formatAudioTime(Duration value) {
    final seconds = value.inSeconds;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _audioBubble({
    required String path,
    required bool isUser,
    required int fallbackSeconds,
    String transcript = '',
  }) {
    final active = _playingAudioPath == path;
    final position = active ? _audioPosition : Duration.zero;
    final duration = active && _audioDuration > Duration.zero
        ? _audioDuration
        : Duration(seconds: fallbackSeconds);
    final knownDuration = duration.inMilliseconds > 0;
    final max = knownDuration ? duration.inMilliseconds.toDouble() : 1.0;
    final value = knownDuration
        ? position.inMilliseconds.clamp(0, max.toInt()).toDouble()
        : 0.0;
    final foreground = isUser ? Colors.white : TideTheme.of(context).textStrong;
    final muted = isUser
        ? Colors.white.withValues(alpha: 0.78)
        : TideTheme.of(context).textWeak;
    final width = MediaQuery.sizeOf(context).width.clamp(250.0, 420.0) - 175;
    return Container(
      constraints: BoxConstraints(minWidth: 154, maxWidth: width),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(7, 5, 8, 5),
      decoration: BoxDecoration(
        color: isUser
            ? TideTheme.of(context).primary
            : TideTheme.of(context).buttonSecondary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  tooltip: active && _audioPlaying ? '暂停语音' : '播放语音',
                  onPressed: () => _toggleAudio(path),
                  icon: Icon(
                    active && _audioPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded,
                    color: foreground,
                    size: 25,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Slider(
                      min: 0,
                      max: max,
                      value: value,
                      onChanged: !active || !knownDuration
                          ? null
                          : (v) =>
                                _player.seek(Duration(milliseconds: v.round())),
                      activeColor: foreground,
                      inactiveColor: muted,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatAudioTime(position),
                          style: TextStyle(
                            color: muted,
                            fontSize: 11,
                            fontFamily: 'TideFont',
                          ),
                        ),
                        Text(
                          knownDuration ? _formatAudioTime(duration) : '语音',
                          style: TextStyle(
                            color: muted,
                            fontSize: 11,
                            fontFamily: 'TideFont',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (transcript.trim().isNotEmpty) ...[
            Divider(height: 1, color: muted.withValues(alpha: 0.55)),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 5),
              child: Text(
                transcript.trim(),
                style: TextStyle(
                  color: foreground,
                  fontSize: 13,
                  height: 1.4,
                  fontFamily: 'TideFont',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _callSummaryCard({
    required String content,
    required int duration,
    required bool failed,
    required VoidCallback onLongPress,
  }) {
    final theme = TideTheme.of(context);
    final hours = duration ~/ 3600;
    final minutes = (duration % 3600) ~/ 60;
    final seconds = duration % 60;
    final durationText = [
      if (hours > 0) '$hours 小时',
      if (minutes > 0 || hours > 0) '$minutes 分钟',
      if (hours == 0 && minutes == 0) '$seconds 秒',
    ].join(' ');
    const separator = '\n\n--- 通话原文 ---\n';
    final splitAt = content.indexOf(separator);
    final summary = splitAt < 0 ? content : content.substring(0, splitAt);
    final transcript = splitAt < 0
        ? ''
        : content.substring(splitAt + separator.length);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onLongPress: onLongPress,
          onTap: failed
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: Colors.transparent,
                      appBar: AppBar(
                        backgroundColor: Colors.transparent,
                        title: const Text('通话摘要'),
                      ),
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(summary, style: const TextStyle(height: 1.6)),
                            if (transcript.isNotEmpty) ...[
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Divider(),
                              ),
                              const Text(
                                '通话原文',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                transcript,
                                style: const TextStyle(height: 1.6),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: theme.isDark ? .46 : .72),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: failed
                    ? Colors.red.shade400
                    : Colors.white.withValues(alpha: .12),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  failed ? Icons.error_outline_rounded : Icons.call_end_rounded,
                  size: 17,
                  color: failed ? Colors.red.shade300 : Colors.white70,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    failed ? '通话已结束 · 摘要未生成' : '通话已结束 · $durationText',
                    style: const TextStyle(
                      color: Colors.white,
                      fontFamily: 'TideFont',
                    ),
                  ),
                ),
                if (!failed)
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white70,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ========== 长按消息 ==========
  void _msgLongPress(Map<String, dynamic> msg) {
    final text = msg['content']?.toString() ?? '';
    showTideSheet(
      context: context,
      height: 300,
      child: Builder(
        builder: (sheetContext) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          children: [
            const Center(
              child: Text(
                '消息操作',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'TideFont',
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.copy_rounded,
                color: TideTheme.of(sheetContext).primary,
              ),
              title: const Text('复制', style: TextStyle(fontFamily: 'TideFont')),
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                Navigator.pop(sheetContext);
              },
            ),
            if (msg['role'] == 'user' &&
                msg['error_log']?.toString().isNotEmpty == true)
              ListTile(
                leading: Icon(
                  Icons.refresh_rounded,
                  color: TideTheme.of(sheetContext).primary,
                ),
                title: const Text(
                  '重新发送',
                  style: TextStyle(fontFamily: 'TideFont'),
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _retryMessage(msg);
                },
              ),
            // 引用功能已移除，避免生成和维护 reply_to_id 关联。
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Color(0xFFE74C3C),
              ),
              title: const Text(
                '删除',
                style: TextStyle(
                  fontFamily: 'TideFont',
                  color: Color(0xFFE74C3C),
                ),
              ),
              onTap: () async {
                await DBManager().deleteMessage(msg['id'].toString());
                if (mounted) {
                  setState(
                    () => _msgs.removeWhere(
                      (item) => item['id'].toString() == msg['id'].toString(),
                    ),
                  );
                }
                if (sheetContext.mounted) Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _replyPreview(Map<String, dynamic> message) {
    final text = message['content']?.toString().trim() ?? '';
    if (text.isNotEmpty) return text;
    return switch (message['type']?.toString()) {
      'image' => '[图片]',
      'audio' => '[语音]',
      'document' => '[文档]',
      _ => '[消息]',
    };
  }

  Widget _replyCard(String replyId, bool isUser) {
    final original = _msgs.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['id']?.toString() == replyId,
      orElse: () => null,
    );
    final missing = original == null;
    final author = missing
        ? '原消息'
        : (original['role'] == 'user' ? '你' : _bot['name']?.toString() ?? 'TA');
    final preview = missing ? '[原消息已删除]' : _replyPreview(original);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: isUser
            ? Colors.white.withValues(alpha: 0.16)
            : TideTheme.of(context).surfaceVariant,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
            color: isUser ? Colors.white70 : TideTheme.of(context).primary,
            width: 3,
          ),
        ),
      ),
      child: Text(
        '$author：$preview',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: isUser ? Colors.white : TideTheme.of(context).textWeak,
          fontFamily: 'TideFont',
        ),
      ),
    );
  }

  // ========== 构建UI ==========
  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    // 背景优先级：单机器人自定义 > 全局主题背景 > 主题底色。
    // 有全局背景图时只增强前景对比度，不改变 2afdaae 的 Stack/Column 结构。
    final String? effBg = _hasBg ? _customBg : null;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: effBg != null
                ? Image.file(
                    File(effBg),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => theme.hasGlobalBackground
                        ? const SizedBox.expand()
                        : const DefaultChatBackground(),
                  )
                : theme.hasGlobalBackground && !_chatBackgroundCleared
                ? const SizedBox.expand()
                : const DefaultChatBackground(),
          ),
          Column(
            children: [
              _chatHeader(),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _emojiPanelCtrl,
                        builder: (context, _) => _chatBody(),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 16,
                      right: 16,
                      child: IncomingCallBanner(
                        botId: _bot['id']?.toString() ?? '',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: _composer()),
        ],
      ),
    );
  }

  Color _messageTimeColor(TideTheme theme) => theme.isDark
      ? Colors.white.withValues(alpha: .92)
      : Colors.black.withValues(alpha: .72);

  List<Shadow> _messageTimeShadows(TideTheme theme) => [
    Shadow(
      color: theme.isDark
          ? Colors.black.withValues(alpha: .72)
          : Colors.white.withValues(alpha: .78),
      blurRadius: 3,
    ),
  ];

  String? _headerColorPath;
  Color? _headerSample;
  int _headerColorRevision = 0;

  void _syncHeaderColor(String? path) {
    if (_headerColorPath == path) return;
    _headerColorPath = path;
    _headerSample = null;
    final revision = ++_headerColorRevision;
    if (path == null) return;
    unawaited(
      sampleChatHeaderColor(path).then((color) {
        if (!mounted || revision != _headerColorRevision) return;
        setState(() => _headerSample = color);
      }),
    );
  }

  Widget _chatHeader() {
    final theme = TideTheme.of(context);
    final path = _hasBg
        ? _customBg
        : !_chatBackgroundCleared && theme.hasGlobalBackground
        ? theme.globalBackground
        : null;
    _syncHeaderColor(path);
    final background = _headerSample == null
        ? theme.pageBackground
        : chatHeaderSurface(_headerSample!, dark: theme.isDark);
    final lightSurface = background.computeLuminance() > .45;
    final foreground = lightSurface
        ? const Color(0xFF24212A)
        : const Color(0xFFF5F2F7);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: background,
        statusBarIconBrightness: lightSurface
            ? Brightness.dark
            : Brightness.light,
        statusBarBrightness: lightSurface ? Brightness.light : Brightness.dark,
      ),
      child: ColoredBox(
        color: background,
        child: SafeArea(
          bottom: false,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.arrow_back_ios_rounded,
                      size: 20,
                      color: foreground,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _bot['name'] as String? ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'TideFont',
                          color: foreground,
                        ),
                      ),
                      if (_typing)
                        Text(
                          '正在输入中...',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.primary,
                            fontFamily: 'TideFont',
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.call_rounded,
                    size: 20,
                    color: theme.primary,
                  ),
                  onPressed: _openCallPreparation,
                ),
                IconButton(
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: foreground.withValues(alpha: .72),
                  ),
                  onPressed: _showDeleteOptions,
                ),
                IconButton(
                  icon: Icon(
                    Icons.settings_rounded,
                    size: 20,
                    color: foreground.withValues(alpha: .72),
                  ),
                  onPressed: _showModelSettings,
                ),
                IconButton(
                  icon: Icon(
                    Icons.menu_rounded,
                    size: 20,
                    color: foreground.withValues(alpha: .72),
                  ),
                  onPressed: _showBotInfo,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openCallPreparation() async {
    final botId = _bot['id']?.toString() ?? '';
    if (botId.isEmpty) return;

    // 这里只校验已选择的配置；当前没有实时 STT/TTS 运行时，
    // 因而不会开始录音、转写或播放伪造的通话音频。
    final prefs = await SharedPreferences.getInstance();
    final hasStt =
        (prefs.getString('stt_model_$botId') ??
                (_bot['stt_model']?.toString() ?? ''))
            .isNotEmpty;
    final hasTts =
        (prefs.getString('tts_model_$botId') ??
                (_bot['tts_model']?.toString() ?? ''))
            .isNotEmpty;

    if (!mounted || !await AppPermissions.microphone(context) || !mounted) {
      return;
    }

    final callCard = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute<Map<String, dynamic>>(
        builder: (_) => CallPage(
          bot: _bot,
          hasStt: hasStt,
          hasTts: hasTts,
          onOpenSettings: () {
            Navigator.of(context).pop();
            _showModelSettings();
          },
        ),
      ),
    );
    if (mounted && callCard != null) {
      final id = callCard['id']?.toString();
      if (id != null && !_msgs.any((message) => message['id'] == id)) {
        setState(() {
          _msgs = normalizeChatMessages([..._msgs, callCard]);
        });
        _scrollDown();
      }
    }
    await _syncLatestMessages();
  }

  String _errorSolution(dynamic code) {
    final raw = code?.toString().toLowerCase() ?? '';
    final detail = switch (raw) {
      '400' =>
        '请求格式不被接口接受：核对模型名称；兼容接口地址应以 /v1 结尾而不是再填写 /chat/completions；移除该模型不支持的图片、工具调用或超长字段后重试。',
      '401' => '密钥无效：重新粘贴完整 API Key，确认没有前后空格、过期密钥或把其他平台的 Key 填到了当前服务商。',
      '403' => '当前 Key 没有该模型或服务权限：到服务商控制台开通模型并确认账户/项目空间正确。',
      '402' => '账户余额或配额不足：到服务商后台检查余额、免费额度和并发配额，充值或切换已开通模型。',
      '404' =>
        '地址或模型不存在：检查 Base URL 是否重复包含 /v1、/chat/completions，确认模型 ID 与服务商控制台完全一致。',
      '408' || 'timeout' =>
        '请求超时：检查网络和服务端排队；降低回复长度或附件尺寸。主模型持续超时时，还要分别测试备用模型的 URL、Key 与模型名。',
      '409' => '请求与正在进行的任务冲突：等待当前请求结束后再发送，不要连续重复点击发送。',
      '413' => '请求内容过大：减少图片、文件文本或历史上下文，并确认最大上下文不超过模型实际窗口。',
      '422' => '字段语义校验失败：通常是模型不支持工具调用、视觉消息或指定音色。先用纯文本测试，再逐项开启功能。',
      '429' => '触发限流：等待服务商冷却时间，降低并发和发送频率；必要时切换备用模型。',
      '500' ||
      '502' ||
      '503' ||
      '504' => '服务商侧异常：查看服务商状态页并稍后重试；若备用模型也失败，请分别测试其连接。',
      'network' || 'dns' || 'connection refused' =>
        '无法建立网络连接：确认设备联网、DNS/代理可用、域名可解析，并检查 Base URL 不是网页或内网地址。',
      'ssl' || 'tls' || 'certificate' => 'HTTPS 证书校验失败：检查设备时间、证书有效性和代理是否注入证书。',
      'empty response' || 'invalid response' =>
        '服务端返回格式不是 OpenAI 兼容响应：检查接口类型和路径；部分模型需关闭工具调用或改用专用接口。',
      _ => '请打开完整日志定位 HTTP 状态与响应体，再按对应状态检查模型、接口地址、密钥、账户配额、网络或功能兼容性。',
    };
    return '$detail\n\n仍无法解决时，请复制完整日志，并同时提供服务商名称、模型名和发生时间。';
  }

  void _showErrorDetails(Map<String, dynamic> message) {
    final log = message['error_log']?.toString().trim();
    final content =
        message['error_text']?.toString() ??
        message['error_message']?.toString() ??
        message['content']?.toString() ??
        '请求失败';

    TideDialogs.show(
      context: context,
      builder: (ctx) => TideDialogSurface(
        title: const Text('请求错误详情', style: TextStyle(fontFamily: 'TideFont')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(content, style: const TextStyle(fontFamily: 'TideFont')),
              const SizedBox(height: 14),
              const Text(
                '完整报错日志',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              LogText(
                log?.isNotEmpty == true ? log! : '历史错误未保存完整日志。',
                color: TideTheme.of(ctx).textStrong,
              ),
              const SizedBox(height: 14),
              const Text('解决方法', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                _errorSolution(message['error_code']),
                style: const TextStyle(fontFamily: 'TideFont'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('复制日志'),
            onPressed: () {
              final copyText = log?.isNotEmpty == true
                  ? log!
                  : '$content\n\n${_errorSolution(message['error_code'])}';
              Clipboard.setData(ClipboardData(text: copyText));
              GlobalNotice.show('完整错误日志已复制');
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic>? _sharedPostPayload(Map<String, dynamic> message) {
    if (message['type']?.toString() != 'shared_post') return null;
    try {
      final raw = jsonDecode(message['content']?.toString() ?? '');
      return raw is Map ? Map<String, dynamic>.from(raw) : null;
    } catch (_) {
      return null;
    }
  }

  Widget _sharedPostCard(Map<String, dynamic> payload, bool isUser) {
    return _SharedPostCard(
      payload: payload,
      isUser: isUser,
      onPreviewImage: _previewImg,
    );
  }

  Widget _chatBody() {
    if (_msgsLoading) {
      return Center(
        child: CircularProgressIndicator(color: TideTheme.of(context).primary),
      );
    }
    return ListView.builder(
      key: const PageStorageKey<String>('chat_messages'),
      controller: _scrollC,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      // The composer already follows the keyboard. Reserve only the island
      // height plus a small gap so the last bubble sits just above it.
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        _inputBarHeight + (_emojiPanelHeight * _emojiPanelCtrl.value) + 8,
      ),
      itemCount: _msgs.length,
      itemBuilder: (ctx, i) {
        final m = _msgs[_msgs.length - 1 - i];
        final isUser = m['role'] == 'user';
        final type = m['type']?.toString() ?? 'text';
        final theme = TideTheme.of(context);

        // 内心独白单独处理
        if (type == 'inner_thought') {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [_buildInnerThoughtBubble(theme, m)],
            ),
          );
        }

        // 语音通话卡片单独处理
        if (type == 'voice_call_card') {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: isUser
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                VoiceCallCard(
                  message: m,
                  botName: _bot['name']?.toString() ?? '',
                  onLongPress: () => _msgLongPress(m),
                ),
              ],
            ),
          );
        }

        // 内存消息使用 image/audio；数据库历史使用 type/file_path，统一兼容两种来源。
        final filePath = m['file_path']?.toString();
        final imagePath =
            m['image']?.toString() ??
            ((m['type'] == 'image' || m['type'] == 'sticker')
                ? filePath
                : null);
        final emojiAsset = m['type'] == 'emoji' ? filePath : null;
        final audioPath =
            m['audio']?.toString() ?? (m['type'] == 'audio' ? filePath : null);
        final videoPath =
            (m['type'] == 'video' ||
                (m['type'] == 'document' &&
                    filePath != null &&
                    isVideoAttachment(filePath)))
            ? filePath
            : null;
        final hasVideo = videoPath?.isNotEmpty == true;
        final documentPath = m['type'] == 'document' && !hasVideo
            ? filePath
            : null;
        final hasImg = imagePath?.isNotEmpty == true;
        final hasAudio = audioPath?.isNotEmpty == true;
        final hasDocument = documentPath?.isNotEmpty == true;
        final hasPreviousDocument =
            i < _msgs.length - 1 &&
            _msgs[_msgs.length - 2 - i]['type'] == 'document';
        final documentName =
            m['document_name']?.toString().trim().isNotEmpty == true
            ? m['document_name'].toString()
            : (documentPath?.split(Platform.pathSeparator).last ?? '文档');
        final documentExt = documentName.contains('.')
            ? documentName.split('.').last.toUpperCase()
            : '文件';
        final isSticker = m['type'] == 'sticker';
        final isEmoji = m['type'] == 'emoji';
        // 表情包和固定 emoji 的 content 都是模型语义，绝不能作为正文显示。
        final hasSummary = m['type'] == 'call_summary';
        final txt = (isSticker || isEmoji)
            ? ''
            : ((m['content'] as String?) ?? '');
        final sharedPost = _sharedPostPayload(m);
        final replyId = m['reply_to_id']?.toString();
        final sources = _decodeSources(m['sources_json']);
        final ts = m['timestamp'] as int? ?? 0;
        // 流式占位气泡（id 以 stream_ 开头）会先用空内容上屏，之后才填充真实文字。
        // 它的时间不应展示，否则会出现“先出时间、后出内容”“一条消息两个时间”的观感。
        final isStreamingPlaceholder = (m['id']?.toString() ?? '').startsWith(
          'stream_',
        );
        // 只有气泡真正渲染出可见内容时才显示时间：图片/贴纸必须文件真实存在，
        // 文本必须非空，避免生成图片或分段等待时时间先出、内容后到。
        final imageExists = hasImg && File(imagePath!).existsSync();
        final hasVisibleContent =
            hasSummary ||
            isUser ||
            txt.isNotEmpty ||
            hasImg ||
            hasAudio ||
            hasDocument ||
            hasVideo ||
            replyId?.isNotEmpty == true ||
            sharedPost != null;
        final showTimeHere =
            _showMessageTime &&
            !isStreamingPlaceholder &&
            !isEmoji &&
            !isSticker &&
            hasVisibleContent;
        final showTimeForAssistant = showTimeHere && !isUser;
        final isRetrying =
            m['is_retrying'] == true || m['retry_status'] == 'retrying';
        final hasRetryFailure =
            m['retry_status'] == 'failed' ||
            m['error_log']?.toString().isNotEmpty == true;
        return GestureDetector(
          key: _messageKeys.putIfAbsent(
            m['id']?.toString() ?? 'local_$i',
            GlobalKey.new,
          ),
          onLongPress: hasSummary ? null : () => _msgLongPress(m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: _highlightedMessageId == m['id']?.toString()
                  ? TideTheme.of(context).primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: hasSummary
                ? _callSummaryCard(
                    content: txt,
                    duration: m['duration'] as int? ?? 0,
                    failed: m['mood'] == 'failed',
                    onLongPress: () => _msgLongPress(m),
                  )
                : Align(
                    alignment: isUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isUser && hasRetryFailure)
                              GestureDetector(
                                onTap: () => _showErrorDetails(m),
                                child: const Padding(
                                  padding: EdgeInsets.only(top: 8, right: 6),
                                  child: Icon(
                                    Icons.error_outline_rounded,
                                    color: Color(0xFFE74C3C),
                                    size: 22,
                                  ),
                                ),
                              ),
                            Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.75,
                              ),
                              child: Column(
                                crossAxisAlignment: isUser
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  if (_showChatAvatar)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: isUser
                                          ? CircleAvatar(
                                              radius: 14,
                                              backgroundColor: TideTheme.of(
                                                context,
                                              ).primary.withValues(alpha: 0.15),
                                              child: Icon(
                                                Icons.person_rounded,
                                                size: 16,
                                                color: TideTheme.of(
                                                  context,
                                                ).primary,
                                              ),
                                            )
                                          : TideBotAvatar(
                                              name:
                                                  _bot['name']?.toString() ??
                                                  'TideBot',
                                              path: _bot['avatar']?.toString(),
                                              size: 28,
                                            ),
                                    ),
                                  if (hasVideo) ChatVideoCard(path: videoPath!),
                                  if (hasDocument) ...[
                                    if (hasPreviousDocument)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 6,
                                          horizontal: 4,
                                        ),
                                        child: Divider(
                                          height: 1,
                                          color: TideTheme.of(context).border,
                                        ),
                                      ),
                                    GestureDetector(
                                      onTap: () async {
                                        try {
                                          if (documentPath == null ||
                                              !await File(
                                                documentPath,
                                              ).exists()) {
                                            GlobalNotice.show('文件不存在或已被清理');
                                            return;
                                          }
                                          await const MethodChannel(
                                            'tidebot.native.channel',
                                          ).invokeMethod<void>('openChatFile', {
                                            'path': documentPath,
                                          });
                                        } on PlatformException catch (error) {
                                          GlobalNotice.show(
                                            '打开文件失败：${error.message ?? '无法启动应用选择器'}',
                                          );
                                        } catch (_) {
                                          GlobalNotice.show('打开文件失败，请稍后重试');
                                        }
                                      },
                                      child: Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: isUser
                                              ? TideTheme.of(context).primary
                                              : TideTheme.of(
                                                  context,
                                                ).buttonSecondary,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          border: Border.all(
                                            color: isUser
                                                ? Colors.white.withValues(
                                                    alpha: .28,
                                                  )
                                                : TideTheme.of(context).border,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 38,
                                              height: 42,
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                color: isUser
                                                    ? Colors.white.withValues(
                                                        alpha: .18,
                                                      )
                                                    : TideTheme.of(
                                                        context,
                                                      ).primary.withValues(
                                                        alpha: .12,
                                                      ),
                                                borderRadius:
                                                    BorderRadius.circular(9),
                                              ),
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    Icons
                                                        .insert_drive_file_rounded,
                                                    size: 20,
                                                    color: isUser
                                                        ? Colors.white
                                                        : TideTheme.of(
                                                            context,
                                                          ).primary,
                                                  ),
                                                  Text(
                                                    documentExt,
                                                    style: TextStyle(
                                                      fontSize: 8,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: isUser
                                                          ? Colors.white
                                                          : TideTheme.of(
                                                              context,
                                                            ).primary,
                                                      fontFamily: 'TideFont',
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Flexible(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    documentName,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: isUser
                                                          ? Colors.white
                                                          : TideTheme.of(
                                                              context,
                                                            ).textStrong,
                                                      fontFamily: 'TideFont',
                                                    ),
                                                  ),
                                                  const SizedBox(height: 3),
                                                  Text(
                                                    '文件附件 · 点击选择应用打开',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: isUser
                                                          ? Colors.white70
                                                          : TideTheme.of(
                                                              context,
                                                            ).textWeak,
                                                      fontFamily: 'TideFont',
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (hasImg && imageExists)
                                    Padding(
                                      padding: txt.isNotEmpty
                                          ? const EdgeInsets.only(bottom: 8)
                                          : EdgeInsets.zero,
                                      child: GestureDetector(
                                        onTap: () => _previewImg(imagePath),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          child: isSticker
                                              ? SizedBox(
                                                  width: 112,
                                                  height: 112,
                                                  child: _localStickerPreview(
                                                    imagePath,
                                                    fit: BoxFit.cover,
                                                    cacheWidth: 224,
                                                  ),
                                                )
                                              : ChatImage(path: imagePath),
                                        ),
                                      ),
                                    )
                                  else if (hasImg && !isSticker)
                                    Container(
                                      width: 144,
                                      height: 72,
                                      alignment: Alignment.center,
                                      margin: const EdgeInsets.only(bottom: 4),
                                      decoration: BoxDecoration(
                                        color: TideTheme.of(
                                          context,
                                        ).buttonSecondary,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        '图片不可用',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: TideTheme.of(context).textWeak,
                                          fontFamily: 'TideFont',
                                        ),
                                      ),
                                    ),
                                  if (isEmoji && emojiAsset != null)
                                    SizedBox(
                                      width: 52,
                                      height: 52,
                                      child: emojiAsset.endsWith('.svg')
                                          ? SvgPicture.asset(emojiAsset)
                                          : Image.asset(emojiAsset),
                                    ),
                                  // 音频卡片：同一结构兼容用户与机器人语音；转写文字会显示在卡片下方。
                                  if (hasAudio)
                                    _audioBubble(
                                      path: audioPath!,
                                      isUser: isUser,
                                      fallbackSeconds:
                                          m['duration'] as int? ?? 0,
                                      transcript: txt,
                                    ),
                                  if (replyId != null && replyId.isNotEmpty)
                                    _replyCard(replyId, isUser),
                                  // 动态分享使用独立卡片，JSON 负载不会直接暴露为聊天正文。
                                  if (sharedPost != null)
                                    _sharedPostCard(sharedPost, isUser),
                                  // 链接预览卡片
                                  if (sharedPost == null &&
                                      !hasAudio &&
                                      !hasSummary &&
                                      txt.isNotEmpty)
                                    _buildTextWithLinkPreviews(txt, isUser),
                                  if ((isUser &&
                                          (m['send_status'] == 'sending' ||
                                              isRetrying ||
                                              showTimeHere)) ||
                                      (!isUser && showTimeForAssistant))
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (m['send_status'] == 'sending' ||
                                              isRetrying)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                right: 4,
                                              ),
                                              child: SizedBox(
                                                width: 10,
                                                height: 10,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 1.4,
                                                      color: TideTheme.of(
                                                        context,
                                                      ).textFaint,
                                                    ),
                                              ),
                                            ),
                                          if (showTimeHere)
                                            Text(
                                              fmtTime(ts),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: _messageTimeColor(
                                                  TideTheme.of(context),
                                                ),
                                                shadows: _messageTimeShadows(
                                                  TideTheme.of(context),
                                                ),
                                                fontFamily: 'TideFont',
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  if (isUser && isRetrying)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 2),
                                      child: Text(
                                        '重新发送中',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.white70,
                                          fontFamily: 'TideFont',
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (_showSearchSources &&
                            sources.isNotEmpty &&
                            _isFinalReplyMessage(m, i))
                          _sourceButton(sources.last),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  List<Map<String, String>> _decodeSources(dynamic raw) {
    if (raw == null || raw.toString().isEmpty) return [];
    try {
      final values = jsonDecode(raw.toString());
      if (values is! List) return [];
      final seenUrls = <String>{};
      return values
          .whereType<Map>()
          .map((item) {
            final title = item['title']?.toString().trim() ?? '';
            final url = item['url']?.toString().trim() ?? '';
            return <String, String>{
              'title': title.isEmpty ? '网页来源' : title,
              'url': url,
            };
          })
          .where((item) {
            final uri = Uri.tryParse(item['url']!);
            return uri != null &&
                (uri.scheme == 'http' || uri.scheme == 'https') &&
                seenUrls.add(uri.toString());
          })
          .toList();
    } catch (_) {
      return [];
    }
  }

  bool _isFinalReplyMessage(Map<String, dynamic> message, int reverseIndex) {
    if (message['role'] != 'assistant') return false;
    final group = message['reply_group_id']?.toString();
    if (group == null || group.isEmpty) return true;
    for (var offset = reverseIndex - 1; offset >= 0; offset--) {
      final next = _msgs[_msgs.length - 1 - offset];
      if (next['reply_group_id']?.toString() == group &&
          next['role'] == 'assistant') {
        return false;
      }
    }
    return true;
  }

  Widget _sourceButton(Map<String, String> source) {
    final theme = TideTheme.of(context);
    final uri = Uri.tryParse(source['url'] ?? '');
    return Padding(
      padding: const EdgeInsets.only(top: 2, left: 2),
      child: OutlinedButton.icon(
        onPressed: uri == null
            ? null
            : () => launchUrl(uri, mode: LaunchMode.externalApplication),
        icon: const Icon(Icons.public_rounded, size: 16),
        label: const Text('数据来源', style: TextStyle(fontFamily: 'TideFont')),
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.primary,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          side: BorderSide(color: theme.primary.withValues(alpha: .45)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
  // 音频时长由播放器进度组件统一显示.

  // 富文本解析：旁白括号灰化
  Widget _parseText(String text, bool isUser) {
    final codeBlockRegex = RegExp(r'```(\w*)\n([\s\S]*?)```', multiLine: true);

    final matches = codeBlockRegex.allMatches(text);
    if (matches.isEmpty) {
      return _renderPlainText(text, isUser);
    }

    final widgets = <Widget>[];
    int lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        final textPart = text.substring(lastEnd, match.start).trim();
        if (textPart.isNotEmpty) {
          widgets.add(_renderPlainText(textPart, isUser));
        }
      }

      final language = match.group(1)?.trim();
      final code = match.group(2)?.trim();

      if (code != null && code.isNotEmpty) {
        widgets.add(
          CodeCard(
            code: code,
            language: language?.isEmpty == true ? 'code' : language!,
            isUser: isUser,
          ),
        );
      }

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      final textPart = text.substring(lastEnd).trim();
      if (textPart.isNotEmpty) {
        widgets.add(_renderPlainText(textPart, isUser));
      }
    }

    return Column(
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _renderPlainText(String text, bool isUser) {
    final baseStyle = TextStyle(
      color: isUser ? Colors.white : TideTheme.of(context).textStrong,
      fontSize: 14,
      fontFamily: 'TideFont',
      height: 1.5,
    );
    final spans = <TextSpan>[];
    final reg = RegExp(r'\(.*?\)');
    final matches = _dimParentheticalText
        ? reg.allMatches(text)
        : const <RegExpMatch>[];
    int last = 0;
    for (final m in matches) {
      if (m.start > last) {
        spans.add(
          TextSpan(text: text.substring(last, m.start), style: baseStyle),
        );
      }
      spans.add(
        TextSpan(
          text: text.substring(m.start, m.end),
          style: baseStyle.copyWith(
            color: isUser
                ? Colors.white.withValues(alpha: 0.6)
                : TideTheme.of(context).textWeak,
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: baseStyle));
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isUser
            ? TideTheme.of(context).primary
            : TideTheme.of(context).bubbleAi,
        borderRadius: BorderRadius.circular(16),
      ),
      child: RichText(
        textHeightBehavior: const TextHeightBehavior(
          applyHeightToFirstAscent: false,
          applyHeightToLastDescent: false,
        ),
        text: TextSpan(children: spans),
      ),
    );
  }

  /// 构建包含链接预览的文本（新增方法）
  Widget _buildTextWithLinkPreviews(String text, bool isUser) {
    // 检测文本中的链接
    final urls = LinkPreviewService.extractUrls(text);

    if (urls.isEmpty) {
      // 没有链接，直接渲染普通文本
      return _parseText(text, isUser);
    }

    // 卡片补充预览，消息气泡完整保留分享原文和链接。
    return Column(
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        // 显示所有链接预览卡片
        for (final url in urls) _buildLinkPreviewCard(url, isUser),
        _parseText(text, isUser),
      ],
    );
  }

  /// 链接预览使用有状态子组件，future 只在 URL 变化时创建，避免消息列表重建时闪回加载态。
  Widget _buildLinkPreviewCard(String url, bool isUser) {
    return _StableLinkPreviewCard(key: ValueKey(url), url: url, isUser: isUser);
  }

  IconData _attachmentIcon(String path) {
    final extension = path.split('.').last.toLowerCase();
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(extension)) {
      return Icons.folder_zip_rounded;
    }
    if (const {
      'dart',
      'js',
      'ts',
      'py',
      'java',
      'kt',
      'cpp',
      'c',
      'html',
      'css',
      'json',
      'yaml',
      'yml',
      'xml',
      'md',
    }.contains(extension)) {
      return Icons.code_rounded;
    }
    if (const {'pdf', 'doc', 'docx', 'txt', 'rtf'}.contains(extension)) {
      return Icons.description_rounded;
    }
    if (const {'xls', 'xlsx', 'csv'}.contains(extension)) {
      return Icons.table_chart_rounded;
    }
    if (const {'mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'}.contains(extension)) {
      return Icons.audio_file_rounded;
    }
    if (const {'mp4', 'mov', 'mkv', 'avi', 'webm'}.contains(extension)) {
      return Icons.video_file_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  Widget _attachmentPreview(dynamic theme) {
    final paths = [..._pendingImages, ..._pendingDocuments];
    if (paths.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: paths.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final path = paths[index];
          final isImage = _pendingImages.contains(path);
          return SizedBox(
            width: isImage ? 62 : 140,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: isImage
                        ? Image(
                            image: photoImageProvider(path),
                            fit: BoxFit.cover,
                          )
                        : Tooltip(
                            message: path.split(Platform.pathSeparator).last,
                            child: Container(
                              color: theme.surfaceVariant,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    _attachmentIcon(path),
                                    size: 22,
                                    color: theme.primary,
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      path.split(Platform.pathSeparator).last,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: theme.textWeak,
                                        fontFamily: 'TideFont',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() {
                        _pendingImages.remove(path);
                        _pendingDocuments.remove(path);
                      }),
                      child: const Padding(
                        padding: EdgeInsets.all(3),
                        child: Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _pendingExpressionPreview(TideTheme theme) {
    final expression = _pendingExpression!;
    return SizedBox(
      height: 62,
      width: 62,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: expression.isEmoji
                  ? Image.asset(expression.path, fit: BoxFit.cover)
                  : _localStickerPreview(expression.path, fit: BoxFit.cover),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => setState(() => _pendingExpression = null),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // The panel remains mounted during its reverse animation, then releases
  // its reserved message space once it has fully left the screen.

  Widget _composer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _inputBar(),
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          child: AnimatedBuilder(
            animation: _emojiPanelCtrl,
            builder: (context, child) => SizedBox(
              height: _emojiPanelHeight * _emojiPanelCtrl.value,
              child: child,
            ),
            child: _emojiPanelMounted
                ? SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(0, 1),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: _emojiPanelCtrl,
                            curve: Curves.easeOutCubic,
                            reverseCurve: Curves.easeInCubic,
                          ),
                        ),
                    child: _emojiPicker(TideTheme.of(context)),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _inputBar() {
    final theme = TideTheme.of(context);
    final hasSendContent =
        _hasText ||
        _pendingImages.isNotEmpty ||
        _pendingDocuments.isNotEmpty ||
        _pendingExpression != null;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, .08), end: Offset.zero)
            .animate(
              CurvedAnimation(
                parent: _bottomBarCtrl,
                curve: Curves.easeOutCubic,
              ),
            ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          decoration: BoxDecoration(
            color: theme.surfaceVariant,
            borderRadius: BorderRadius.circular(27),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_pendingImages.isNotEmpty || _pendingDocuments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                  child: _attachmentPreview(theme),
                ),
              if (_pendingExpression != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                  child: _pendingExpressionPreview(theme),
                ),
              Row(
                children: [
                  Builder(
                    builder: (triggerContext) => IconButton(
                      tooltip: '图片和文件',
                      onPressed: () => _pickMedia(triggerContext),
                      icon: Icon(
                        Icons.add_rounded,
                        size: 26,
                        color: theme.iconMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      contextMenuBuilder: androidTextContextMenu,
                      focusNode: _inputFocus,
                      controller: _msgC,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      style: TextStyle(
                        fontSize: 15,
                        fontFamily: 'TideFont',
                        color: theme.textStrong,
                      ),
                      decoration: InputDecoration(
                        hintText: '发消息...',
                        hintStyle: TextStyle(
                          color: theme.textFaint,
                          fontSize: 14,
                          fontFamily: 'TideFont',
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _showEmojiPanel ? '收起表情' : '表情',
                    onPressed: _toggleEmojiPanel,
                    icon: Icon(
                      _showEmojiPanel
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.emoji_emotions_outlined,
                      size: 23,
                      color: _showEmojiPanel ? theme.primary : theme.iconMuted,
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(scale: animation, child: child),
                      ),
                      child: hasSendContent
                          ? IconButton(
                              key: const ValueKey('send'),
                              tooltip: '发送',
                              splashRadius: 22,
                              onPressed: _sendFromComposer,
                              icon: Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.primary,
                                ),
                                child: const Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          : IconButton(
                              key: const ValueKey('record'),
                              tooltip: _isRecording ? '结束录音' : '录音',
                              onPressed:
                                  !_isRecording && _sendVoiceCooldown.isBlocked
                                  ? null
                                  : _toggleRec,
                              icon: Icon(
                                Icons.mic_rounded,
                                size: 22,
                                color: _isRecording
                                    ? Colors.red
                                    : theme.iconMuted,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mLabel(String t) {
    final theme = TideTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(
        t,
        style: TextStyle(
          fontSize: 12,
          color: theme.textWeak,
          fontFamily: 'TideFont',
        ),
      ),
    );
  }

  Widget _mField(TextEditingController c, {double h = 40}) {
    final theme = TideTheme.of(context);
    return Container(
      height: h,
      decoration: BoxDecoration(
        color: theme.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
      ),
      child: TextField(
        contextMenuBuilder: androidTextContextMenu,
        controller: c,
        maxLines: null,
        expands: h > 50,
        style: TextStyle(
          fontSize: 14,
          color: theme.textStrong,
          fontFamily: 'TideFont',
        ),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.all(10),
          border: InputBorder.none,
        ),
      ),
    );
  }
}

class _EmojiPanelTab extends StatelessWidget {
  const _EmojiPanelTab({
    required this.selected,
    required this.icon,
    required this.label,
    required this.primary,
    required this.muted,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final Color primary;
  final Color muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? primary.withValues(alpha: .14) : Colors.transparent,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: selected ? primary : muted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? primary : muted,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontFamily: 'TideFont',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SharedPostCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool isUser;
  final ValueChanged<String> onPreviewImage;

  const _SharedPostCard({
    required this.payload,
    required this.isUser,
    required this.onPreviewImage,
  });

  @override
  State<_SharedPostCard> createState() => _SharedPostCardState();
}

class _SharedPostCardState extends State<_SharedPostCard> {
  bool _deleted = false;
  Map<String, dynamic>? _feed;

  String get _postId {
    final payload = widget.payload;
    return payload['post_id']?.toString().trim() ??
        payload['id']?.toString().trim() ??
        '';
  }

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final postId = _postId;
    if (postId.isEmpty) {
      if (mounted) setState(() => _deleted = true);
      return;
    }
    try {
      final feed = await feedMapFromPostId(postId);
      if (!mounted) return;
      setState(() {
        _deleted = feed == null;
        _feed = feed;
      });
    } catch (_) {
      if (mounted) setState(() => _deleted = true);
    }
  }

  Future<void> _open() async {
    if (_deleted) return;
    var feed = _feed;
    feed ??= await feedMapFromPostId(_postId);
    if (!mounted) return;
    if (feed == null) {
      setState(() {
        _deleted = true;
        _feed = null;
      });
      return;
    }
    openFeedDetail(context, feed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final isUser = widget.isUser;
    final payload = widget.payload;
    final author = (_feed?['user'] ?? payload['author'])?.toString().trim();
    final content = (_feed?['content'] ?? payload['content'])?.toString() ?? '';
    final imagePath =
        (_feed?['image'] ?? payload['image_path'])?.toString() ?? '';
    final timestamp = (payload['timestamp'] as num?)?.toInt();
    final imageExists = imagePath.isNotEmpty && File(imagePath).existsSync();
    final foreground = isUser ? Colors.white : theme.textStrong;
    final muted = isUser
        ? Colors.white.withValues(alpha: 0.76)
        : theme.textWeak;
    return GestureDetector(
      onTap: _deleted ? null : _open,
      child: Container(
        width: 245,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser
              ? theme.primary.withValues(alpha: 0.92)
              : theme.buttonSecondary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: _deleted
            ? Text(
                sharedPostDeletedUserCopy,
                style: TextStyle(color: muted, fontFamily: 'TideFont'),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.dynamic_feed_rounded,
                        size: 17,
                        color: foreground,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '分享的动态',
                          style: TextStyle(
                            color: foreground,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'TideFont',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    (author == null || author.isEmpty) ? '匿名' : author,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'TideFont',
                    ),
                  ),
                  if (timestamp != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      fmtTime(timestamp),
                      style: TextStyle(
                        color: muted,
                        fontSize: 11,
                        fontFamily: 'TideFont',
                      ),
                    ),
                  ],
                  if (content.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      content,
                      style: TextStyle(
                        color: foreground,
                        height: 1.35,
                        fontFamily: 'TideFont',
                      ),
                    ),
                  ],
                  if (imageExists) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () => widget.onPreviewImage(imagePath),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 144,
                          height: 144,
                          child: Image.file(File(imagePath), fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  ] else if (imagePath.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '图片已失效或不可访问',
                      style: TextStyle(
                        color: muted,
                        fontSize: 12,
                        fontFamily: 'TideFont',
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

extension _ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    try {
      return firstWhere(test);
    } catch (_) {
      return null;
    }
  }
}
