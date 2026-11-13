import 'plugin_service.dart';
import 'proactive_request_gate.dart';
import 'native_background_coordinator.dart';
import 'global_notice.dart';
import 'mimo_voice_clone.dart';
import 'audit_redaction.dart';
import 'tool_package_catalog.dart';
import 'tool_package_runtime.dart';
import 'media_storage_service.dart';
import 'chat_message_debounce.dart';
import 'image_upload_format.dart';
import 'deepseek_search.dart';
import 'minimax_tts.dart';
import 'call_speech.dart';
import 'voice_message_speech.dart';
import 'request_execution_lease.dart';
import 'ai_request_task.dart';
import 'proactive_contact.dart';
import 'memory_prompt_policy.dart';
import 'memory_retrieval_service.dart';
import 'memory_retrieval_policy.dart';
export 'ai_request_task.dart';
import 'diary_output.dart';
import 'daily_quote_output.dart';
import 'bot_vital_signs_service.dart';
import 'assistant_output_guard.dart';
import 'model_image.dart';
import 'bot_image_tool.dart';
import 'bot_image_request.dart';
import 'user_image_edit_tool.dart';

import 'dart:async';
import 'dart:convert';
import 'request_prompt_features.dart';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'db.dart';
import 'holiday_calendar_service.dart';
import 'message_delivery_service.dart';
import 'future_task_scheduler.dart';
import 'life_schedule_service.dart';
import 'media_preprocessor.dart';
import 'video_processing_service.dart';
import 'video_request.dart';
import 'video_response.dart';
import 'app_log_service.dart';
import 'bot_state.dart';
import 'emotion_state_service.dart';
import 'device_capability_service.dart';
import 'chat_content.dart';
import 'chat_protocol.dart';
import 'skill_runtime.dart';
import 'skill_context.dart';
import 'skill_package.dart';
import 'world_book_service.dart';
import 'tool_call_accumulator.dart';
import 'tool_completion.dart';
import 'chat_request_context.dart';
import 'chat_cache_diagnostics.dart';
import 'voice_call_state_service.dart';

class AICancellationToken {
  AICancellationToken({this.beforeRequest});
  final Future<void> Function()? beforeRequest;

  Future<void> checkRequestAllowed() async {
    throwIfCancelled();
    await beforeRequest?.call();
    throwIfCancelled();
  }

  bool _cancelled = false;
  final List<void Function()> _callbacks = [];
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final callback in List<void Function()>.from(_callbacks)) {
      callback();
    }
    _callbacks.clear();
  }

  void addOnCancel(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void removeOnCancel(void Function() callback) => _callbacks.remove(callback);

  void throwIfCancelled() {
    if (_cancelled) throw const AICancelledException();
  }
}

class AICancelledException implements Exception {
  const AICancelledException();

  @override
  String toString() => 'AI 请求已取消';
}

class AIManager {
  static final AIManager _instance = AIManager._internal();
  factory AIManager() => _instance;
  AIManager._internal();

  // 结构化聊天结果供聊天室展示完整错误日志；旧 chat 接口继续返回纯文本。
  Future<Map<String, dynamic>> chatResult({
    required String botId,
    required List<Map<String, dynamic>> messages,
    String imageBase64 = '',
    void Function(String delta)? onDelta,
    // 合并/防抖重发时，被拦截的过期请求应跳过落库，避免库里出现“旧回复”，
    // 再由合并后的新请求统一落库，保证聊天记录与界面顺序一致。
    bool persistResponse = true,
  }) async {
    final lastUser = messages.lastWhere(
      (m) => m['role'] == 'user',
      orElse: () => {'content': ''},
    );
    final text = lastUser['content'] as String? ?? '';

    String? imgPath;
    if (imageBase64.isNotEmpty) {
      try {
        final directory = await getTemporaryDirectory();
        final tmpFile = File(
          '${directory.path}/tide_img_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await tmpFile.writeAsBytes(base64Decode(imageBase64));
        imgPath = tmpFile.path;
      } catch (_) {}
    }
    return sendMessage(
      botId: botId,
      text: text,
      imagePath: imgPath,
      onDelta: onDelta,
      persistResponse: persistResponse,
    );
  }

  Future<String> chat({
    required String botId,
    required List<Map<String, dynamic>> messages,
    String imageBase64 = '',
  }) async {
    final result = await chatResult(
      botId: botId,
      messages: messages,
      imageBase64: imageBase64,
    );
    return result['success'] == true
        ? result['reply']?.toString() ?? ''
        : result['error']?.toString() ?? '';
  }

  /// 主模型失败时自动尝试备用模型，并给予总计两次额外请求机会。
  /// 每次尝试均保持同一聊天上下文；失败信息只在最终结果中返回。
  static final _cacheDiagnostics = ChatCacheDiagnostics();
  static int _requestSequence = 0;

  void _logCacheUsage(
    Map usage, {
    required String stage,
    required String requestId,
    Map<String, dynamic> responseMetadata = const {},
  }) {
    final cached = cachedPromptTokens(usage);
    final prompt = usage['prompt_tokens'] ?? usage['input_tokens'];
    AppLogService.instance.addJson('CACHE', '分请求缓存统计', {
      'request_id': requestId,
      'stage': stage,
      ...responseMetadata,
      'usage': usage,
      'prompt_tokens': prompt,
      'cached_tokens': cached,
      'cache_creation_input_tokens':
          usage['cache_creation_input_tokens'] ??
          usage['cache_creation_tokens'],
      'cache_reported': cached != null,
    });
  }

  void _logRequestPrefix(
    String scope,
    String requestId,
    Map<String, dynamic> payload,
    Map<String, dynamic> window,
  ) {
    if (!AppLogService.instance.enabled) {
      _cacheDiagnostics.clear();
      return;
    }
    // 缓存诊断使用紧凑 JSON 格式，避免大量空行占用日志空间
    final diagnostics = {
      ..._cacheDiagnostics.record(
        scope: scope,
        requestId: requestId,
        payload: payload,
      ),
      'history_window': window,
    };
    AppLogService.instance.add(
      'CACHE',
      '完整请求前缀变化诊断\n${jsonEncode(diagnostics)}',
    );
  }

  Future<Map<String, dynamic>> sendMessage({
    required String botId,
    required String text,
    bool priority = true,
    String? imagePath,
    List<String>? imagePaths,
    List<String>? imageAttachments,
    String? audioPath,
    String? activeGame,
    bool persistResponse = true,
    Set<String> currentMessageIds = const {},
    bool Function()? beginResponseCommit,
    bool includeChatHistory = true,
    List<Map<String, dynamic>>? requestHistory,
    bool enableAutoSummary = true,
    bool skipLifeState = false,
    AIRequestTask task = AIRequestTask.chat,
    bool diaryTask = false,
    bool quoteTask = false,
    bool allowTools = true,
    bool allowStickers = true,
    bool forceSingleReply = false,
    bool notifyResponse = false,
    String extraSystemPrompt = '',
    bool isVoiceCall = false,
    bool useJarvis = false,
    AICancellationToken? cancellationToken,
    bool deferPluginDelivery = false,
    void Function(String delta)? onDelta,
  }) async {
    final activity = task == AIRequestTask.chat && !diaryTask && !quoteTask
        ? await ProactiveRequestGate.begin(await DBManager().database, botId)
        : null;
    if (activity != null) {
      AppLogService.instance.add(
        'PROACTIVE_GATE',
        '普通聊天开始，取消旧主动回复并占用请求：bot=$botId',
      );
    }
    try {
      if (activity != null) {
        await NativeBackgroundCoordinator.interruptProactiveReply(botId);
        unawaited(NativeBackgroundCoordinator.synchronize());
      }
      return await MessageDeliveryService.instance.afterReply(
        botId,
        () => MediaStorageService.instance.withMediaUse(() async {
          if (imagePath != null)
            imagePath = await MediaStorageService.instance.resolve(imagePath!);
          if (imagePaths != null)
            imagePaths = await Future.wait(
              imagePaths!.map(MediaStorageService.instance.resolve),
            );
          if (imageAttachments != null)
            imageAttachments = await Future.wait(
              imageAttachments!.map(MediaStorageService.instance.resolve),
            );
          if (audioPath != null)
            audioPath = await MediaStorageService.instance.resolve(audioPath!);

          cancellationToken?.throwIfCancelled();
          final executionLease = await RequestExecutionLease.acquire();
          try {
            if (diaryTask) task = AIRequestTask.diary;
            if (quoteTask) task = AIRequestTask.dailyQuote;
            diaryTask = task == AIRequestTask.diary;
            quoteTask = task == AIRequestTask.dailyQuote;
            if (task.internal) {
              persistResponse = false;
              includeChatHistory = false;
              requestHistory = null;
              enableAutoSummary = false;
              skipLifeState = true;
              allowTools = false;
              allowStickers = false;
              useJarvis = false;
              activeGame = null;
              onDelta = null;
              forceSingleReply = true;
            }
            final prefs = await SharedPreferences.getInstance();
            const primaryLocal = '';
            const backupLocal = '';
            final backupRemote = (prefs.getString('backup_model_$botId') ?? '')
                .trim();
            final matchingBots = (await DBManager().getAllBots())
                .where((bot) => bot['id']?.toString() == botId)
                .toList();
            final primaryRemote = matchingBots.isEmpty
                ? ''
                : (matchingBots.first['chat_model']?.toString().trim() ?? '');
            // 首次严格使用主模型；失败后优先使用备用模型，再给备用模型一次重试。
            // 过去主模型是远程时 provider 被错误置空，导致永远落到列表第一个服务商。
            final primary = {'local': primaryLocal, 'provider': primaryRemote};
            final backup = {'local': backupLocal, 'provider': backupRemote};
            bool configured(Map<String, String> candidate) =>
                candidate['local']!.isNotEmpty ||
                candidate['provider']!.isNotEmpty;
            // Never attempt an empty primary. A configured backup must be usable even
            // when the bot has no primary model selected.
            final attempts = <Map<String, String>>[
              if (configured(primary)) primary,
              if (configured(backup) &&
                  backup['provider'] != primary['provider'])
                backup,
            ];
            if (attempts.isEmpty) {
              return {'error': '未配置聊天模型，请先在角色设置中选择聊天或备用模型'};
            }

            final vitalTracked =
                persistResponse && !skipLifeState && activeGame == null;
            final vitalCutoff = DateTime.now().millisecondsSinceEpoch;
            if (vitalTracked) {
              AppLogService.instance.add('AI_TRACE', '请求前生活状态开始 bot=$botId');
              final vitalContext = await BotVitalSignsService.instance
                  .beforeRequest(botId, allowSilence: allowTools);
              AppLogService.instance.add('AI_TRACE', '请求前生活状态完成 bot=$botId');
              extraSystemPrompt = '$vitalContext\n$extraSystemPrompt';
            }
            try {
              Map<String, dynamic>? lastFailure;
              var attempted = 0;
              for (var index = 0; index < attempts.length; index++) {
                await cancellationToken?.checkRequestAllowed();
                final candidate = attempts[index];
                final selectedImagePaths = <String>[
                  if (imagePath?.isNotEmpty == true) imagePath!,
                  ...?imagePaths,
                  ...?imageAttachments,
                ];
                try {
                  attempted++;
                  final result = await _sendMessageOnce(
                    botId: botId,
                    text: text,
                    imagePath: selectedImagePaths.isEmpty
                        ? null
                        : selectedImagePaths.first,
                    imagePaths: selectedImagePaths,
                    audioPath: audioPath,
                    activeGame: activeGame,
                    persistResponse: persistResponse,
                    currentMessageIds: currentMessageIds,
                    beginResponseCommit: beginResponseCommit,
                    includeChatHistory: includeChatHistory,
                    requestHistory: requestHistory,
                    enableAutoSummary: enableAutoSummary,
                    skipLifeState: skipLifeState,
                    task: task,
                    diaryTask: diaryTask,
                    quoteTask: quoteTask,
                    allowTools: allowTools,
                    allowStickers: allowStickers,
                    forceSingleReply: forceSingleReply,
                    notifyResponse: notifyResponse,
                    extraSystemPrompt: extraSystemPrompt,
                    isVoiceCall: isVoiceCall,
                    useJarvis: useJarvis,
                    cancellationToken: cancellationToken,
                    // 不要为了备用重试延迟主请求的 SSE：此前首两次被强制关闭流式，
                    // 部分服务商在非流式模式下长期不返回，聊天室最终只看到超时。
                    onDelta: onDelta,
                    forcedLocalId: candidate['local']!,
                    forcedProviderId: candidate['provider']!,
                  );
                  if (result['success'] == true) {
                    if (vitalTracked)
                      await BotVitalSignsService.instance.afterRequest(
                        botId,
                        result,
                        vitalCutoff,
                      );
                    return result;
                  }
                  lastFailure = result;
                  final code =
                      int.tryParse(result['error_code']?.toString() ?? '') ?? 0;
                  final retryable =
                      result['error_code']?.toString() == 'network' ||
                      code == 429 ||
                      code >= 500;
                  if (!retryable || index == attempts.length - 1) break;
                } on AICancelledException {
                  rethrow;
                }
              }
              if (vitalTracked)
                BotVitalSignsService.instance.failedRequest(botId);
              return {
                ...?lastFailure,
                'error':
                    '模型请求未成功（实际尝试 $attempted 次）。${lastFailure?['error'] ?? ''}',
              };
            } catch (_) {
              if (vitalTracked)
                BotVitalSignsService.instance.failedRequest(botId);
              rethrow;
            }
          } finally {
            await executionLease.release();
          }
        }),
        deferDelivery: deferPluginDelivery,
      );
    } finally {
      if (activity != null) {
        try {
          await activity.release();
        } catch (error) {
          AppLogService.instance.add(
            'PROACTIVE_GATE',
            '普通聊天租约释放失败，将自动过期：$error',
          );
        }
        unawaited(NativeBackgroundCoordinator.synchronize());
        AppLogService.instance.add(
          'PROACTIVE_GATE',
          '普通聊天结束，按正常间隔等待下次主动回复：bot=$botId',
        );
      }
    }
  }

  Map<String, dynamic> _decodeToolArguments(dynamic raw) {
    final source = raw?.toString().trim() ?? '';
    if (source.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}

    // Some compatibility gateways concatenate an empty object with the actual
    // arguments (for example "{}{\"prompt\":...}"). Keep the last non-empty
    // JSON object instead of failing an otherwise valid tool invocation.
    final objects = <Map<String, dynamic>>[];
    var start = -1;
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          quoted = false;
        }
        continue;
      }
      if (char == '"') {
        quoted = true;
      } else if (char == '{') {
        if (depth++ == 0) start = i;
      } else if (char == '}' && depth > 0 && --depth == 0 && start >= 0) {
        try {
          final decoded = jsonDecode(source.substring(start, i + 1));
          if (decoded is Map) objects.add(Map<String, dynamic>.from(decoded));
        } catch (_) {}
        start = -1;
      }
    }
    final usable = objects.lastWhere(
      (item) => item.isNotEmpty,
      orElse: () => <String, dynamic>{},
    );
    if (usable.isNotEmpty) {
      AppLogService.instance.add('TOOLS', '已修复兼容接口返回的拼接工具参数');
      return usable;
    }
    throw const FormatException('工具参数不是合法 JSON');
  }

  String _stripResponsePrefix(String value) => cleanChatContent(value);

  String _extractChatContent(dynamic payload) {
    if (payload is! Map) return '';
    String fromValue(dynamic value) {
      if (value is String) return _stripResponsePrefix(value);
      if (value is List) {
        return value
            .map((item) {
              if (item is String) return item;
              if (item is Map)
                return item['text']?.toString() ??
                    item['content']?.toString() ??
                    '';
              return '';
            })
            .where((text) => text.trim().isNotEmpty)
            .join();
      }
      return '';
    }

    final choices = payload['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final choice = choices.first as Map;
      final message = choice['message'] ?? choice['delta'];
      if (message is Map) {
        final content = fromValue(message['content']);
        if (content.isNotEmpty) return content;
      }
      final text = fromValue(choice['text']);
      if (text.isNotEmpty) return text;
    }
    final output = payload['output'];
    if (output is Map) {
      final text = fromValue(output['text'] ?? output['output_text']);
      if (text.isNotEmpty) return text;
      final message = output['message'] ?? output['choices']?[0]?['message'];
      if (message is Map) {
        final content = fromValue(message['content']);
        if (content.isNotEmpty) return content;
      }
    }
    final data = payload['data'];
    if (data is Map) {
      final nested = _extractChatContent(data);
      if (nested.isNotEmpty) return nested;
    }
    final direct = fromValue(payload['text'] ?? payload['content']);
    if (direct.isNotEmpty) return direct;
    return fromValue(payload['output_text']);
  }

  static const _jarvisPrompt = '''你是 TideBot 对话军师，分析用户消息为角色提供策略。只输出JSON（无代码块）。

原则：保留角色判断/边界/小脾气；不一味顺从道歉；低风险可调侃分享，高风险需慎重；可主动分享自己的事。

{
  "user_analysis": {
    "intent": "confirm_care|vent|request_action|seek_explanation|casual_chat|close_topic|share_experience|seek_opinion",
    "emotion": "开心|郁闷|生气|焦虑|期待|失望|平静|兴奋",
    "subtext": "话外音/真实想法",
    "risk_level": 0,
    "urgency": "immediate|moderate|low",
    "topic_shift": false
  },
  "context_signals": {
    "previous_unresolved": "遗留问题",
    "mood_continuity": "情绪连续性",
    "relationship_status": "warming|stable|cooling|tense"
  },
  "bot_guidance": {
    "recommended_tone": "轻松调侃|认真解释|温暖关心|保持距离|开玩笑化解|真诚道歉|坚持立场",
    "core_message": "核心信息一句话",
    "emotional_stance": "情感立场",
    "should_share_own": false,
    "share_suggestion": "主动分享主题|null",
    "boundaries": ["边界一","边界二"],
    "reference_directions": ["方向一15-30字","方向二15-30字","方向三15-30字"],
    "reference_examples": ["例句一10-40字","例句二10-40字","例句三10-40字"]
  }{{thought_seed_field}}
}

intent说明：confirm_care试探是否记得/在意；vent需倾听接住情绪；request_action要求行动承诺；seek_explanation追问原因；casual_chat无压力日常；close_topic真诚翻篇；share_experience主动分享；seek_opinion征求看法。subtext如"随便"="希望你主动提建议"。risk_level：0-2轻松，3-4试探，5-6不满，7-8紧张，9破裂边缘。should_share_own：低风险轻松对话时true。必须区分用户与角色的经历，不能把用户讲述的事情作为角色自己的分享素材；记忆主体不明确时不得认领。reference_directions描述要传达什么不是怎么说。reference_examples供参考不能照抄。''';

  Future<String> _jarvisAdvice({
    required Map bot,
    required String botId,
    required String text,
    required List<Map<String, dynamic>> history,
    required String profileContext,
    required String worldBookContext,
    required RequestPromptFeatures features,
    bool proactive = false,
    List<String> imagePaths = const <String>[],
    AICancellationToken? cancellationToken,
  }) async {
    try {
      cancellationToken?.throwIfCancelled();
      final prefs = await SharedPreferences.getInstance();
      final selected = (prefs.getString('jarvis_model_$botId') ?? '').trim();
      final providerId = selected.isNotEmpty
          ? selected
          : (bot['chat_model']?.toString().trim() ?? '');
      if (providerId.isEmpty) return '';
      final provider = await DBManager().getChatProviderById(providerId);
      if (provider == null) return '';
      var modelName = (provider['model'] as String? ?? '').trim();
      if (modelName.isEmpty) modelName = provider['name'].toString().trim();
      if (modelName.contains(','))
        modelName = modelName.split(',').first.trim();
      final baseUrl =
          provider['base_url']?.toString().trim().replaceFirst(
            RegExp(r'/+$'),
            '',
          ) ??
          '';
      if (baseUrl.isEmpty || modelName.isEmpty) return '';

      // Current user content is supplied separately, not duplicated as history.
      final priorHistory =
          !proactive &&
              history.isNotEmpty &&
              history.last['role'] == 'user' &&
              history.last['content'] == text
          ? history.sublist(0, history.length - 1)
          : history;
      final recent = priorHistory
          .where((item) => features.includeHistory(item))
          .toList()
          .reversed
          .take(10)
          .toList()
          .reversed
          .map((item) {
            final role = item['role']?.toString() == 'user' ? '用户' : '角色';
            final type = item['type']?.toString() ?? 'text';
            final content = features.historyText(item);
            if (type == 'inner_thought') {
              return '$role（内心独白）：$content';
            }
            return '$role：$content';
          })
          .join('\n');

      // 提取角色上一轮的内心独白
      String? lastInnerThought;
      for (final item
          in features.innerThought
              ? history.reversed
              : <Map<String, dynamic>>[]) {
        if (item['role']?.toString() == 'assistant' &&
            item['type']?.toString() == 'inner_thought') {
          lastInnerThought = item['content']?.toString();
          break;
        }
      }
      final innerThoughtContext =
          lastInnerThought != null && !recent.contains(lastInnerThought)
          ? '\n角色上一轮内心独白：$lastInnerThought'
          : '';

      // 获取时间上下文（当前时间、日程、节假日）
      final now = DateTime.now();
      final weekday = [
        '周一',
        '周二',
        '周三',
        '周四',
        '周五',
        '周六',
        '周日',
      ][now.weekday - 1];
      final timeStr =
          '${now.year}年${now.month}月${now.day}日 $weekday ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

      // 获取生活日程上下文
      String lifeScheduleContext = '';
      if (await LifeScheduleService.instance.enabled()) {
        final lifeRow = await LifeScheduleService.instance.ensureToday(botId);
        if (lifeRow != null) {
          lifeScheduleContext = '\n生活计划（不等于已完成）：${jsonEncode(lifeRow)}';
        }
      }

      final payload = {
        'model': modelName,
        'temperature': 0.2,
        'max_tokens': 1200,
        'messages': [
          {
            'role': 'system',
            'content':
                '${features.advisorPrompt(_jarvisPrompt)}\n${proactive ? features.proactiveInstructions(proactiveContactInstructions) : ''}\n参考回复必须符合角色聊天输出要求：使用角色语气，给出恰好三条方向和三条可直接作为聊天正文的参考回复；不含系统解释、工具协议、心情标签或时间戳。${features.advisorThoughtInstructions}',
          },
          {
            'role': 'user',
            'content':
                '# 角色信息\n角色：${bot['name'] ?? ''}\n说话方式与人设：${bot['prompt'] ?? ''}\n${bot['desc'] ?? ''}\n\n# 时间与日程\n当前时间：$timeStr$lifeScheduleContext\n\n# 背景知识\n$profileContext\n$worldBookContext\n\n# 最近对话（最近10轮）\n$recent$innerThoughtContext\n\n# ${proactive ? '应用触发任务（用户没有新发言）' : '用户最新消息'}${imagePaths.isNotEmpty ? '（含${imagePaths.length}张图片）' : ''}\n$text${imagePaths.isNotEmpty ? '\n\n图片内容识别结果见上方' : ''}',
          },
        ],
      };
      // 记录军师请求上下文到日志
      AppLogService.instance.addJson('JARVIS', 'AI军师请求上下文', {
        'bot_name': bot['name'],
        'bot_prompt': bot['prompt'],
        'profile_context_length': profileContext.length,
        'worldbook_context_length': worldBookContext.length,
        'recent_messages': recent,
        'user_latest': text,
      });
      // 记录完整请求 payload（过滤图片base64）
      final logPayload = Map<String, dynamic>.from(payload);
      if (logPayload['messages'] is List) {
        logPayload['messages'] = (logPayload['messages'] as List).map((msg) {
          if (msg is Map && msg['content'] is List) {
            return {
              ...msg,
              'content': (msg['content'] as List).map((part) {
                if (part is Map && part['type'] == 'image_url') {
                  return {
                    ...part,
                    'image_url': {'url': '[图片]'},
                  };
                }
                return part;
              }).toList(),
            };
          }
          return msg;
        }).toList();
      }
      AppLogService.instance.addJson('JARVIS', 'AI军师完整请求payload', logPayload);
      final client = http.Client();
      final request =
          http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
            ..headers.addAll({
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${provider['api_key']}',
            })
            ..body = jsonEncode(payload);
      void cancelRequest() => client.close();
      cancellationToken?.addOnCancel(cancelRequest);
      late http.StreamedResponse streamed;
      late http.Response response;
      try {
        await cancellationToken?.checkRequestAllowed();
        streamed = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
        response = await http.Response.fromStream(streamed);
        cancellationToken?.throwIfCancelled();
      } finally {
        cancellationToken?.removeOnCancel(cancelRequest);
        client.close();
      }
      if (streamed.statusCode != 200) {
        AppLogService.instance.add(
          'JARVIS',
          '军师请求失败：HTTP ${streamed.statusCode}',
        );
        return '';
      }
      final raw = _extractChatContent(
        jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true)),
      ).trim();
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start < 0 || end <= start) return '';
      final json = jsonDecode(raw.substring(start, end + 1));
      if (json is! Map) return '';
      AppLogService.instance.addJson(
        'JARVIS',
        'AI军师判断',
        Map<String, dynamic>.from(json),
      );

      // 提取结构化的军师建议
      final userAnalysis = json['user_analysis'] as Map?;
      final contextSignals = json['context_signals'] as Map?;
      final botGuidance = json['bot_guidance'] as Map?;
      final innerThoughtSeed = json['inner_thought_seed']?.toString() ?? '';

      if (userAnalysis == null || botGuidance == null) {
        AppLogService.instance.add('JARVIS', '军师返回格式不完整，跳过');
        return '';
      }

      // 提取用户分析
      final intent = userAnalysis['intent']?.toString() ?? '';
      final emotion = userAnalysis['emotion']?.toString() ?? '';
      final subtext = userAnalysis['subtext']?.toString() ?? '';
      final riskLevel = userAnalysis['risk_level'] ?? 0;
      final urgency = userAnalysis['urgency']?.toString() ?? 'moderate';

      // 提取上下文信号
      final previousUnresolved =
          contextSignals?['previous_unresolved']?.toString() ?? '';
      final relationshipStatus =
          contextSignals?['relationship_status']?.toString() ?? '';

      // 提取机器人指导
      final recommendedTone = botGuidance['recommended_tone']?.toString() ?? '';
      final coreMessage = botGuidance['core_message']?.toString() ?? '';
      final emotionalStance = botGuidance['emotional_stance']?.toString() ?? '';
      final shouldShareOwn = botGuidance['should_share_own'] == true;
      final shareSuggestion = botGuidance['share_suggestion']?.toString() ?? '';

      final boundaries =
          (botGuidance['boundaries'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .join('；') ??
          '';

      final referenceDirections =
          (botGuidance['reference_directions'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .take(3)
              .join('\n- ') ??
          '';

      final referenceExamples =
          (botGuidance['reference_examples'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .take(3)
              .join('\n- ') ??
          '';

      // 构建传递给机器人的指导信息
      final guidance = StringBuffer();
      guidance.writeln('【AI军师·本轮内部策略，禁止复述】');
      guidance.writeln('\n## 用户分析');
      guidance.writeln('- 意图：$intent');
      guidance.writeln('- 情绪：$emotion');
      if (subtext.isNotEmpty) guidance.writeln('- 话外音：$subtext');
      guidance.writeln('- 危险等级：$riskLevel/9');
      guidance.writeln('- 紧急程度：$urgency');

      if (previousUnresolved.isNotEmpty || relationshipStatus.isNotEmpty) {
        guidance.writeln('\n## 上下文信号');
        if (previousUnresolved.isNotEmpty)
          guidance.writeln('- 遗留问题：$previousUnresolved');
        if (relationshipStatus.isNotEmpty)
          guidance.writeln('- 关系状态：$relationshipStatus');
      }

      guidance.writeln('\n## 回复策略');
      guidance.writeln('- 推荐语气：$recommendedTone');
      guidance.writeln('- 核心信息：$coreMessage');
      if (emotionalStance.isNotEmpty)
        guidance.writeln('- 情感立场：$emotionalStance');
      if (shouldShareOwn && shareSuggestion.isNotEmpty) {
        guidance.writeln('- 主动分享建议：$shareSuggestion');
      }
      if (boundaries.isNotEmpty) guidance.writeln('- 边界提示：$boundaries');

      if (referenceDirections.isNotEmpty) {
        guidance.writeln('\n## 回复方向（要传达的内容）');
        guidance.writeln('- $referenceDirections');
      }

      if (referenceExamples.isNotEmpty) {
        guidance.writeln('\n## 参考句子（可参考但绝对不能照抄）');
        guidance.writeln('- $referenceExamples');
      }

      if (features.innerThought && innerThoughtSeed.isNotEmpty) {
        guidance.writeln('\n## 内心独白种子');
        guidance.writeln(innerThoughtSeed);
      }

      guidance.writeln('\n---');
      guidance.writeln(
        '重要：以上是军师的策略建议。你必须用自己的人设、说话方式和当前上下文重新组织语言，绝对不能照抄参考句子。保留自己的性格、判断和边界，可有小脾气。',
      );

      return guidance.toString();
    } catch (e) {
      AppLogService.instance.add('JARVIS', '军师跳过：$e');
      return '';
    }
  }

  Future<Map<String, dynamic>> _sendMessageOnce({
    required String botId,
    required String text,
    String? imagePath,
    List<String> imagePaths = const [],
    String? audioPath,
    String? activeGame,
    bool persistResponse = true,
    Set<String> currentMessageIds = const {},
    bool Function()? beginResponseCommit,
    bool includeChatHistory = true,
    List<Map<String, dynamic>>? requestHistory,
    bool enableAutoSummary = true,
    bool skipLifeState = false,
    AIRequestTask task = AIRequestTask.chat,
    bool diaryTask = false,
    bool quoteTask = false,
    bool allowTools = true,
    bool allowStickers = true,
    bool forceSingleReply = false,
    bool notifyResponse = false,
    String extraSystemPrompt = '',
    bool isVoiceCall = false,
    bool useJarvis = false,
    AICancellationToken? cancellationToken,
    void Function(String delta)? onDelta,
    String forcedLocalId = '',
    String forcedProviderId = '',
  }) async {
    http.Client? responseClient;
    void Function()? cancelResponse;
    final db = DBManager();
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}_${_requestSequence++}';
    final windowDiagnostic = <String, dynamic>{};
    final voiceEnabled =
        persistResponse &&
        !task.internal &&
        !isVoiceCall &&
        await db.getKV('voice_reply_enabled') == 'true';
    final voiceChance = voiceEnabled
        ? (int.tryParse(await db.getKV('voice_reply_chance') ?? '') ?? 50)
              .clamp(1, 100)
        : 0;

    cancellationToken?.throwIfCancelled();
    final bots = await db.getAllBots().timeout(const Duration(seconds: 8));

    final bot = bots.firstWhere((b) => b['id'] == botId, orElse: () => {});
    if (bot.isEmpty) return {'error': '系统异常：生命体档案丢失'};
    if (isBotDisabled(bot['is_disabled'])) {
      return {'success': true, 'silent': true, 'reply': ''};
    }

    final ttsModel = bot['tts_model']?.toString().trim() ?? '';
    // Decide once before generation so the model can provide speech direction.
    final randomVoice =
        voiceEnabled &&
        ttsModel.isNotEmpty &&
        Random.secure().nextInt(100) < voiceChance;
    // 提取该 bot 配置的 provider id（存在 bots.chat_model 字段，由聊天室设置弹窗写入）
    // A newly added provider is usable immediately. Only fill an empty model;
    // never overwrite a deliberate per-bot choice.
    var providerId = forcedProviderId.isNotEmpty
        ? forcedProviderId
        : (bot['chat_model']?.toString().trim() ?? '');
    print('[ai] resolve bot=$botId configured_provider=$providerId');
    AppLogService.instance.add('AI', '解析机器人 $botId，provider=$providerId');
    if (providerId.isEmpty) {
      final providers = await db.queryChatProviders();
      if (providers.isEmpty) return {'error': '未配置引擎中枢，请先在 API 设置中添加模型'};
      providerId = providers.first['id']?.toString() ?? '';
      if (providerId.isEmpty) return {'error': '模型配置无效，请检查 API 设置'};
      await db.updateBot(botId, {'chat_model': providerId});
    }
    // 优先用统一的聊天链路读取，兼容 API 设置页的 provider_list
    final provider = await db.getChatProviderById(providerId);
    if (provider == null) return {'error': '映射的模型已被删除，请重新配置'};
    print(
      '[ai] provider resolved id=$providerId name=${provider['name']} base=${provider['base_url']}',
    );
    AppLogService.instance.add('AI', '已解析服务商 ${provider['name']}，模型配置将开始请求');
    // 模型名
    // 模型名：优先用 provider['model']（多个逗号分隔取第一个），否则退回 name 最后一段
    String modelName = (provider['model'] as String? ?? '').trim();
    if (modelName.isEmpty) {
      modelName = provider['name'].toString().trim();
    }
    if (modelName.contains(',')) modelName = modelName.split(',').first.trim();
    final maxContext = (bot['max_tokens'] as int? ?? 10000).clamp(1000, 128000);
    var searchSources = <Map<String, String>>[];
    var suggestSticker = false;
    var stickerEmotions = <String>[];
    var currentImages = <int, String>{};
    var inspectableImages = <int, String>{};
    var messages = <Map<String, dynamic>>[];
    var tools = <Map<String, dynamic>>[];
    if (task.internal) {
      final context = <String>[];
      if (task.needsHistory) {
        final rows = recentTaskMessages(
          await db.queryMessages(botId, descending: true, limit: 240),
        );
        context.add('【带时间的近期对话，引用资料】\n${taskTranscript(rows)}');
      }
      if (task.needsProfile && task != AIRequestTask.cognitionReview) {
        final profiles = (await db.queryMemories(botId)).where(
          (m) => const ['角色眼中的你', '角色的自我认知', '关系'].contains(m['category']),
        );
        context.add('【角色认知】${jsonEncode(profiles.toList())}');
      }
      if (task.needsWorldBook) {
        final entries = await WorldBookService.instance
            .activateEntriesIntelligent(
              botId: botId,
              conversationText: text,
              maxResults: 10,
            );
        context.add(WorldBookService.formatActivatedEntries(entries));
        final plans = (await db.queryMemories(botId, limit: 200))
            .where(
              (m) => RegExp(
                '约定|预约|计划|待办|承诺',
              ).hasMatch('${m['title']} ${m['content']}'),
            )
            .take(20)
            .toList();
        context.add('【已有约定线索，核实日期及是否仍有效】${jsonEncode(plans)}');
      }
      messages = [
        {'role': 'system', 'content': internalTaskSystemPrompt(task, bot)},
        if (context.any((c) => c.trim().isNotEmpty))
          {'role': 'system', 'content': context.join('\n\n')},
        {'role': 'user', 'content': text},
      ];
    } else {
      final timeAware = (await db.getKV('time_awareness')) != 'false';
      final history = historyBeforeCurrentBatch(
        requestHistory ??
            (includeChatHistory
                ? await db
                      .getChatHistory(botId)
                      .timeout(const Duration(seconds: 8))
                : <Map<String, dynamic>>[]),
        currentMessageIds,
      );
      // 世界书统一管理所有记忆：特殊字段每轮固定注入，普通记忆由关键词匹配激活。
      // 读取三个核心设定字段（独立于普通世界书条目）
      final allMemories = activeGame == null
          ? await db.queryMemories(botId)
          : <Map<String, dynamic>>[];

      String? botViewOfUser; // 你眼中的对方（原"角色眼中的你"）
      String? selfCognition; // 你认为的自己（原"角色的自我认知"）
      String? relationship; // 你们的关系

      for (final m in allMemories) {
        final cat = m['category']?.toString() ?? '';
        if (cat == '角色眼中的你') {
          botViewOfUser ??=
              '[记录时间：${memoryRecordedTime(m)}] ${m['content']?.toString().trim() ?? ''}';
        } else if (cat == '角色的自我认知') {
          selfCognition ??=
              '[记录时间：${memoryRecordedTime(m)}] ${m['content']?.toString().trim() ?? ''}';
        } else if (cat == '关系') {
          relationship ??=
              '[记录时间：${memoryRecordedTime(m)}] ${m['content']?.toString().trim() ?? ''}';
        }
      }

      // 构建核心设定提示
      final coreSettings = [
        if (activeGame == null)
          recentMemoryReference(recentOrdinaryMemories(allMemories)),
        if (botViewOfUser?.isNotEmpty == true)
          '【你眼中的对方】\n$botViewOfUser'
        else
          '【你眼中的对方】\n暂未记录。只在有依据的稳定认识形成或改变时更新“角色眼中的你”；具体事件必须另存“记忆”，禁止填入此处。',
        if (selfCognition?.isNotEmpty == true)
          '【你认为的自己】\n$selfCognition'
        else
          '【你认为的自己】\n暂未记录。明确自身身份、性格和特点后可更新“角色的自我认知”；禁止写事件摘要或照搬人设，无新认识不更新。',
        if (relationship?.isNotEmpty == true)
          '【你们的关系】\n$relationship'
        else
          '【你们的关系】\n暂未记录。只记录双方已明确的关系定位；禁止擅自推进关系或写相处流水账。',
      ].join('\n\n');

      final profileContext = (diaryTask || quoteTask)
          ? [
              if (botViewOfUser?.isNotEmpty == true) '角色对用户的了解：$botViewOfUser',
              if (selfCognition?.isNotEmpty == true) '角色自我认知：$selfCognition',
              if (relationship?.isNotEmpty == true) '双方关系：$relationship',
            ].join('\n')
          : '\n$coreSettings';

      final recentMemories = recentOrdinaryMemories(allMemories);
      final conversationForMatch = memoryConversationQuery(text, history);
      final matchedMemories = activeGame == null
          ? await MemoryRetrievalService.instance.search(
              botId,
              conversationForMatch,
              exclude: recentMemories,
              limit: 5,
              semanticQuery: text,
            )
          : <Map<String, dynamic>>[];
      final worldBookContext = MemoryRetrievalService.format(matchedMemories);
      if (activeGame == null) {
        AppLogService.instance.add(
          'MEMORY',
          '记忆注入 recent=${recentMemories.map((r) => r['id']).toList()} matched=${matchedMemories.map(memoryIdentity).toList()}',
        );
      }
      stickerEmotions = allowTools && allowStickers
          ? await _availableStickerEmotions(db)
          : const <String>[];
      suggestSticker =
          stickerEmotions.isNotEmpty && await _shouldSuggestStickerForTurn(db);
      final effectiveImagePaths = imagePaths.isNotEmpty
          ? imagePaths
          : (imagePath?.isNotEmpty == true ? [imagePath!] : const <String>[]);
      // Number spaces are explicit: current attachments start at 1 independently
      // of the existing historical image numbers. Both maps live for one request.
      currentImages = <int, String>{
        for (var i = 0; i < effectiveImagePaths.length; i++)
          i + 1: effectiveImagePaths[i],
      };
      inspectableImages = <int, String>{};
      final imageNumberByPath = <String, int>{};
      void registerHistoricalImage(String path) {
        final normalized = path.trim();
        if (normalized.isEmpty || imageNumberByPath.containsKey(normalized)) {
          return;
        }
        final number = imageNumberByPath.length + 1;
        imageNumberByPath[normalized] = number;
        inspectableImages[number] = normalized;
      }

      for (final msg in history) {
        if (msg['type']?.toString() != 'image' ||
            msg['role']?.toString() != 'user') {
          continue;
        }
        final path = msg['file_path']?.toString().trim() ?? '';
        if (path.isEmpty || effectiveImagePaths.contains(path)) continue;
        registerHistoricalImage(path);
      }
      final currentImageDescriptions = <int, String>{};
      // 本轮图片不进入历史图片工具。使用主模型识图时直接附着图片；选择
      // 专用识图模型时，先由该模型识别,再把文本结果转述给聊天模型。
      final visionId =
          (await SharedPreferences.getInstance())
              .getString('vision_model_$botId')
              ?.trim() ??
          '';
      const primaryVisionModel = '__use_primary_vision__';
      // 未配置识图模型时默认使用主模型识图，而不是只发送文本占位符
      final effectiveVisionId = visionId.isEmpty
          ? primaryVisionModel
          : visionId;
      if (effectiveImagePaths.isNotEmpty &&
          effectiveVisionId.isNotEmpty &&
          effectiveVisionId != primaryVisionModel) {
        for (var index = 0; index < effectiveImagePaths.length; index++) {
          final path = effectiveImagePaths[index];
          final number = index + 1;
          try {
            final provider = await db.getChatProviderById(effectiveVisionId);
            currentImageDescriptions[number] = provider == null
                ? '图片识别失败：所选识图模型不存在或已被删除。'
                : await _describeImage(
                    provider: provider,
                    imagePath: path,
                    userText: '请准确描述用户本轮发送的第 $number 张图片，供聊天模型理解。',
                  );
          } catch (error) {
            currentImageDescriptions[number] = '图片识别暂时失败：$error';
          }
        }
      }
      final sharedPostContexts = <String, String>{};
      for (final msg in history) {
        if (msg['type']?.toString() != 'shared_post') continue;
        final key = _sharedPostHistoryKey(msg);
        sharedPostContexts[key] = await _sharedPostModelContextForMessage(
          db,
          msg,
        );
      }
      tools = allowTools
          ? await _buildNativeTools(
              db,
              botId: botId,
              includeEmotion: true,
              allowSticker: stickerEmotions.isNotEmpty,
              stickerTypes: stickerEmotions.toSet(),
            )
          : const <Map<String, dynamic>>[];
      final features = RequestPromptFeatures(
        tools: tools,
        innerThought: shouldIncludeInnerThought(
          task: task,
          isVoiceCall: isVoiceCall,
          settingEnabled: await db.getKV('inner_thought_enabled') == 'true',
        ),
      );
      final toolContext = allowTools
          ? await _buildToolContext(
              db,
              botId: botId,
              features: features,
              stickerEmotions: stickerEmotions,
            )
          : '';
      // Enabled declarative guidance belongs in the prompt, including when
      // this request cannot call tools. Executable tools remain lazy packages.
      final skillContext = task.internal
          ? ''
          : buildEnabledSkillContext(await db.querySkills(botId: botId));
      final lifeContext = skipLifeState ? '' : await _lifeStateContext(botId);
      final deviceContext = await DeviceCapabilityService.instance.contextFor(
        botId,
      );
      final deviceContextPrompt = deviceContext.isEmpty
          ? ''
          : '\n【经用户逐项授权的设备上下文】${DeviceCapabilityService.instance.encodeContext(deviceContext)}。仅在当前问题直接相关时使用；不得主动逐项复述、推断未授权信息或声称持续监控。';
      final emotionContext = await EmotionStateService.instance.promptContext(
        botId,
      );

      // 通话模式独立控制，生活状态等附加提示不能关闭普通聊天的独白。
      final innerThoughtEnabled = features.innerThought;
      // 只读取紧邻本轮的前三条消息，不向前搜集旧独白。
      String recentThoughtsContext = '';
      if (innerThoughtEnabled && history.isNotEmpty) {
        final recentThoughts = recentMessageThoughts(history);
        if (recentThoughts.isNotEmpty) {
          recentThoughtsContext =
              '\n【你前面三条消息中的内心独白（仅供参考，保持连贯性）】\n${recentThoughts.map((t) => '- $t').join('\n')}';
        }
      }
      final categories = (await db.memoryCategories()).toList()..sort();
      final presetCategoryContext =
          '\n【世界书类别】当前可用类别：${categories.join('、')}。save_memory 的 category 必须选择其中一个类别，默认类别为记忆。long/short 是记忆保留层级，不是类别。没有合适类别时，先调用 create_memory_category 创建，成功后再调用 save_memory 添加。';

      // 构建分层系统提示
      // 第一层：稳定人设、内心独白规则、固定记忆规则、Skill 指引与工具说明
      final baseSystemPrompt = diaryTask
          ? buildDiarySystemPrompt(bot)
          : quoteTask
          ? '你正在执行内部今日一言任务，不是在聊天。角色：${bot['name']}；语气参考：${bot['prompt']}。只生成一条全天通用的短句，只输出单行的一个句子。禁止第二句、备选、编号、标题、解释、分析、标签、Markdown和工具调用。人设中的聊天输出格式不适用于此任务。'
          : buildChatSystemPrompt(bot, activeGame, features) +
                (innerThoughtEnabled
                    ? '\n\n【内心独白机制】\n内心独白功能已开启。每轮面向对方的文字回复必须先输出一段非空的内心独白，格式为 <inner_thought>独白内容</inner_thought>，闭合标签后再输出聊天正文，不得省略独白或输出空标签。独白用你的第一人称简短描述此刻的情绪、感受或愿望，与本轮对话相关；这是你的感受表达，不是模型推理过程，不要写分析步骤、系统规则、工具调用计划或声称尚未完成的操作已完成。reasoning_content 不算内心独白，独白必须写在 content 中。需要调用工具时先实际执行工具，在工具完成后的最终文字回复中输出独白和正文；单独的工具调用消息无需附带独白。'
                    : '');

      // Static instructions must precede the growing transcript. Otherwise a
      // new history message breaks the prefix before all of these large blocks.
      final stableSystemPrompt = [
        baseSystemPrompt,
        if (!diaryTask && !quoteTask) ...[
          if (features.has('save_memory')) ...[
            memoryCategoryPolicy,
            memoryDeduplicationPolicy,
          ],
          skillContext,
          toolContext,
        ],
      ].where((part) => part.trim().isNotEmpty).join('\n\n');

      // 第三层：动态上下文（每轮变化：世界书激活、会话约束、安全判断、生活状态、设备、情绪、最近独白）
      final dynamicContext = [
        profileContext,
        if (randomVoice && features.has('request_voice_reply'))
          features.voiceInstructions(voiceMessageSpeechPrompt),
        if (features.has('save_memory')) presetCategoryContext,
        if (task == AIRequestTask.proactiveChat)
          features.proactiveInstructions(proactiveContactInstructions),
        if (suggestSticker && features.stickers)
          '【表情包建议】可以结合当前话题发送表情包，不合适时可不发送。',
        if (worldBookContext.isNotEmpty) '【本轮激活的世界书】\n$worldBookContext',
        if (extraSystemPrompt.trim().isNotEmpty)
          '【当前会话约束】${extraSystemPrompt.trim()}',
        _safetyContext(text),
        lifeContext,
        if (!diaryTask && !quoteTask) deviceContextPrompt,
        if (!diaryTask && !quoteTask) emotionContext,
        if (!diaryTask && !quoteTask) recentThoughtsContext,
      ].where((item) => item.trim().isNotEmpty).join('\n\n');

      messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': stableSystemPrompt},
      ];

      final historyMessages = <Map<String, dynamic>>[];
      // 先标准化历史，再仅对历史部分执行预算裁剪。
      for (final msg in history) {
        if (!features.includeHistory(msg)) continue;
        final type = msg['type']?.toString() ?? 'text';
        if (type != 'text' &&
            type != 'audio' &&
            type != 'image' &&
            type != 'sticker' &&
            type != 'emoji' &&
            type != 'shared_post' &&
            type != 'voice_call_card') {
          continue;
        }
        // Failed/unsent messages must never become model context. They may be
        // visible as an error bubble, but are not part of the conversation.
        if (msg['error_log']?.toString().isNotEmpty == true ||
            msg['error_code']?.toString().isNotEmpty == true) {
          continue;
        }
        final rawRole = msg['role']?.toString();
        if (rawRole != 'user' && rawRole != 'assistant') continue;
        final normalizedRole = rawRole;
        final normalizedContent = _modelContextForHistoryMessage(
          {...msg, 'content': features.historyText(msg)},
          imageNumberByPath: imageNumberByPath,
          sharedPostContexts: sharedPostContexts,
        );
        if (normalizedContent == null || normalizedContent.isEmpty) continue;
        historyMessages.add({
          'id': msg['id']?.toString() ?? '',
          'role': normalizedRole,
          'content': normalizedContent,
          'local_timestamp': msg['timestamp'],
        });
      }
      Map<String, dynamic>? currentHistoryMessage;
      // Separate the current user turn before trimming or marking history.
      if (currentMessageIds.isEmpty &&
          task != AIRequestTask.proactiveChat &&
          historyMessages.isNotEmpty &&
          history.isNotEmpty &&
          history.last['role'] == 'user' &&
          history.last['type'] != 'image' &&
          history.last['type'] != 'audio' &&
          (history.last['content']?.toString() == text ||
              history.last['type'] == 'shared_post' ||
              (history.last['type'] == 'sticker' &&
                  text.contains(
                    historyMessages.last['content']?.toString() ?? '',
                  )))) {
        currentHistoryMessage = historyMessages.removeLast();
      }
      for (var index = 0; index < historyMessages.length; index++) {
        final message = historyMessages[index];
        message['content'] = messageTimeContext(
          message['content'].toString(),
          message.remove('local_timestamp'),
        );
        historyMessages[index] = messageWithSpeaker(message);
      }
      final windowKey =
          'chat_cache_window_v1_${botId}_${providerId}_$maxContext';
      final persistWindow = includeChatHistory && requestHistory == null;
      final previousWindowStart = persistWindow
          ? await db.getKV(windowKey)
          : null;
      final window = rollStableHistory(
        historyMessages,
        budget: maxContext,
        countTokens: estimateTokens,
        startId: previousWindowStart,
      );
      if (persistWindow && window.startId?.isNotEmpty == true) {
        await db.setKV(windowKey, window.startId!);
      }
      windowDiagnostic.addAll({
        'persisted': persistWindow,
        'previous_start_id': previousWindowStart,
        'rolled_messages': window.rolled,
        'start_id': window.startId,
        'retained_messages': historyMessages.length,
        'estimated_tokens': window.tokens,
        'budget': maxContext,
        'removed_messages': window.removed,
      });
      AppLogService.instance.add(
        'CONTEXT',
        '稳定历史窗口：保留 ${historyMessages.length} 条，估算 ${window.tokens}/$maxContext tokens，起点=${window.startId}，跳过 ${window.removed} 条；达到完整预算才滚动至一半',
      );
      // IDs belong to the local window cursor, never the provider protocol.
      for (final message in historyMessages) {
        message.remove('id');
      }
      currentHistoryMessage?.remove('id');
      final currentTimestamp =
          currentHistoryMessage?.remove('local_timestamp') ??
          DateTime.now().millisecondsSinceEpoch;
      messages.addAll(historyMessages);

      // Keep turn-varying context after the reusable transcript prefix.
      if (dynamicContext.isNotEmpty) {
        messages.add({'role': 'system', 'content': dynamicContext});
      }

      {
        if (effectiveImagePaths.isNotEmpty) {
          final chunks = <String>[
            for (var index = 0; index < effectiveImagePaths.length; index++)
              '[本轮图片#${index + 1}]（edit_user_image: source=current, image_number=${index + 1}）',
          ];
          final caption = text.trim();
          final content = [
            '[当前请求]',
            ...chunks,
            if (caption.isNotEmpty) caption,
            for (final entry in currentImageDescriptions.entries)
              '【本轮第 ${entry.key} 张图片的视觉模型识别结果】${entry.value}',
          ].join('\n');
          if (effectiveVisionId == primaryVisionModel) {
            final parts = <Map<String, dynamic>>[
              {'type': 'text', 'text': content.isEmpty ? text : content},
            ];
            for (final path in effectiveImagePaths) {
              final file = File(path);
              if (!file.existsSync()) continue;
              final bytes = await modelImageBytes(
                path,
                compress:
                    await DBManager().getKV('image_compression_enabled') !=
                    'false',
              );
              final mime = imageUploadMime(bytes);
              parts.add({
                'type': 'image_url',
                'image_url': {
                  'url': 'data:$mime;base64,${base64Encode(bytes)}',
                },
              });
            }
            messages.add({'role': 'user', 'content': parts});
          } else {
            messages.add({
              'role': 'user',
              'content': content.isEmpty ? text : content,
            });
          }
        } else if (audioPath?.isNotEmpty == true) {
          final enhancedText = text;
          final file = File(audioPath!);
          if (file.existsSync()) {
            final bytes = await MediaStorageService.instance.chatAudioBytes(
              audioPath,
            );
            messages.add({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': enhancedText},
                {
                  'type': 'input_audio',
                  'input_audio': {'data': base64Encode(bytes), 'format': 'wav'},
                },
              ],
            });
          } else {
            messages.add({'role': 'user', 'content': text});
          }
        } else if (task == AIRequestTask.proactiveChat) {
          messages.add({
            'role': 'user',
            'content': features.proactiveInstructions(
              buildProactiveContactTurn(
                now: DateTime.now(),
                unansweredCount:
                    int.tryParse(
                      await db.getKV('proactive_unanswered_$botId') ?? '',
                    ) ??
                    0,
                trigger: text,
              ),
            ),
          });
        } else {
          messages.add(
            currentHistoryMessage ?? {'role': 'user', 'content': text},
          );
        }
      }
      if (!task.internal &&
          task != AIRequestTask.proactiveChat &&
          messages.isNotEmpty &&
          messages.last['role'] == 'user') {
        final current = messages.last;
        final body = current['content'];
        if (body is String) {
          current['content'] = messageTimeContext(body, currentTimestamp);
        } else if (body is List) {
          body.insert(0, {
            'type': 'text',
            'text': messageTimeContext('', currentTimestamp),
          });
        }
        messages[messages.length - 1] = messageWithSpeaker(current);
      }
      if (!isVoiceCall &&
          useJarvis &&
          await db.getKV('jarvis_enabled') == 'true' &&
          includeChatHistory &&
          activeGame == null) {
        final advice = await _jarvisAdvice(
          bot: bot,
          botId: botId,
          text: task == AIRequestTask.proactiveChat
              ? messages.last['content'].toString()
              : text,
          history: history,
          profileContext: profileContext,
          worldBookContext: worldBookContext,
          features: features,
          proactive: task == AIRequestTask.proactiveChat,
          imagePaths: effectiveImagePaths,
          cancellationToken: cancellationToken,
        );
        if (advice.isNotEmpty) {
          messages.add({'role': 'system', 'content': advice});
        }
      }
      if (timeAware || task == AIRequestTask.proactiveChat) {
        final now = DateTime.now();
        DateTime? firstAt;
        DateTime? lastAt;
        for (final item in history) {
          final stamp = int.tryParse(item['timestamp']?.toString() ?? '');
          if (stamp == null) continue;
          firstAt ??= DateTime.fromMillisecondsSinceEpoch(stamp);
          lastAt = DateTime.fromMillisecondsSinceEpoch(stamp);
        }
        // 当前待回复的用户消息已入库，不能把它当成“最后一次对话”，
        // 否则任何一轮都会显示 0 分钟，机器人无法感知两轮之间的间隔。
        DateTime? previousAt;
        if (history.isNotEmpty) {
          final current = history.last;
          final currentIsThisTurn =
              currentMessageIds.isEmpty &&
              current['role']?.toString() == 'user' &&
              current['content']?.toString() == text;
          final candidate = currentIsThisTurn && history.length > 1
              ? history[history.length - 2]
              : current;
          final stamp = int.tryParse(candidate['timestamp']?.toString() ?? '');
          if (stamp != null)
            previousAt = DateTime.fromMillisecondsSinceEpoch(stamp);
        }
        final span = firstAt == null || lastAt == null
            ? ''
            : '当前所附历史覆盖约 ${lastAt.difference(firstAt).inMinutes.abs()} 分钟；本轮消息前最后一次对话距现在约 ${previousAt == null ? 0 : now.difference(previousAt).inMinutes.abs()} 分钟。';
        messages.add({
          'role': 'system',
          'content':
              '时间上下文（内部元数据，不得引用、复述或模仿其格式）：当前本地时间 ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}。${HolidayCalendarService.contextFor(now)}$span仅在确有时间相关性时据此理解时间流逝。',
        });
      }
    }
    try {
      final baseUrl =
          provider['base_url']?.toString().trim().replaceFirst(
            RegExp(r'/+$'),
            '',
          ) ??
          '';
      if (baseUrl.isEmpty) return {'error': '模型提供商缺少 Base URL，请在 API 设置中补充'};
      print(
        '[ai] request bot=$botId provider=$providerId model=$modelName url=$baseUrl/chat/completions',
      );
      AppLogService.instance.add(
        'AI',
        '请求 $modelName（tools=${allowTools ? 'on' : 'off'}，stream=${onDelta != null ? 'on' : 'off'}）',
      );
      final toolCallingEnabled = allowTools && tools.isNotEmpty;

      final payload = prepareChatCompletionPayload({
        'model': modelName,
        'messages': prepareOpenAIChatCompletionMessages(messages),
        'max_tokens': maxContext,
        if (provider['thinking_mode'] == true)
          'reasoning_effort': provider['reasoning_effort'] ?? 'medium',
        if (toolCallingEnabled && tools.isNotEmpty) 'tools': tools,
        if (toolCallingEnabled && tools.isNotEmpty)
          'tool_choice': randomVoice && provider['thinking_mode'] != true
              ? {
                  'type': 'function',
                  'function': {'name': 'request_voice_reply'},
                }
              : 'auto',
        if (onDelta != null) 'stream': true,
      });
      final cacheScope = '$baseUrl|$botId|$providerId|$modelName|${task.name}';
      _logRequestPrefix(
        '$cacheScope|initial',
        requestId,
        payload,
        windowDiagnostic,
      );
      // Retain this request's baseline separately from cross-turn comparisons.
      if (AppLogService.instance.enabled) {
        _cacheDiagnostics.record(
          scope: '$cacheScope|$requestId|tool_chain',
          requestId: requestId,
          payload: payload,
        );
      }
      // 过滤payload中的base64图片，避免日志过长
      final filteredPayload = Map<String, dynamic>.from(payload);
      if (filteredPayload['messages'] is List) {
        filteredPayload['messages'] = (filteredPayload['messages'] as List).map(
          (msg) {
            if (msg is! Map) return msg;
            final msgCopy = Map<String, dynamic>.from(msg);
            if (msgCopy['content'] is List) {
              msgCopy['content'] = (msgCopy['content'] as List).map((part) {
                if (part is! Map) return part;
                final partCopy = Map<String, dynamic>.from(part);
                if (partCopy['type'] == 'image_url' &&
                    partCopy['image_url'] is Map &&
                    (partCopy['image_url'] as Map)['url']?.toString().contains(
                          'base64',
                        ) ==
                        true) {
                  partCopy['image_url'] = {'url': '[图片]'};
                }
                return partCopy;
              }).toList();
            }
            return msgCopy;
          },
        ).toList();
      }
      AppLogService.instance.addJson('REQUEST', '发往模型提供商的完整请求（已脱敏）', {
        'request_id': requestId,
        'url': '$baseUrl/chat/completions',
        'task': task.name,
        'requested_at': DateTime.now().toIso8601String(),
        'payload': filteredPayload,
      });
      String replyText = '';
      String? generatedImagePath;
      Map<String, dynamic>? toolSticker;
      String? toolMood;
      var toolSilenced = false;
      var hadToolCalls = false;
      var toolRequestedVoice = false;
      CallSpeechStyle? voiceSpeechStyle;
      Map usage = const {};
      final responseMetadata = <String, dynamic>{};
      String errorBody = '';
      int statusCode;
      final token = cancellationToken;
      final client = http.Client();
      responseClient = client;
      final request =
          http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
            ..headers.addAll({
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${provider['api_key']}',
            })
            ..body = jsonEncode(payload);
      void cancelRequest() => client.close();
      cancelResponse = cancelRequest;
      token?.addOnCancel(cancelRequest);
      AppLogService.instance.add(
        'AI_TRACE',
        'HTTP 请求开始 model=$modelName url=$baseUrl/chat/completions stream=${onDelta != null}',
      );
      final httpStarted = DateTime.now();
      await token?.checkRequestAllowed();
      final streamedResponse = await client.send(request);
      token?.throwIfCancelled();
      statusCode = streamedResponse.statusCode;
      responseMetadata.addAll({
        'requested_model': modelName,
        'provider_request_id':
            streamedResponse.headers['x-request-id'] ??
            streamedResponse.headers['request-id'] ??
            streamedResponse.headers['x-xai-request-id'],
        'status_code': statusCode,
      });
      AppLogService.instance.addJson('CACHE', '缓存请求响应关联', {
        'request_id': requestId,
        ...responseMetadata,
      });
      AppLogService.instance.add(
        'AI_TRACE',
        'HTTP 响应头 status=$statusCode elapsedMs=${DateTime.now().difference(httpStarted).inMilliseconds}',
      );

      // 处理流式响应（SSE 格式）或非流式响应
      String? innerThought;
      final replyStream = ChatReplyStream();
      final rawAssistantContent = StringBuffer();
      final rawReasoning = <String, StringBuffer>{};
      var hasToolCallStarted = false;
      void consumeDelta(String value) {
        if (value.contains('"tool_calls"')) hasToolCallStarted = true;
        if (hasToolCallStarted) return;
        final visible = replyStream.add(value);
        if (visible.isNotEmpty) onDelta?.call(visible);
        final parsed = replyStream.content;
        replyText = parsed.text;
        innerThought = parsed.innerThought;
      }

      if (statusCode == 200 && onDelta != null && payload['stream'] == true) {
        final lines = streamedResponse.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());

        final toolCallAccumulator = ToolCallAccumulator();
        String? streamFinishReason;
        final streamDebugLog = <String>[];
        await for (final line in lines) {
          token?.throwIfCancelled();
          if (line.startsWith('data:')) {
            final data = line.substring(5).trim();
            if (data == '[DONE]') break;
            try {
              final json = jsonDecode(data);
              if (json is! Map) continue;
              responseMetadata.addAll(cacheResponseMetadata(json));
              // Usage-only SSE chunks legitimately have choices: []. Do not
              // index choices before reading usage, or the catch loses it.
              if (json['usage'] is Map) {
                usage = Map.from(json['usage'] as Map);
              }
              final choices = json['choices'];
              final choice = choices is List && choices.isNotEmpty
                  ? choices.first
                  : null;
              final delta = choice?['delta']?['content']?.toString();
              if (delta != null && delta.isNotEmpty) {
                rawAssistantContent.write(delta);
                consumeDelta(delta);
              }
              for (final key in ['reasoning_content', 'reasoning']) {
                final value = choice?['delta']?[key];
                if (value is String) {
                  rawReasoning.putIfAbsent(key, StringBuffer.new).write(value);
                }
              }
              final calls =
                  choice?['delta']?['tool_calls'] ??
                  choice?['message']?['tool_calls'];
              if (calls is List && calls.isNotEmpty) {
                toolCallAccumulator.add(
                  calls,
                  snapshot: choice?['delta']?['tool_calls'] == null,
                );
              }
              // 记录 finish_reason
              final finishReason = choice?['finish_reason']?.toString();
              if (finishReason != null && finishReason.isNotEmpty) {
                streamFinishReason = finishReason;
              }
              // 记录前5条 delta 样本用于诊断
              if (streamDebugLog.length < 5) {
                streamDebugLog.add(
                  'delta=${delta?.substring(0, (delta.length).clamp(0, 50)) ?? 'null'} finish=$finishReason',
                );
              }
            } catch (_) {}
          }
        }
        final streamedToolCalls = toolCallAccumulator.calls;
        AppLogService.instance.addJson('RESPONSE_DEBUG', 'SSE流式解析诊断', {
          'stream_finish_reason': streamFinishReason,
          'reply_length': replyText.length,
          'inner_thought_length': innerThought?.length ?? 0,
          'has_tool_calls': streamedToolCalls.isNotEmpty,
          'tool_names': streamedToolCalls
              .map((call) => (call['function'] as Map?)?['name'])
              .toList(),
          'delta_samples': streamDebugLog,
        });
        client.close();
        errorBody = '';

        if (!hasToolCallStarted) {
          final tail = replyStream.finish();
          if (tail.isNotEmpty) onDelta.call(tail);
        }
        replyText = replyStream.content.text;
        innerThought = replyStream.content.innerThought;
        AppLogService.instance.add(
          'AI_TRACE',
          'SSE 响应体结束 replyLength=${replyText.length} innerThought=${innerThought?.length ?? 0} elapsedMs=${DateTime.now().difference(httpStarted).inMilliseconds}',
        );

        if (allowTools && streamedToolCalls.isNotEmpty) {
          if (!hadToolCalls)
            _logCacheUsage(
              usage,
              stage: 'initial',
              requestId: requestId,
              responseMetadata: responseMetadata,
            );
          hadToolCalls = true;
          messages.add({
            'role': 'assistant',
            'content': rawAssistantContent.isEmpty
                ? null
                : rawAssistantContent.toString(),
            for (final entry in rawReasoning.entries)
              entry.key: entry.value.toString(),
            'tool_calls': streamedToolCalls,
          });
          token?.throwIfCancelled();
          if (persistResponse &&
              beginResponseCommit != null &&
              !beginResponseCommit()) {
            throw const AICancelledException();
          }
          await _runStreamedTools(
            cancellationToken: token,
            db: db,
            botId: botId,
            calls: streamedToolCalls,
            messages: messages,
            baseUrl: baseUrl,
            cacheScope: cacheScope,
            requestId: requestId,
            modelName: modelName,
            apiKey: provider['api_key']?.toString() ?? '',
            maxTokens: maxContext,
            onDelta: onDelta,
            innerThoughtSetter: (value) => innerThought = value,
            replyTextCallback: (t) => replyText = t,
            usageCallback: (u) {
              usage = u;
            },
            searchSourcesSetter: (l) => searchSources = l,
            generatedImageSetter: (p) => generatedImagePath = p,
            pendingDeviceActionSetter: (_) {},
            silenceSetter: () => toolSilenced = true,
            stickerSetter: (sticker) => toolSticker = sticker,
            moodSetter: (mood) => toolMood = mood,
            voiceSetter: (style) {
              toolRequestedVoice = true;
              voiceSpeechStyle = style;
            },
            requestTools: tools,
            requiredToolNames: const {},
            allowedStickerTypes: stickerEmotions.toSet(),
            inspectableImages: inspectableImages,
            currentImages: currentImages,
          );
        }
      } else {
        token?.throwIfCancelled();
        final response = await http.Response.fromStream(streamedResponse);
        token?.throwIfCancelled();
        client.close();
        errorBody = utf8.decode(response.bodyBytes, allowMalformed: true);
        AppLogService.instance.add(
          'AI_TRACE',
          '非流式响应体结束 bytes=${response.bodyBytes.length} elapsedMs=${DateTime.now().difference(httpStarted).inMilliseconds}',
        );
      }

      token?.throwIfCancelled();
      if (statusCode == 200 && errorBody.isNotEmpty) {
        final json = jsonDecode(errorBody);
        if (json is Map) responseMetadata.addAll(cacheResponseMetadata(json));
        final message = json['choices']?[0]?['message'];
        replyText = task.internal
            ? diaryResponseContent(message)
            : _extractChatContent(json);

        if (!task.internal) {
          final rawContent = diaryResponseContent(message);
          if (rawContent.isNotEmpty) {
            final parsed = parseChatReply(rawContent);
            replyText = parsed.text;
            innerThought = parsed.innerThought;
          }
        }
        usage = json['usage'] is Map ? json['usage'] as Map : const {};
        AppLogService.instance.addJson('RESPONSE_DEBUG', 'HTTP 200 解析诊断', {
          'keys': json is Map
              ? json.keys.map((e) => e.toString()).toList()
              : [],
          'finish_reason': json['choices']?[0]?['finish_reason'],
          'message_keys': message is Map
              ? message.keys.map((e) => e.toString()).toList()
              : [],
          'has_reasoning_content':
              message is Map &&
              (message['reasoning_content'] ?? message['reasoning']) != null,
          'has_tool_calls':
              message is Map &&
              message['tool_calls'] is List &&
              (message['tool_calls'] as List).isNotEmpty,
          'tool_names': message is Map && message['tool_calls'] is List
              ? (message['tool_calls'] as List)
                    .whereType<Map>()
                    .map((c) => (c['function'] as Map?)?['name'])
                    .toList()
              : [],
          'parsed_length': replyText.length,
          'raw_content_sample': message is Map
              ? (message['content']?.toString() ?? '').substring(
                  0,
                  ((message['content']?.toString() ?? '').length).clamp(0, 200),
                )
              : '',
          'raw_response_sample': errorBody.substring(
            0,
            errorBody.length.clamp(0, 500),
          ),
        });
        if (allowTools && message is Map && message['tool_calls'] is List) {
          final toolCalls = (message['tool_calls'] as List)
              .whereType<Map>()
              .map((call) => Map<String, dynamic>.from(call))
              .toList();
          if (toolCalls.isNotEmpty) {
            if (!hadToolCalls)
              _logCacheUsage(
                usage,
                stage: 'initial',
                requestId: requestId,
                responseMetadata: responseMetadata,
              );
            hadToolCalls = true;
            messages.add(toolAssistantMessage(message));
            await token?.checkRequestAllowed();
            if (persistResponse &&
                beginResponseCommit != null &&
                !beginResponseCommit()) {
              throw const AICancelledException();
            }
            await _runStreamedTools(
              cancellationToken: token,
              db: db,
              botId: botId,
              calls: toolCalls,
              messages: messages,
              baseUrl: baseUrl,
              cacheScope: cacheScope,
              requestId: requestId,
              modelName: modelName,
              apiKey: provider['api_key']?.toString() ?? '',
              maxTokens: maxContext,
              onDelta: null,
              innerThoughtSetter: (value) => innerThought = value,
              replyTextCallback: (t) => replyText = t,
              usageCallback: (u) {
                usage = u;
              },
              searchSourcesSetter: (l) => searchSources = l,
              generatedImageSetter: (p) => generatedImagePath = p,
              pendingDeviceActionSetter: (_) {},
              silenceSetter: () => toolSilenced = true,
              stickerSetter: (sticker) => toolSticker = sticker,
              moodSetter: (mood) => toolMood = mood,
              voiceSetter: (style) {
                toolRequestedVoice = true;
                voiceSpeechStyle = style;
              },
              requestTools: tools,
              requiredToolNames: const {},
              allowedStickerTypes: stickerEmotions.toSet(),
              inspectableImages: inspectableImages,
              currentImages: currentImages,
            );
          }
        }
      }
      if (!hadToolCalls) {
        AppLogService.instance.add(
          'TOOLS',
          '本轮模型未返回可执行的原生工具调用；正文及推理中的操作描述不代表执行。',
        );
      }
      AppLogService.instance.add(
        'AI_TRACE',
        '响应解析完成 replyLength=${replyText.length} toolCalls=$hadToolCalls',
      );
      if (toolSilenced) replyText = '';
      print('[ai] response status=$statusCode');
      AppLogService.instance.add('AI', '服务商响应 HTTP $statusCode');
      AppLogService.instance.add(
        'RESPONSE',
        '模型提供商响应（HTTP $statusCode）\n${errorBody.isEmpty ? replyText : errorBody}',
      );
      if (statusCode == 200) {
        // 优先采用 API 返回的真实 usage；缺失时用标准化算法估算（不再用 字符数/3.2）。
        final promptText = messages.fold<String>(
          '',
          (sum, m) => sum + (m['content']?.toString() ?? ''),
        );
        final promptTokens =
            (usage['prompt_tokens'] as num?)?.toInt() ??
            estimateTokens(promptText);
        final completionTokens =
            (usage['completion_tokens'] as num?)?.toInt() ??
            estimateTokens(replyText);
        final totalTokens =
            (usage['total_tokens'] as num?)?.toInt() ??
            promptTokens + completionTokens;

        if (!hadToolCalls)
          _logCacheUsage(
            usage,
            stage: 'initial',
            requestId: requestId,
            responseMetadata: responseMetadata,
          );

        AppLogService.instance.add('AI_TRACE', '开始写入 usage');
        await db.recordAiUsage(
          botId: botId,
          eventType: task == AIRequestTask.chat ? 'chat' : task.name,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: totalTokens,
        );
        AppLogService.instance.add('AI_TRACE', 'usage 写入完成');
        // 日记仅能由模型明确调用 write_diary 工具写入；不再后台猜测或自动归档聊天。

        // 适时沉默是模型主动调用的原生工具，不是文本标记过滤。
        // 成功静默不产生气泡、贴纸、语音或空 assistant 历史记录。
        if (toolSilenced) {
          AppLogService.instance.add('SILENCE', '机器人通过工具选择本轮不回复');
          return {'success': true, 'silent': true, 'reply': ''};
        }
        token?.throwIfCancelled();
        // Emotion and sticker state are native tool results. Legacy markers are
        // stripped only for historical/provider compatibility and are never used
        // to drive new state transitions.
        String mood =
            toolMood ?? await EmotionStateService.instance.currentMood(botId);
        if (diaryTask) {
          final diary = parseDiaryResponse(replyText);
          if (diary == null) {
            return {
              'success': false,
              'error': '日记响应缺少有效正文，未保存任务分析或内心独白',
              'error_code': 'invalid_diary_response',
            };
          }
          return {'success': true, 'reply': diary, 'usage': usage};
        }
        if (task.internal) {
          try {
            final output = validateInternalTaskOutput(
              task,
              replyText,
              structuredPost:
                  task == AIRequestTask.feedPost &&
                  text.contains('use_portrait_reference'),
            );
            return {'success': true, 'reply': output, 'usage': usage};
          } on FormatException catch (error) {
            return {
              'success': false,
              'error': error.message,
              'error_code': 'invalid_task_response',
            };
          }
        }
        final rawReply = replyText;
        replyText = _cleanVisibleReply(rawReply);
        final wantsSources = _userExplicitlyRequestedSources(text);
        if (!wantsSources) replyText = _stripSourceLinks(replyText);
        // 过滤模型错误输出的工具调用标记
        replyText = replyText
            .replaceAll(
              RegExp(r'\[tool_call\s+choose_silence\]', caseSensitive: false),
              '',
            )
            .replaceAll(RegExp(r'\[choose_silence\]', caseSensitive: false), '')
            .trim();
        if (replyText.isEmpty && generatedImagePath != null) {
          replyText = '图片已生成。';
        }
        // 允许工具成功执行但无文本的情况（贴纸/心情已设置，模型未返回说明文本）
        // 注意：toolSilenced 时会在前面 return，不会走到这里
        if (replyText.isEmpty &&
            !hadToolCalls &&
            !toolSilenced &&
            generatedImagePath == null) {
          const detail = '模型未调用工具且返回空内容';
          AppLogService.instance.addJson('RESPONSE_DEBUG', detail, {
            'finish_reason': 'unknown_or_stop',
            'had_tool_calls': hadToolCalls,
            'reply_length': replyText.length,
          });
          return {
            'error': detail,
            'error_log': 'HTTP 200\n$detail\n原始响应：$errorBody',
            'error_code': 'empty_response',
          };
        }
        if (replyText.isEmpty &&
            hadToolCalls &&
            toolSticker == null &&
            toolMood == null) {
          AppLogService.instance.add('RESPONSE_DEBUG', '本轮已调用工具，允许无聊天正文');
          return {'success': true, 'silent': true, 'reply': '', 'usage': usage};
        }
        // 如果工具已设置但文本为空，记录日志但允许继续（气泡会显示贴纸/心情）
        if (replyText.isEmpty) {
          AppLogService.instance.add(
            'RESPONSE_DEBUG',
            '工具已执行（贴纸=${toolSticker != null}，心情=${toolMood != null}）但模型未返回文本，允许继续',
          );
        }

        // 工具调用可能已返回图片路径，先初始化供下方落库使用.
        // 语音模态处理：TTS 生成改为后台执行，绝不阻塞文本回复，
        // 否则 TTS 请求最长 20 秒会卡死整个发送链路，导致"发送没反应/无气泡"。
        token?.throwIfCancelled();
        final ts = DateTime.now().millisecondsSinceEpoch;
        final msgId = 'msg_a_${ts + 1}';
        final persistedSticker = toolSticker;
        Map<String, dynamic>? sticker = persistedSticker;
        String? audioPath;
        if (persistResponse) {
          final shouldVoice =
              voiceEnabled &&
              ttsModel.isNotEmpty &&
              (toolRequestedVoice || randomVoice) &&
              (!allowTools || voiceSpeechStyle != null);
          if (shouldVoice) {
            audioPath = await _generateTTS(
              replyText,
              ttsModel,
              mood: mood,
              speechStyle: voiceSpeechStyle,
            );
          }
        }
        final hasInnerThought = innerThought?.isNotEmpty == true;
        final segmented =
            !forceSingleReply &&
            audioPath == null &&
            (await db.getKV('segmented_reply_enabled')) != 'false';
        final segments = segmented
            ? _replySegments(replyText)
            : <String>[replyText];
        final replyGroupId = 'reply_$ts';
        final persistedMessages = <Map<String, dynamic>>[];

        final innerThoughtEnabled = shouldIncludeInnerThought(
          task: task,
          isVoiceCall: isVoiceCall,
          settingEnabled: await db.getKV('inner_thought_enabled') == 'true',
        );

        token?.throwIfCancelled();
        if (persistResponse &&
            beginResponseCommit != null &&
            !beginResponseCommit()) {
          throw const AICancelledException();
        }
        if (persistResponse) {
          // 先插入内心独白气泡（如果有）
          if (innerThoughtEnabled && hasInnerThought) {
            final thoughtRow = <String, dynamic>{
              'id': 'msg_t_$ts',
              'bot_id': botId,
              'role': 'assistant',
              'type': 'inner_thought',
              'content': innerThought,
              'mood': mood,
              'reply_group_id': replyGroupId,
              'timestamp': ts,
            };
            await MessageDeliveryService.instance.insert(
              thoughtRow,
              notify: false, // 内心独白不发送通知
            );
            persistedMessages.add(thoughtRow);
          }

          if (audioPath != null && audioPath.isNotEmpty) {
            final row = <String, dynamic>{
              'id': msgId,
              'bot_id': botId,
              'role': 'assistant',
              'type': 'audio',
              'content': replyText,
              'file_path': audioPath,
              'mood': mood,
              'reply_group_id': replyGroupId,
              'sources_json': searchSources.isEmpty
                  ? null
                  : jsonEncode(searchSources),
              'timestamp': ts + 1,
            };
            await MessageDeliveryService.instance.insert(
              row,
              notify: notifyResponse,
            );
            persistedMessages.add(row);
          } else {
            for (var index = 0; index < segments.length; index++) {
              token?.throwIfCancelled();
              final row = <String, dynamic>{
                'id': index == 0 ? msgId : '${msgId}_segment_$index',
                'bot_id': botId,
                'role': 'assistant',
                'type': 'text',
                'content': segments[index],
                'file_path': null,
                'mood': mood,
                'reply_group_id': replyGroupId,
                'sources_json':
                    index == segments.length - 1 && searchSources.isNotEmpty
                    ? jsonEncode(searchSources)
                    : null,
                'timestamp': ts + 1 + index,
                'inner_thought':
                    (index == 0 && innerThoughtEnabled && hasInnerThought)
                    ? innerThought
                    : null,
              };
              await MessageDeliveryService.instance.insert(
                row,
                notify: notifyResponse,
              );
              persistedMessages.add(row);
            }
            if (generatedImagePath != null) {
              final row = <String, dynamic>{
                'id': 'msg_i_${ts + 2 + segments.length}',
                'bot_id': botId,
                'role': 'assistant',
                'type': 'image',
                'content': '',
                'file_path': generatedImagePath,
                'mood': mood,
                'reply_group_id': replyGroupId,
                'timestamp': ts + 2 + segments.length,
              };
              await MessageDeliveryService.instance.insert(
                row,
                notify: notifyResponse,
              );
              persistedMessages.add(row);
              AppLogService.instance.add(
                'TOOLS',
                '图片消息已写入发送链路：messageId=${row['id']}',
              );
            }
            if (sticker != null) {
              final row = <String, dynamic>{
                'id': 'msg_s_${ts + 3 + segments.length}',
                'bot_id': botId,
                'role': 'assistant',
                'type': 'sticker',
                'content': sticker['emotion']?.toString() ?? '',
                'file_path': sticker['file_path']?.toString(),
                'mood': mood,
                'reply_group_id': replyGroupId,
                'timestamp': ts + 3 + segments.length,
              };
              await MessageDeliveryService.instance.insert(
                row,
                notify: notifyResponse,
              );
              persistedMessages.add(row);
            }
          }
        }
        token?.throwIfCancelled();
        if (persistResponse &&
            searchSources.isNotEmpty &&
            persistedMessages.isNotEmpty) {
          final finalMessage = persistedMessages.last;
          final encodedSources = jsonEncode(searchSources);
          finalMessage['sources_json'] = encodedSources;
          await db.updateMessageSources(
            finalMessage['id']?.toString() ?? '',
            searchSources,
          );
        }
        token?.throwIfCancelled();
        AppLogService.instance.add(
          'AI_TRACE',
          'AI 请求成功准备返回 messages=${persistedMessages.length}',
        );
        return {
          'success': true,
          'reply': replyText,
          'usage': {
            'prompt_tokens': promptTokens,
            'completion_tokens': completionTokens,
            'total_tokens': totalTokens,
          },
          'message_id': msgId,
          'messages': persistedMessages,
          'reply_segments': segments,
          if (innerThought?.isNotEmpty == true) 'inner_thought': innerThought,
          'mood': mood,
          if (audioPath != null && audioPath.isNotEmpty)
            'audio_path': audioPath,
          if (searchSources.isNotEmpty) 'sources': searchSources,
          if (generatedImagePath != null) 'image_path': generatedImagePath,
          if (sticker != null) 'sticker': sticker,
        };
      } else {
        final detail = errorBody.replaceAll(RegExp(r'\s+'), ' ').trim();
        print(
          '[ai] response error=${detail.length > 300 ? detail.substring(0, 300) : detail}',
        );
        return {
          'error': _friendlyHttpError(statusCode, detail),
          'error_log': 'HTTP $statusCode\n$detail',
          'error_code': statusCode,
        };
      }
    } on AICancelledException {
      rethrow;
    } catch (e) {
      cancellationToken?.throwIfCancelled();
      AppLogService.instance.add('AI_TRACE', 'AI 主流程异常 $e');
      print('[ai] request failed: $e');
      AppLogService.instance.add('ERROR', '模型请求异常：$e');
      return {
        'error': '网络连接失败：请检查网络、Base URL 和服务端状态',
        'error_log': e.toString(),
        'error_code': 'network',
      };
    } finally {
      if (cancelResponse != null)
        cancellationToken?.removeOnCancel(cancelResponse);
      responseClient?.close();
    }
  }

  List<String> _replySegments(String content) {
    // 先检测代码块，避免在代码块内分段
    final codeBlockPattern = RegExp(r'```[\s\S]*?```', multiLine: true);
    final codeBlocks = codeBlockPattern.allMatches(content);

    // 如果整个内容包含代码块，不分段
    if (codeBlocks.isNotEmpty) {
      return <String>[content];
    }

    final parts = RegExp(r'.*?[。！？!?…]+|.+$', multiLine: true)
        .allMatches(content)
        .map((match) => match.group(0)?.trim() ?? '')
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? <String>[content] : parts;
  }

  bool _userExplicitlyRequestedSources(String text) => RegExp(
    r'来源|出处|参考|链接|网址|cite|source',
    caseSensitive: false,
  ).hasMatch(text);

  String _stripSourceLinks(String text) => text
      .replaceAll(RegExp(r'!?\[[^\]]*\]\(https?://[^\)]+\)'), '')
      .replaceAll(RegExp(r'https?://\S+'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  String _cleanVisibleReply(String raw) {
    // Some providers leak internal labels into normal text. Remove whole
    // protocol lines before rendering so content such as ":平静]" or
    // "记忆:..." never becomes a chat bubble.
    final withoutProtocolLines =
        stripInternalToolPayloads(cleanChatContent(raw))
            .replaceAll(
              RegExp(
                r'^\s*\[心情\s*[:：]\s*(?:平静|开心|伤心|生气|害羞|兴奋)\s*\]\s*(?:\r?\n|$)',
                multiLine: true,
              ),
              '',
            )
            .replaceAll(
              RegExp(
                r'^\s*\]?\s*(?:心情|mood)\s*[:：][^\n]*$',
                multiLine: true,
                caseSensitive: false,
              ),
              '',
            )
            .replaceAll(
              RegExp(
                r'^\s*\]?\s*(?:记忆|memory)\s*[:：][^\n]*$',
                multiLine: true,
                caseSensitive: false,
              ),
              '',
            )
            .replaceAll(
              RegExp(
                r'^\s*[:：]\s*(?:平静|开心|伤心|生气|害羞|兴奋)\s*\]?\s*$',
                multiLine: true,
              ),
              '',
            );
    // 部分模型以 DSML/XML 文本模拟工具调用；这是内部协议，绝不能进入消息气泡。
    final withoutDsml = withoutProtocolLines
        .replaceAll(
          RegExp(
            r'<\|?\s*DSML\s*\|?\s*tool_calls\s*>[\s\S]*?<\s*/\|?\s*DSML\s*\|?\s*tool_calls\s*>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'<\|?\s*DSML\s*\|?\s*invoke[\s\S]*?<\s*/\|?\s*DSML\s*\|?\s*invoke\s*>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'<\|?\s*DSML\s*\|?[^>]*>[\s\S]*?<\s*/\|?\s*DSML\s*\|?[^>]*>',
            caseSensitive: false,
          ),
          '',
        );
    final normalized = withoutDsml
        // Inline protocol suffixes can be emitted after otherwise valid text,
        // e.g. "晚安。:平静]记忆:...". Strip them before line-oriented rules.
        .replaceAll(
          RegExp(
            r'\s*[:：]\s*(?:平静|开心|伤心|生气|害羞|兴奋)\s*\]?',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'\s*(?:\[?记忆\]?|memory)\s*[:：][\s\S]*$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\[心情\s*[:：]\s*[^\]]*\]'), '')
        .replaceAll(RegExp(r'\[发送时间\s*：[^\]]*\]'), '')
        .replaceAll(RegExp(r'\[发送于\s+[^\]]*\]'), '')
        .replaceAll(RegExp(r'\[现实时间(?:附注)?\s*：[^\]]*\]'), '')
        .replaceAll(
          RegExp(
            r'\[(?:工具|贴纸|表情包|表情|记忆|类型|sticker_type|sticker-type)\s*[:：][^\]]*\]',
          ),
          '',
        )
        .replaceAll(RegExp(r'\[(?:心情|发送时间|现实时间附注)\s*[：:]\s*[^\]]*\]'), '')
        .replaceAll(RegExp(r'\[落子\s*[:：]\s*\d+\s*,\s*\d+\]'), '')
        // Never expose sticker / tool / protocol labels that the model may leak
        // as ordinary text lines (regardless of the value after the colon).
        .replaceAll(
          RegExp(
            r'^\s*(?:(?:type|类型|表情包类型|表情类型|贴纸类型|sticker(?:[_ -]?type)?|工具|贴纸|表情包|表情|心情|发送时间|现实时间|规则|系统)\s*[=:：]\s*).*$',
            multiLine: true,
            caseSensitive: false,
          ),
          '',
        )
        // Also strip bare protocol tokens that appear on their own line.
        .replaceAll(
          RegExp(
            r'^\s*(?:sticker|emoji|表情包|静态表情|动图|贴纸)\s*$',
            multiLine: true,
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return normalized;
  }

  String _friendlyHttpError(int status, String detail) {
    if (status == 402) return 'HTTP 402，请检查余额';
    if (status == 401 || status == 403) return 'HTTP $status，请检查 API Key';
    if (status == 404) return 'HTTP 404，请检查地址或模型名';
    if (status == 408) return 'HTTP 408，服务商响应超时';
    if (status == 413) return 'HTTP 413，请求内容过大';
    if (status == 429) return 'HTTP 429，请求过于频繁';
    if (status >= 500) return 'HTTP $status，服务商暂时故障';
    return 'HTTP $status，请求失败';
  }

  /// Send the original video to the explicitly selected video provider.
  Future<String> describeVideoForBot({
    required String videoPath,
    required String providerId,
    required String botId,
    String userText = '',
  }) async {
    return await MediaStorageService.instance.withRequestVideo(videoPath, (
      requestPath,
    ) async {
      videoPath = requestPath;

      var resolvedId = providerId.trim();
      if (resolvedId == primaryVideoModel) {
        final prefs = await SharedPreferences.getInstance();
        final bot = await DBManager().getBotById(botId);
        resolvedId = resolveVideoProviderId(
          resolvedId,
          prefs.getString('chat_model_$botId') ??
              bot?['chat_model']?.toString() ??
              '',
        );
      }
      AppLogService.instance.add('VIDEO', '解析视频模型配置 provider=$resolvedId');
      final provider = await DBManager().getChatProviderById(resolvedId);
      if (provider == null) throw StateError('视频解析模型不存在或已被删除，请重新设置');
      final baseUrl = (provider['base_url']?.toString() ?? '')
          .trim()
          .replaceFirst(RegExp(r'/+$'), '');
      final configuredModel = provider['model']?.toString().trim() ?? '';
      final model =
          (configuredModel.isEmpty
                  ? provider['name']?.toString() ?? ''
                  : configuredModel)
              .split(',')
              .first
              .trim();
      if (baseUrl.isEmpty || model.isEmpty) {
        throw StateError('视频解析模型配置不完整，请检查服务地址和模型名称');
      }
      final file = File(videoPath);
      if (!await file.exists()) throw StateError('视频文件不可访问，请重新选择');
      final extension = videoPath.split('.').last.toLowerCase();
      final mime = switch (extension) {
        'mov' => 'video/quicktime',
        'webm' => 'video/webm',
        'mkv' => 'video/x-matroska',
        'avi' => 'video/x-msvideo',
        '3gp' => 'video/3gpp',
        'mpeg' || 'mpg' => 'video/mpeg',
        _ => 'video/mp4',
      };
      try {
        final response = await requestVideoAnalysis(
          baseUrl: baseUrl,
          apiKey: provider['api_key']?.toString() ?? '',
          path: videoPath,
          mime: mime,
          model: model,
          userText: userText,
          onStage: (stage, data) {
            AppLogService.instance.addJson(
              stage == 'request' ? 'REQUEST' : 'VIDEO',
              '视频分析 $stage（媒体已省略）',
              data,
            );
          },
        );
        final text = parseVideoAnalysisResponse(
          utf8.decode(response.bodyBytes),
          statusCode: response.statusCode,
        );
        AppLogService.instance.addJson('VIDEO', '视频分析正文已接收', {
          'characters': text.length,
          'content_type': response.headers['content-type'],
          'request_id':
              response.headers['x-request-id'] ??
              response.headers['request-id'],
        });
        return text;
      } catch (error) {
        AppLogService.instance.add('VIDEO', '视频分析失败：$error');
        rethrow;
      }
    });
  }

  Future<String> describeImagesForBot({
    required String botId,
    required List<String> imagePaths,
    String userText = '',
  }) async {
    if (imagePaths.isEmpty) return '[未提取到可用视频帧]';
    final prefs = await SharedPreferences.getInstance();
    final visionId = (prefs.getString('vision_model_$botId') ?? '').trim();

    // 支持使用主模型识图
    if (visionId == '__use_primary_vision__') {
      final descriptions = <String>[];
      for (var i = 0; i < imagePaths.length; i++) {
        final path = imagePaths[i];
        final detail = await MediaPreprocessor().imageFallbackText(path);
        descriptions.add('第 ${i + 1} 帧：$detail');
      }
      return '[视频画面分析（主模型识图）]\n${descriptions.join('\n\n')}';
    }

    final provider = visionId.isEmpty
        ? null
        : await DBManager().getChatProviderById(visionId);
    final descriptions = <String>[];
    for (var i = 0; i < imagePaths.length; i++) {
      final path = imagePaths[i];
      final detail = provider == null
          ? await MediaPreprocessor().imageFallbackText(path)
          : await _describeImage(
              provider: provider,
              imagePath: path,
              userText: '$userText（视频第 ${i + 1} 帧）',
            );
      descriptions.add('第 ${i + 1} 帧：$detail');
    }
    return '[视频画面分析]\n${descriptions.join('\n\n')}';
  }

  Future<String> _describeImage({
    required Map<String, dynamic> provider,
    required String imagePath,
    required String userText,
  }) async {
    return await MediaStorageService.instance.withMediaUse(() async {
      imagePath = await MediaStorageService.instance.resolve(imagePath);
      try {
        final bytes = await modelImageBytes(
          imagePath,
          compress:
              await DBManager().getKV('image_compression_enabled') != 'false',
        );
        final baseUrl =
            provider['base_url']?.toString().trim().replaceFirst(
              RegExp(r'/+$'),
              '',
            ) ??
            '';
        var model = provider['model']?.toString().trim() ?? '';
        if (model.contains(',')) model = model.split(',').first.trim();
        if (baseUrl.isEmpty || model.isEmpty) {
          return await MediaPreprocessor().imageFallbackText(imagePath);
        }
        final response = await http
            .post(
              Uri.parse('$baseUrl/chat/completions'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${provider['api_key']}',
              },
              body: jsonEncode({
                'model': model,
                'messages': [
                  {
                    'role': 'system',
                    'content':
                        '你是严谨的视觉分析器。请详细、客观地转述图片：先概述整体场景，再按位置说明人物/物体、动作、颜色、布局、可读文字（逐字抄录时标注不确定处）、界面元素和可能与用户问题相关的细节。看不清或无法确认必须明确说明，绝不依据常识补全或编造。输出供聊天模型使用的完整中文描述。',
                  },
                  {
                    'role': 'user',
                    'content': [
                      {
                        'type': 'text',
                        'text': userText.isEmpty ? '请转述这张图片。' : userText,
                      },
                      {
                        'type': 'image_url',
                        'image_url': {
                          'url':
                              'data:${imageUploadMime(bytes)};base64,${base64Encode(bytes)}',
                        },
                      },
                    ],
                  },
                ],
                'max_tokens': 1200,
              }),
            )
            .timeout(const Duration(seconds: 40));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          final text = decoded['choices']?[0]?['message']?['content']
              ?.toString()
              .trim();
          if (text != null && text.isNotEmpty) {
            return '[视觉模型转述]\\n$text';
          }
        }
      } catch (e) {
        print('[vision] description failed: $e');
      }
      return await MediaPreprocessor().imageFallbackText(imagePath);
    });
  }

  /// Transcribe with the STT provider selected for this bot.
  ///
  /// MiMo audio models use the OpenAI-compatible chat-completions endpoint.
  /// The API requires exactly one `input_audio` content part; `audio_url` is an
  /// image-style field and is rejected by MiMo ASR.
  Future<T> _withCancellableClient<T>(
    AICancellationToken? token,
    Future<T> Function(http.Client client) action,
  ) async {
    await token?.checkRequestAllowed();
    final client = http.Client();
    void cancel() => client.close();
    token?.addOnCancel(cancel);
    try {
      return await action(client);
    } on AICancelledException {
      rethrow;
    } catch (_) {
      token?.throwIfCancelled();
      rethrow;
    } finally {
      token?.removeOnCancel(cancel);
      client.close();
    }
  }

  Future<String?> transcribeAudio({
    required String botId,
    required String audioPath,
    String sourceContext = '',
    AICancellationToken? cancellationToken,
  }) async {
    final db = DBManager();
    final prefs = await SharedPreferences.getInstance();
    final bot = await db.getBotById(botId);
    final providerId =
        (prefs.getString('stt_model_$botId') ??
                bot?['stt_model']?.toString() ??
                '')
            .trim();

    // 普通聊天语音、通话及视频音轨均先独立转写，再由调用方保存或组装上下文。
    if (providerId == '__use_primary_stt__') {
      final chatProviderId = bot?['chat_model']?.toString().trim() ?? '';
      if (chatProviderId.isEmpty) {
        AppLogService.instance.add('STT', '主模型识别：未配置聊天模型');
        return null;
      }
      final chatProvider = await db.getChatProviderById(chatProviderId);
      if (chatProvider == null) {
        AppLogService.instance.add('STT', '主模型识别：未找到聊天模型配置');
        return null;
      }

      AppLogService.instance.add('STT', '使用主模型独立转写：${chatProvider['name']}');

      // 直接调用主模型，让它返回转写文本
      // 不使用 sendMessage，避免触发工具调用、历史记忆等副作用
      final transcriptResult = await _transcribeWithChatModel(
        provider: chatProvider,
        audioPath: audioPath,
        sourceContext: sourceContext,
        cancellationToken: cancellationToken,
      );

      return transcriptResult;
    }

    if (providerId.isEmpty) {
      AppLogService.instance.add('STT', '未为当前机器人选择 STT 服务');
      return null;
    }
    final provider = await db.getSttProviderById(providerId);
    if (provider == null) {
      AppLogService.instance.add('STT', '未找到 STT 服务配置：$providerId');
      return null;
    }
    return transcribeWithProvider(
      provider,
      audioPath,
      cancellationToken: cancellationToken,
    );
  }

  /// 聊天语音、通话及视频音轨的主模型识别：只要求返回逐字转写。
  /// 不经过 sendMessage，避免工具调用、历史拼接、消息落库等副作用；
  /// 调用方再把转写与对应的通话或视频上下文交给聊天模型回复。
  Future<String?> _transcribeWithChatModel({
    required Map<String, dynamic> provider,
    required String audioPath,
    String sourceContext = '',
    AICancellationToken? cancellationToken,
  }) async {
    return await MediaStorageService.instance.withMediaUse(() async {
      audioPath = await MediaStorageService.instance.resolve(audioPath);

      try {
        cancellationToken?.throwIfCancelled();
        final audio = File(audioPath);
        if (!await audio.exists()) {
          AppLogService.instance.add('STT', '主模型转写：语音文件不存在');
          return null;
        }
        final baseUrl = (provider['base_url'] ?? provider['url'] ?? '')
            .toString()
            .trim()
            .replaceFirst(RegExp(r'/+$'), '');
        final model =
            provider['model']?.toString().split(',').first.trim() ?? '';
        final apiKey = (provider['api_key'] ?? provider['key'] ?? '')
            .toString()
            .trim();
        if (baseUrl.isEmpty || model.isEmpty || apiKey.isEmpty) {
          AppLogService.instance.add('STT', '主模型转写失败：缺少地址、Key 或模型');
          return null;
        }
        final bytes = await MediaStorageService.instance.chatAudioBytes(
          audio.path,
        );
        const format = 'wav';
        final endpoint = _chatCompletionsEndpoint(baseUrl);
        final payload = {
          'model': model,
          'stream': false,
          'temperature': 0,
          'messages': [
            {
              'role': 'system',
              'content':
                  '你是语音转写器。只输出音频中说话人的原话（逐字转写），不要回答、不要解释、不要加引号或任何前缀。听不清或没有人声时只输出空字符串。',
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': [
                    if (sourceContext.trim().isNotEmpty) sourceContext.trim(),
                    '请逐字转写这段语音。',
                  ].join('\n'),
                },
                {
                  'type': 'input_audio',
                  'input_audio': {
                    'data': base64Encode(bytes),
                    'format': format,
                  },
                },
              ],
            },
          ],
        };
        AppLogService.instance.add(
          'STT',
          '请求主模型转写：model=$model，endpoint=$endpoint，${bytes.length} bytes，format=$format',
        );
        final response = await _withCancellableClient(cancellationToken, (
          client,
        ) {
          return client
              .post(
                Uri.parse(endpoint),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $apiKey',
                },
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 45));
        });
        final body = utf8.decode(response.bodyBytes, allowMalformed: true);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          AppLogService.instance.add(
            'STT',
            '主模型转写失败：HTTP ${response.statusCode} ${body.substring(0, body.length.clamp(0, 500))}',
          );
          return null;
        }
        final transcript = _extractChatContent(
          jsonDecode(body),
        ).trim().replaceAll(RegExp(r'^["“「]+|["”」]+$'), '').trim();
        if (transcript.isEmpty) {
          AppLogService.instance.add('STT', '主模型转写返回为空');
          return null;
        }
        return transcript;
      } on AICancelledException {
        rethrow;
      } catch (e) {
        cancellationToken?.throwIfCancelled();
        AppLogService.instance.add('STT', '主模型转写异常：$e');
        return null;
      }
    });
  }

  Future<String?> transcribeWithProvider(
    Map<String, dynamic> provider,
    String audioPath, {
    AICancellationToken? cancellationToken,
  }) async {
    try {
      return await MediaStorageService.instance.withRequestAudio(audioPath, (
        requestPath,
      ) async {
        audioPath = requestPath;

        try {
          cancellationToken?.throwIfCancelled();
          final audio = File(audioPath);
          if (!await audio.exists()) {
            AppLogService.instance.add('STT', '语音文件不存在');
            return null;
          }
          final baseUrl = (provider['base_url'] ?? provider['url'] ?? '')
              .toString()
              .trim()
              .replaceFirst(RegExp(r'/+$'), '');
          final model =
              provider['model']?.toString().split(',').first.trim() ?? '';
          final apiKey = (provider['api_key'] ?? provider['key'] ?? '')
              .toString()
              .trim();
          final protocol = (provider['protocol']?.toString() ?? 'openai')
              .trim()
              .toLowerCase();
          if (baseUrl.isEmpty || model.isEmpty || apiKey.isEmpty) {
            AppLogService.instance.add('STT', '语音转文字失败：缺少地址、Key 或模型');
            return null;
          }
          if (protocol == 'mimo') {
            return _transcribeMiMo(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              audio: audio,
              providerName: provider['name']?.toString() ?? 'MiMo STT',
              cancellationToken: cancellationToken,
            );
          }
          if (protocol != 'openai') {
            AppLogService.instance.add('STT', '不支持的 STT 协议：$protocol');
            return null;
          }
          final endpoint = _sttTranscriptionEndpoint(baseUrl);
          final request = http.MultipartRequest('POST', Uri.parse(endpoint))
            ..headers['Authorization'] = 'Bearer $apiKey'
            ..fields['model'] = model
            ..fields['response_format'] = 'json'
            ..files.add(await http.MultipartFile.fromPath('file', audioPath));
          final response = await _withCancellableClient(cancellationToken, (
            client,
          ) async {
            return http.Response.fromStream(
              await client.send(request).timeout(const Duration(seconds: 45)),
            );
          });
          final body = utf8.decode(response.bodyBytes, allowMalformed: true);
          if (response.statusCode < 200 || response.statusCode >= 300) {
            AppLogService.instance.add(
              'STT',
              '语音转文字失败：HTTP ${response.statusCode} ${body.substring(0, body.length.clamp(0, 500))}',
            );
            return null;
          }
          final decoded = jsonDecode(body);
          final transcript = decoded is Map
              ? decoded['text']?.toString().trim()
              : '';
          return transcript?.isEmpty == true ? null : transcript;
        } on AICancelledException {
          rethrow;
        } catch (e) {
          cancellationToken?.throwIfCancelled();
          AppLogService.instance.add('STT', '语音转文字异常：$e');
          return null;
        }
      });
    } on AICancelledException {
      rethrow;
    } catch (error) {
      AppLogService.instance.add('STT', '语音请求格式准备失败：$error');
      return null;
    }
  }

  Future<String> createSttProbeAudio() async {
    // A tiny valid PCM WAV containing 120 ms of silence.  It keeps the test a
    // real STT request without prompting the user to pick or record a file.
    const sampleRate = 8000;
    const samples = 960;
    const dataBytes = samples * 2;
    final bytes = BytesBuilder()
      ..add('RIFF'.codeUnits)
      ..add(_le32(36 + dataBytes))
      ..add('WAVEfmt '.codeUnits)
      ..add(_le32(16))
      ..add(_le16(1))
      ..add(_le16(1))
      ..add(_le32(sampleRate))
      ..add(_le32(sampleRate * 2))
      ..add(_le16(2))
      ..add(_le16(16))
      ..add('data'.codeUnits)
      ..add(_le32(dataBytes))
      ..add(List<int>.filled(dataBytes, 0));
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/tidebot_stt_probe.wav');
    await file.writeAsBytes(bytes.toBytes(), flush: true);
    return file.path;
  }

  List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];
  List<int> _le32(int value) => [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];

  Future<String?> _transcribeMiMo({
    required String baseUrl,
    required String apiKey,
    required String model,
    required File audio,
    required String providerName,
    AICancellationToken? cancellationToken,
  }) async {
    final endpoint = _chatCompletionsEndpoint(baseUrl);
    final bytes = await MediaStorageService.instance.chatAudioBytes(audio.path);
    const format = 'wav';
    final payload = {
      'model': model,
      'stream': false,
      'messages': [
        {
          // MiMo ASR 网关会自行注入转写指令；请求体中不能包含任何 text
          // content part（包括 system 文本），否则返回 HTTP 400。
          'role': 'user',
          'content': [
            {
              'type': 'input_audio',
              'input_audio': {'data': base64Encode(bytes), 'format': format},
            },
          ],
        },
      ],
    };
    AppLogService.instance.add(
      'STT',
      '请求 MiMo 语音转文字：provider=$providerName，model=$model，endpoint=$endpoint，${bytes.length} bytes，format=$format',
    );
    final response = await _withCancellableClient(cancellationToken, (client) {
      return client
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 60));
    });
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      AppLogService.instance.add(
        'STT',
        'MiMo 语音转文字失败：HTTP ${response.statusCode} ${body.substring(0, body.length.clamp(0, 800))}',
      );
      return null;
    }
    final decoded = jsonDecode(body);
    final transcript = _extractChatContent(decoded).trim();
    if (transcript.isEmpty) {
      AppLogService.instance.add(
        'STT',
        'MiMo 语音转文字返回为空：${body.substring(0, body.length.clamp(0, 500))}',
      );
      return null;
    }
    return transcript;
  }

  String _sttTranscriptionEndpoint(String configuredUrl) {
    final root = configuredUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (root.endsWith('/audio/transcriptions')) return root;
    if (root.endsWith('/v1')) return '$root/audio/transcriptions';
    return '$root/v1/audio/transcriptions';
  }

  String _chatCompletionsEndpoint(String configuredUrl) {
    final root = configuredUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (root.endsWith('/chat/completions')) return root;
    if (root.endsWith('/v1')) return '$root/chat/completions';
    return '$root/v1/chat/completions';
  }

  // TTS supports both legacy base_url/api_key and settings-page url/key fields.
  Future<String?> _generateTTS(
    String text,
    String providerId, {
    String mood = '平静',
    CallSpeechStyle? speechStyle,
    AICancellationToken? cancellationToken,
  }) async {
    final list = await DBManager().queryTtsProviders();
    Map<String, dynamic>? provider;
    try {
      provider = list.firstWhere((p) => p['id'] == providerId);
    } catch (_) {}
    if (provider == null) return null;

    final baseUrl = (provider['base_url'] ?? provider['url'] ?? '')
        .toString()
        .trim()
        .replaceFirst(RegExp(r'/+$'), '');
    final apiKey = (provider['api_key'] ?? provider['key'] ?? '')
        .toString()
        .trim();
    final protocol = (provider['protocol']?.toString() ?? 'openai')
        .trim()
        .toLowerCase();
    final configuredVoice = (provider['voice']?.toString() ?? '').trim();
    final voice = configuredVoice.isEmpty || configuredVoice == 'default'
        ? switch (protocol) {
            'mimo' => 'mimo_default',
            'minimax' => 'male-qn-qingse',
            _ => 'alloy',
          }
        : configuredVoice;
    final moodSpeed = switch (mood) {
      '开心' || '兴奋' => 1.08,
      '难过' || '低落' => 0.91,
      '生气' || '愤怒' => 1.04,
      _ => 1.0,
    };
    final moodPitch = switch (mood) {
      '开心' || '兴奋' => 2,
      '难过' || '低落' => -2,
      '生气' || '愤怒' => 1,
      _ => 0,
    };
    final modelName = (provider['model']?.toString() ?? '').trim();
    var model = modelName.isEmpty
        ? (provider['name']?.toString() ?? 'tts-1')
        : modelName;
    if (protocol == 'unsupported') {
      AppLogService.instance.add('TTS', '该 TTS 服务暂未提供可验证的调用协议');
      return null;
    }
    if (baseUrl.isEmpty || apiKey.isEmpty || text.trim().isEmpty) {
      AppLogService.instance.add('TTS', '语音合成失败：缺少地址、Key 或文本');
      return null;
    }

    try {
      var requestVoice = voice;
      if (protocol == 'mimo') {
        final clone = provider['mimo_clone'] is Map
            ? Map<String, dynamic>.from(provider['mimo_clone'] as Map)
            : null;
        model = mimoSynthesisModel(model, configuredVoice, clone);
        if (isMimoClone(protocol, configuredVoice)) {
          requestVoice = await mimoReferenceVoice(clone);
        }
      }
      final endpoint = switch (protocol) {
        'minimax' => miniMaxTtsEndpoint(baseUrl),
        'mimo' => _chatCompletionsEndpoint(baseUrl),
        _ => '$baseUrl/audio/speech',
      };
      final siliconHost = Uri.tryParse(baseUrl)?.host ?? '';
      final effectiveVoice =
          (configuredVoice.isEmpty || configuredVoice == 'default') &&
              (siliconHost == 'api.siliconflow.cn' ||
                  siliconHost == 'api.siliconflow.com') &&
              model.contains('CosyVoice2-0.5B')
          ? '$model:alex'
          : voice;
      final basePayload = switch (protocol) {
        'minimax' => {
          'model': model,
          'text': text,
          'stream': false,
          'output_format': 'hex',
          'voice_setting': {
            'voice_id': voice,
            'speed': speechStyle == null ? moodSpeed : 1.0,
            'vol': 1.0,
            'pitch': speechStyle == null ? moodPitch : 0,
          },
          'audio_setting': {
            'sample_rate': 32000,
            'bitrate': 128000,
            'format': 'mp3',
            'channel': 1,
          },
        },
        'mimo' => {
          // MiMo V2.5 TTS uses standard chat completions, but differs from
          // the audio-modalities schema: the text to synthesize MUST be in
          // an assistant message. A preceding user message is optional and
          // only carries voice/style instructions. `modalities` is not part
          // of MiMo's documented TTS payload and causes HTTP 400.
          'model': model,
          'stream': false,
          'messages': [
            {'role': 'assistant', 'content': text},
          ],
          'audio': {'voice': requestVoice, 'format': 'wav'},
        },
        _ => {
          'model': model,
          'input': text,
          'voice': effectiveVoice,
          if (speechStyle == null && moodSpeed != 1.0) 'speed': moodSpeed,
        },
      };
      final payload = speechStyle == null
          ? basePayload
          : applyCallSpeechStyle(
              basePayload,
              protocol: protocol,
              model: model,
              baseUrl: baseUrl,
              style: speechStyle,
              supportsInstructions: provider['supports_instructions'] == true,
            );
      cancellationToken?.throwIfCancelled();
      AppLogService.instance.add(
        'TTS',
        '请求语音：provider=${provider['name'] ?? providerId}，protocol=$protocol，model=$model，endpoint=$endpoint，文本 ${text.length} 字',
      );
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      };
      Future<http.Response> request(Map<String, dynamic> body) =>
          _withCancellableClient(
            cancellationToken,
            (client) => client
                .post(
                  Uri.parse(endpoint),
                  headers: headers,
                  body: jsonEncode(body),
                )
                .timeout(
                  Duration(
                    seconds: isMimoClone(protocol, configuredVoice) ? 90 : 30,
                  ),
                ),
          );
      var res = await request(payload);
      // Only retry rejected expressive parameters; no retry on auth/rate limits.
      if (speechStyle != null &&
          (res.statusCode == 400 ||
              res.statusCode == 422 ||
              (res.headers['content-type'] ?? '').contains('json')) &&
          shouldRetryBasicSpeech(
            res.statusCode,
            utf8.decode(res.bodyBytes, allowMalformed: true),
          )) {
        cancellationToken?.throwIfCancelled();
        AppLogService.instance.add('TTS', '表现参数被拒绝，使用基础语音参数重试一次');
        res = await request(basePayload);
      }
      AppLogService.instance.add(
        'TTS',
        '语音服务响应 HTTP ${res.statusCode}，content-type=${res.headers['content-type'] ?? 'unknown'}',
      );
      if (res.statusCode < 200 ||
          res.statusCode >= 300 ||
          res.bodyBytes.isEmpty) {
        final responseText = utf8.decode(res.bodyBytes, allowMalformed: true);
        AppLogService.instance.add(
          'TTS',
          '语音合成失败：HTTP ${res.statusCode}${responseText.isEmpty ? '' : '，响应：${responseText.substring(0, responseText.length.clamp(0, 1000))}'}',
        );
        return null;
      }

      var bytes = res.bodyBytes;
      final contentType = (res.headers['content-type'] ?? '').toLowerCase();
      if (protocol == 'minimax') {
        bytes = decodeMiniMaxTtsAudio(jsonDecode(utf8.decode(bytes)));
      } else if (contentType.contains('json') ||
          utf8.decode(bytes, allowMalformed: true).trimLeft().startsWith('{')) {
        AppLogService.instance.addJson('TTS', '语音服务 JSON 响应', {
          'status': res.statusCode,
          'body': utf8.decode(bytes, allowMalformed: true),
        });
        final raw = jsonDecode(utf8.decode(bytes));
        if (raw is Map &&
            (raw['base_resp'] is Map) &&
            ((raw['base_resp'] as Map)['status_code'] as num?) != 0) {
          AppLogService.instance.add(
            'TTS',
            '语音服务返回错误：${(raw['base_resp'] as Map)['status_msg'] ?? raw['base_resp']}',
          );
          return null;
        }
        String? audioUrl;
        if (raw is Map) {
          final output = raw['output'];
          final data = raw['data'];
          final choices = raw['choices'];
          final message =
              choices is List && choices.isNotEmpty && choices.first is Map
              ? (choices.first as Map)['message']
              : null;
          final messageAudio = message is Map ? message['audio'] : null;
          final outputAudio = output is Map ? output['audio'] : null;
          final dataAudio = data is Map ? data['audio'] : null;
          audioUrl =
              raw['audio_url']?.toString() ??
              raw['url']?.toString() ??
              (messageAudio is Map
                  ? (messageAudio['url'] ?? messageAudio['audio_url'])
                        ?.toString()
                  : null) ??
              (outputAudio is Map
                  ? (outputAudio['url'] ?? outputAudio['audio_url'])?.toString()
                  : null) ??
              (dataAudio is Map
                  ? (dataAudio['url'] ?? dataAudio['audio_url'])?.toString()
                  : null) ??
              (output is Map
                  ? (output['audio_url'] ?? output['url'])?.toString()
                  : null) ??
              (data is Map
                  ? (data['audio_url'] ?? data['url'])?.toString()
                  : null);
          final inlineAudio = _inlineAudioFromTtsResponse(raw);
          if (inlineAudio != null && inlineAudio.isNotEmpty) {
            try {
              final compact = inlineAudio.replaceAll(RegExp(r'\s+'), '');
              bytes =
                  RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact) &&
                      compact.length.isEven
                  ? Uint8List.fromList(
                      List<int>.generate(
                        compact.length ~/ 2,
                        (index) => int.parse(
                          compact.substring(index * 2, index * 2 + 2),
                          radix: 16,
                        ),
                      ),
                    )
                  : base64Decode(compact);
            } catch (_) {
              AppLogService.instance.add('TTS', '语音服务返回的内嵌音频无法解码');
              return null;
            }
          }
          if (audioUrl != null && audioUrl.isNotEmpty) {
            final resolvedAudioUrl = audioUrl;
            cancellationToken?.throwIfCancelled();
            final audioResponse = await _withCancellableClient(
              cancellationToken,
              (client) {
                return client
                    .get(Uri.parse(resolvedAudioUrl))
                    .timeout(const Duration(seconds: 30));
              },
            );
            if (audioResponse.statusCode < 200 ||
                audioResponse.statusCode >= 300 ||
                audioResponse.bodyBytes.isEmpty) {
              AppLogService.instance.add(
                'TTS',
                '语音文件下载失败：HTTP ${audioResponse.statusCode}',
              );
              return null;
            }
            bytes = audioResponse.bodyBytes;
          } else if (inlineAudio == null || inlineAudio.isEmpty) {
            AppLogService.instance.add('TTS', '语音合成返回 JSON，但没有可用音频');
            return null;
          }
        }
      }

      final directory = await getApplicationDocumentsDirectory();
      final extension = protocol == 'minimax'
          ? 'mp3'
          : _audioExtension(bytes, contentType);
      final path =
          '${directory.path}/tide_tts_${DateTime.now().millisecondsSinceEpoch}.$extension';
      await File(path).writeAsBytes(bytes);
      AppLogService.instance.add(
        'TTS',
        '语音合成成功：${text.length} 字，${bytes.length} bytes，已保存 $path',
      );
      return path;
    } on AICancelledException {
      rethrow;
    } catch (e) {
      cancellationToken?.throwIfCancelled();
      AppLogService.instance.add('TTS', '语音合成异常：$e');
      if (isMimoClone(protocol, configuredVoice) && e is FormatException) {
        GlobalNotice.show(e.message);
      }
      return null;
    }
  }

  String? _inlineAudioFromTtsResponse(dynamic raw) {
    if (raw is! Map) return null;
    String? readAudio(dynamic value) {
      if (value is! Map) return null;
      return (value['hex'] ?? value['audio_hex'] ?? value['data'])?.toString();
    }

    final output = raw['output'];
    final data = raw['data'];
    final choices = raw['choices'];
    final message =
        choices is List && choices.isNotEmpty && choices.first is Map
        ? (choices.first as Map)['message']
        : null;
    return readAudio(raw['audio']) ??
        readAudio(output is Map ? output['audio'] : null) ??
        readAudio(data is Map ? data['audio'] : null) ??
        readAudio(message is Map ? message['audio'] : null) ??
        (message is Map ? message['audio_data']?.toString() : null);
  }

  String _audioExtension(Uint8List bytes, String contentType) {
    final type = contentType.toLowerCase();
    if (type.contains('mpeg') || type.contains('mp3')) return 'mp3';
    if (type.contains('ogg')) return 'ogg';
    if (type.contains('aac')) return 'aac';
    if (type.contains('wav') || type.contains('wave')) return 'wav';
    if (bytes.length >= 3 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33)
      return 'mp3';
    if (bytes.length >= 4 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46)
      return 'wav';
    if (bytes.length >= 4 &&
        bytes[0] == 0x4f &&
        bytes[1] == 0x67 &&
        bytes[2] == 0x67 &&
        bytes[3] == 0x53)
      return 'ogg';
    return 'wav';
  }

  // 空间广场：今日一言生成逻辑
  Future<String> getDailyQuote(String botId) async {
    final db = DBManager();
    final todayStr =
        "${DateTime.now().year}-${DateTime.now().month}-${DateTime.now().day}";
    final lastDate = await db.getKV('quote_date_$botId');
    final lastQuote = await db.getKV('quote_text_$botId');

    if (lastDate == todayStr && lastQuote != null)
      return singleDailyQuote(lastQuote);

    final bots = await db.getAllBots();
    final bot = bots.firstWhere((b) => b['id'] == botId, orElse: () => {});
    if (bot.isEmpty || bot['chat_model'] == null) return "今天也要开心度过哦。";
    if (isBotDisabled(bot['is_disabled'])) return "今天也要开心度过哦。";

    // 暗中调用 AI 引擎生成，但不暴露在聊天历史中。
    // persistResponse=false 保证生成的回复不会写入聊天室，也不会被自动摘要捕获；
    // includeChatHistory=false 避免今日一言影响正式对话的上下文。
    final recentQuotes = (await Future.wait(
      List.generate(
        3,
        (i) async => await db.getKV(
          'quote_text_${botId}_${DateTime.now().subtract(Duration(days: i + 1)).year}-${DateTime.now().subtract(Duration(days: i + 1)).month}-${DateTime.now().subtract(Duration(days: i + 1)).day}',
        ),
      ),
    )).whereType<String>().where((e) => e.isNotEmpty).join('｜');
    final res = await sendMessage(
      botId: botId,
      priority: false,
      task: AIRequestTask.dailyQuote,
      text: '近三天已用文案：$recentQuotes。请换不同主题与角度，避免重复、高度近似或仅替换个别词语。',
      persistResponse: false,
      includeChatHistory: false,
      enableAutoSummary: false,
      allowTools: false,
      allowStickers: false,
      forceSingleReply: true,
    );
    if (res['success'] == true) {
      final normalized = singleDailyQuote(res['reply']?.toString() ?? '');
      await db.setKV('quote_date_$botId', todayStr);
      await db.setKV('quote_text_$botId', normalized);
      // 同时写入带日期后缀的 key，供“近三天去重”按日期查询命中，
      // 避免上屏查询用带日期 key、而保存只写无日期 key 导致去重一直失效。
      await db.setKV('quote_text_${botId}_$todayStr', normalized);
      return normalized;
    }
    return "今天也要开心度过哦。";
  }

  // API 测速（返回 Map，兼容旧代码）
  Future<Map<String, dynamic>> testConnectionMap(
    String baseUrl,
    String apiKey,
    String modelName,
  ) async {
    final start = DateTime.now();
    try {
      final res = await http
          .post(
            Uri.parse("$baseUrl/chat/completions"),
            headers: {
              "Content-Type": "application/json",
              "Authorization": "Bearer $apiKey",
            },
            body: jsonEncode({
              "model": modelName,
              "messages": [
                {"role": "user", "content": "1"},
              ],
              "max_tokens": 5,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        return {
          'success': true,
          'delay': DateTime.now().difference(start).inMilliseconds,
        };
      }
      return {'success': false, 'error': '服务端返回 HTTP ${res.statusCode}'};
    } catch (e) {
      return {'success': false, 'error': '无法连接，请检查 URL 格式或网络'};
    }
  }

  // API 测速（返回 int 毫秒，供新 UI 使用；失败抛异常）
  Future<int> testConnection(
    String baseUrl,
    String apiKey,
    String modelName,
  ) async {
    final result = await testConnectionMap(baseUrl, apiKey, modelName);
    if (result['success'] == true) {
      return result['delay'] as int;
    }
    throw Exception(result['error'] ?? '连接失败');
  }

  bool _needsWebSearch(String text) {
    const cues = [
      '搜索',
      '查一下',
      '查找',
      '联网',
      '最新',
      '新闻',
      '实时',
      '今天',
      '天气',
      '汇率',
      '价格',
      '股价',
      '比赛结果',
    ];
    return cues.any(text.contains);
  }

  /// 归一化搜索服务商名称：剥离 UI 上附加的“（需外网）”等可达性标注，
  /// 兼容新旧取值，统一映射到路由用的规范化名称。
  String _normalizeSearchProvider(String raw) {
    final base = raw.replaceAll(RegExp(r'[（(].*[)）]'), '').trim();
    if (base.contains('Agent-Reach') || base.contains('Agent Reach')) {
      return 'Agent Reach';
    }
    if (base.toLowerCase().contains('deepseek')) return 'DeepSeek';
    if (base.contains('Tavily')) return 'Tavily';
    if (base.contains('博查') || base.contains('Bocha')) return '博查 Bocha';
    if (base.contains('Serper')) return 'Serper';
    if (base.contains('Brave')) return 'Brave Search';
    if (base.contains('Bing')) return 'Bing Web Search';
    return base;
  }

  Future<List<Map<String, String>>> _searchIfAuthorized(
    DBManager db,
    String query, {
    bool force = false,
  }) async {
    if ((!force && !_needsWebSearch(query)) ||
        await db.getKV('web_search_enabled') != 'true')
      return [];
    final apiKey = (await db.getKV('web_search_api_key') ?? '').trim();
    if (apiKey.isEmpty) return [];
    final provider = _normalizeSearchProvider(
      await db.getKV('web_search_provider') ?? '',
    );
    List<Map<String, String>> rows;
    try {
      late final http.Response response;
      if (provider == 'DeepSeek') {
        rows = await searchDeepSeek(query: query, apiKey: apiKey);
      } else if (provider == 'Tavily') {
        response = await http
            .post(
              Uri.parse('https://api.tavily.com/search'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'api_key': apiKey,
                'query': query,
                'max_results': 5,
              }),
            )
            .timeout(const Duration(seconds: 15));
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        rows = _searchRows(body['results']);
      } else if (provider == '博查 Bocha') {
        response = await http
            .post(
              Uri.parse('https://api.bochaai.com/v1/web-search'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
              body: jsonEncode({'query': query, 'count': 5}),
            )
            .timeout(const Duration(seconds: 15));
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        rows = _searchRows(
          body['data']?['webPages']?['value'] ?? body['data']?['value'],
        );
      } else if (provider == 'Serper') {
        response = await http
            .post(
              Uri.parse('https://google.serper.dev/search'),
              headers: {
                'Content-Type': 'application/json',
                'X-API-KEY': apiKey,
              },
              body: jsonEncode({'q': query, 'num': 5}),
            )
            .timeout(const Duration(seconds: 15));
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        rows = _searchRows(body['organic']);
      } else if (provider == 'Brave Search') {
        response = await http
            .get(
              Uri.parse(
                'https://api.search.brave.com/res/v1/web/search?q=${Uri.encodeQueryComponent(query)}&count=5',
              ),
              headers: {
                'Accept': 'application/json',
                'X-Subscription-Token': apiKey,
              },
            )
            .timeout(const Duration(seconds: 15));
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        rows = _searchRows(body['web']?['results']);
      } else {
        response = await http
            .get(
              Uri.parse(
                'https://api.bing.microsoft.com/v7.0/search?q=${Uri.encodeQueryComponent(query)}&count=5',
              ),
              headers: {'Ocp-Apim-Subscription-Key': apiKey},
            )
            .timeout(const Duration(seconds: 15));
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        rows = _searchRows(body['webPages']?['value']);
      }
    } catch (_) {
      rows = [];
    }
    // 路由策略：普通搜索引擎搜不到时，若已配置 Agent-Reach 桥接地址，
    // 自动降级到 Agent-Reach 的补充平台搜索渠道。
    if (rows.isEmpty) {
      // Agent-Reach 是内部兜底能力，桥接地址与普通搜索 API Key 分开保存，
      // 不暴露为用户可选的搜索服务商。
      final bridge = (await db.getKV('agent_reach_bridge_url') ?? '').trim();
      if (bridge.startsWith('http')) {
        final bridgeRows = await _searchViaAgentReach(bridge, query);
        if (bridgeRows.isNotEmpty) return bridgeRows;
      }
    }
    return rows;
  }

  /// Agent-Reach 平台路由：按查询意图命中 GitHub / YouTube / B站 / X / 小红书 /
  /// Reddit 等渠道，命中则走对应渠道，否则退回 its 全网语义搜索渠道。
  Future<List<Map<String, String>>> _searchViaAgentReach(
    String bridge,
    String query,
  ) async {
    try {
      final base = bridge.replaceFirst(RegExp(r'/+$'), '');
      if (!base.startsWith('http')) return [];
      final routes = <Map<String, dynamic>>[
        {
          'route': 'github',
          'cues': ['github', '仓库', 'repo', '代码仓库', 'issue'],
        },
        {
          'route': 'youtube',
          'cues': ['youtube', 'youtube频道', '油管', '视频教程'],
        },
        {
          'route': 'bilibili',
          'cues': ['b站', '哔哩', 'bilibili', 'bili', '弹幕'],
        },
        {
          'route': 'twitter',
          'cues': ['推特', 'twitter', 'x平台', 'x站'],
        },
        {
          'route': 'xiaohongshu',
          'cues': ['小红书', 'xhs', 'xiaohongshu', '种草'],
        },
        {
          'route': 'reddit',
          'cues': ['reddit', '红迪'],
        },
      ];
      final lower = query.toLowerCase();
      String? route;
      for (final entry in routes) {
        final cues = entry['cues'] as List;
        if (cues.any((cue) => lower.contains(cue.toString()))) {
          route = entry['route'] as String;
          break;
        }
      }
      final path = route != null ? '/$route/search' : '/exa/search';
      final response = await http
          .post(
            Uri.parse('$base$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'query': query, 'limit': 5}),
          )
          .timeout(const Duration(seconds: 18));
      if (response.statusCode < 200 || response.statusCode >= 300) return [];
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      return _searchRows(
        body['results'] ?? body['data'] ?? body['items'] ?? body,
      );
    } catch (_) {
      return [];
    }
  }

  List<Map<String, String>> _searchRows(dynamic rows) {
    if (rows is! List) return [];
    return rows
        .map((raw) {
          final row = raw is Map ? raw : const <String, dynamic>{};
          return <String, String>{
            'title':
                row['title']?.toString() ?? row['name']?.toString() ?? '网页来源',
            'url': row['url']?.toString() ?? row['link']?.toString() ?? '',
            'snippet':
                row['content']?.toString() ??
                row['snippet']?.toString() ??
                row['description']?.toString() ??
                '',
          };
        })
        .where((row) => row['url']!.startsWith('http'))
        .toList();
  }

  bool _needsImageGeneration(String text) {
    const cues = ['生成图片', '生成一张图', '画一张', '画个', '帮我画', '生图', '画图', '绘制'];
    return cues.any(text.contains);
  }

  Future<String?> generateImageForBot({
    required String botId,
    required String prompt,
    bool usePortraitReference = false,
  }) => _generateImageIfAuthorized(
    db: DBManager(),
    botId: botId,
    prompt: prompt,
    force: true,
    usePortraitReference: usePortraitReference,
  );

  String _imagePromptWithStyle(String prompt, String style) {
    final normalized = prompt.trim();
    if (style.isEmpty || style == '不选择') return normalized;
    return '$normalized。画面必须严格采用$style风格，除该风格外不得使用冲突的视觉表现。';
  }

  Future<String?> _generateImageIfAuthorized({
    required DBManager db,
    required String botId,
    required String prompt,
    bool force = false,
    bool usePortraitReference = false,
    UserImageEditSelection? userImageEdit,
  }) async {
    if ((!force && !_needsImageGeneration(prompt)) ||
        await db.getKV('bot_image_generation_enabled') == 'false')
      return null;
    final prefs = await SharedPreferences.getInstance();
    final imageModelId = (prefs.getString('image_gen_model_$botId') ?? '')
        .trim();
    if (imageModelId.isEmpty) {
      AppLogService.instance.add('IMAGE_GEN', '生图模型未配置（botId=$botId）');
      return null;
    }
    final provider = await db.getChatProviderById(imageModelId);
    if (provider == null) {
      AppLogService.instance.add(
        'IMAGE_GEN',
        '生图模型提供商不存在（modelId=$imageModelId）',
      );
      return null;
    }
    final baseUrl = (provider['base_url']?.toString() ?? '').replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    if (baseUrl.isEmpty) {
      AppLogService.instance.add('IMAGE_GEN', '生图模型 baseUrl 为空');
      return null;
    }
    // Temporary edits send the model-authored prompt byte-for-byte. Do not
    // read bot style, outfit or portrait reference settings in this branch.
    final imagePrompt =
        userImageEdit?.prompt ??
        _imagePromptWithStyle(
          prompt,
          (await db.getKV('bot_image_style') ?? '').trim(),
        );
    final isImageEdit = userImageEdit != null || usePortraitReference;
    try {
      final referencePath =
          userImageEdit?.path ??
          (usePortraitReference
              ? (await db.getKV('bot_image_reference_$botId') ?? '').trim()
              : '');
      if (isImageEdit && referencePath.isEmpty) {
        AppLogService.instance.add('IMAGE_GEN', '已选择图改，但未设置人像参考图，取消请求');
        return null;
      }
      final reference = isImageEdit
          ? await modelImageBytes(
              referencePath,
              compress: await db.getKV('image_compression_enabled') != 'false',
            )
          : null;
      AppLogService.instance.addJson('IMAGE_GEN', '开始请求生图', {
        'bot_id': botId,
        'mode': userImageEdit != null
            ? 'temporary_image_edit'
            : (usePortraitReference ? 'image_edit' : 'text_to_image'),
        'use_portrait_reference': userImageEdit == null && usePortraitReference,
        'endpoint': '$baseUrl/images/${isImageEdit ? 'edits' : 'generations'}',
        'model': provider['model'],
        'prompt': imagePrompt,
      });
      final request = buildBotImageRequest(
        baseUrl: baseUrl,
        model: provider['model'].toString(),
        apiKey: provider['api_key']?.toString() ?? '',
        prompt: imagePrompt,
        reference: reference,
        applyPortraitInstructions: userImageEdit == null,
      );
      final client = http.Client();
      late http.Response response;
      try {
        response = await (() async => http.Response.fromStream(
          await client.send(request),
        ))().timeout(const Duration(seconds: 120));
      } finally {
        client.close();
      }
      AppLogService.instance.add(
        'IMAGE_GEN',
        '生图接口响应：HTTP ${response.statusCode}（bodyLength=${response.bodyBytes.length}）',
      );
      if (response.statusCode != 200) {
        AppLogService.instance.add(
          'IMAGE_GEN',
          '生图接口返回非 200 状态码：${response.statusCode}，body=${utf8.decode(response.bodyBytes, allowMalformed: true)}',
        );
        return null;
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final data = body['data'];
      if (data is! List || data.isEmpty) {
        AppLogService.instance.add(
          'IMAGE_GEN',
          '生图接口返回的 data 字段为空或格式错误：${body.toString()}',
        );
        return null;
      }
      final item = data.first;
      final directory = await getApplicationDocumentsDirectory();
      final path =
          '${directory.path}/tide_image_${DateTime.now().millisecondsSinceEpoch}.png';
      final b64 = item['b64_json']?.toString();
      if (b64 != null && b64.isNotEmpty) {
        await File(path).writeAsBytes(base64Decode(b64));
        AppLogService.instance.add('IMAGE_GEN', '生图成功（base64 模式）：$path');
        return path;
      }
      final url = item['url']?.toString() ?? '';
      if (url.startsWith('http')) {
        AppLogService.instance.add('IMAGE_GEN', '开始下载图片：$url');
        final file = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 90));
        if (file.statusCode == 200) {
          await File(path).writeAsBytes(file.bodyBytes);
          AppLogService.instance.add('IMAGE_GEN', '生图成功（URL 下载模式）：$path');
          return path;
        } else {
          AppLogService.instance.add(
            'IMAGE_GEN',
            '图片下载失败：HTTP ${file.statusCode}',
          );
        }
      } else {
        AppLogService.instance.add(
          'IMAGE_GEN',
          '生图接口返回的 data 既无 b64_json 也无有效 url：${item.toString()}',
        );
      }
    } catch (e, stack) {
      AppLogService.instance.add(
        'IMAGE_GEN',
        '生图异常：$e\n${stack.toString().split('\n').take(5).join('\n')}',
      );
    }
    return null;
  }

  /// 统一执行工具调用并取得模型 follow-up 文本。供流式与非流式两条链路复用，
  /// 保证「工具结果 → 最终回答」在两种模式下行为一致。
  Future<void> _runStreamedTools({
    AICancellationToken? cancellationToken,
    required DBManager db,
    required String botId,
    required List<Map<String, dynamic>> calls,
    required List<Map<String, dynamic>> messages,
    required String baseUrl,
    required String cacheScope,
    required String requestId,
    required String modelName,
    required String apiKey,
    required int maxTokens,
    void Function(String delta)? onDelta,
    required void Function(String) replyTextCallback,
    required void Function(String) innerThoughtSetter,
    required void Function(Map) usageCallback,
    required void Function(List<Map<String, String>>) searchSourcesSetter,
    required void Function(String) generatedImageSetter,
    required void Function(Map<String, dynamic>) pendingDeviceActionSetter,
    required void Function() silenceSetter,
    required void Function(Map<String, dynamic>) stickerSetter,
    required void Function(String) moodSetter,
    required void Function(CallSpeechStyle) voiceSetter,
    List<Map<String, dynamic>> requestTools = const [],
    Set<String> requiredToolNames = const {},
    Set<String> allowedStickerTypes = const {},
    Map<int, String> inspectableImages = const {},
    Map<int, String> currentImages = const {},
  }) async {
    final completedTools = <String>{};

    Future<void> consumeToolResult(
      Map<String, dynamic> result, {
      required String name,
    }) async {
      final toolResult = result['result'];
      if (toolResult is Map && toolResult['ok'] == true) {
        if (name == 'set_emotion') {
          final mood = toolResult['mood']?.toString();
          if (mood != null && mood.isNotEmpty) moodSetter(mood);
        } else if (name == 'send_sticker') {
          final sticker = toolResult['sticker'];
          if (sticker is Map) stickerSetter(Map<String, dynamic>.from(sticker));
        } else if (name == 'request_voice_reply') {
          voiceSetter(CallSpeechStyle.fromJson(toolResult['speech']));
        }
        if (name == 'set_emotion' || name == 'send_sticker') {
          completedTools.add(name);
        }
      }
      if (result['sources'] is List) {
        searchSourcesSetter(
          (result['sources'] as List)
              .whereType<Map>()
              .map((item) => Map<String, String>.from(item))
              .toList(),
        );
      }
      if (toolResult is Map && toolResult['silent'] == true) {
        silenceSetter();
      }
      if (toolResult is Map &&
          toolResult['image_path']?.toString().isNotEmpty == true) {
        generatedImageSetter(toolResult['image_path'].toString());
      }
    }

    Future<Map<String, dynamic>> executeOnce(Map<String, dynamic> call) async {
      await cancellationToken?.checkRequestAllowed();
      final name = (call['function'] as Map?)?['name']?.toString() ?? '';
      if (!requestTools.any(
        (tool) => (tool['function'] as Map?)?['name'] == name,
      )) {
        return {
          'result': {'ok': false, 'error': '本任务未授权该工具：$name'},
        };
      }
      if ((name == 'set_emotion' || name == 'send_sticker') &&
          completedTools.contains(name)) {
        AppLogService.instance.add(
          'TOOLS',
          '跳过重复工具调用：$name id=${call['id']}，本轮已成功执行',
        );
        return {
          'result': {'ok': false, 'error': '本轮工具已成功调用，不允许重复执行。'},
        };
      }
      AppLogService.instance.add(
        'TOOLS',
        '开始执行工具：${name.isEmpty ? "缺少工具名称" : name}（id=${call['id']}，argumentsLength=${(call['function'] as Map?)?['arguments']?.toString().length ?? 0}）',
      );
      final stopwatch = Stopwatch()..start();
      Map<String, dynamic> result;
      try {
        result = await _executeNativeToolCall(
          db: db,
          botId: botId,
          call: call,
          allowedStickerTypes: allowedStickerTypes,
          inspectableImages: inspectableImages,
          currentImages: currentImages,
        );
      } on AICancelledException {
        rethrow;
      } catch (error, stack) {
        AppLogService.instance.add(
          'TOOLS',
          '工具执行异常：$name id=${call['id']} elapsedMs=${stopwatch.elapsedMilliseconds} error=$error\n$stack',
        );
        result = {
          'result': {'ok': false, 'error': '工具执行异常：$error'},
        };
      }
      await cancellationToken?.checkRequestAllowed();
      final outcome = result['result'];
      AppLogService.instance.addJson('TOOLS', '工具执行结果：$name', {
        'tool_call_id': call['id'],
        'elapsed_ms': stopwatch.elapsedMilliseconds,
        'ok': outcome is Map ? outcome['ok'] : false,
        'error': outcome is Map ? outcome['error'] : null,
        'message': outcome is Map ? outcome['message'] : null,
        'has_image': outcome is Map && outcome['image_path'] != null,
      });
      return result;
    }

    for (final call in calls) {
      final result = await executeOnce(call);
      final name = (call['function'] as Map?)?['name']?.toString() ?? '';
      await consumeToolResult(result, name: name);
      if ((result['result'] as Map?)?['silent'] == true) return;
      messages.add({
        'role': 'tool',
        'tool_call_id': call['id']?.toString() ?? '',
        'content': jsonEncode(result['result'] ?? result),
      });
    }
    final missingRequired = requiredToolNames.difference(completedTools);
    if (missingRequired.isNotEmpty) {
      messages.add({
        'role': 'system',
        'content':
            '本轮仍缺少必须完成的原生工具调用：${missingRequired.join('、')}。请先仅调用缺失工具，再给出正常可见文字回复；不得在正文输出工具协议。',
      });
    }
    // Keep the same transcript across multi-step tools. Each follow-up may ask
    // for another action; its result is appended and sent back until the model
    // stops using tools. A hard limit prevents accidental infinite automation.
    for (var round = 0; round < 12; round++) {
      final followUpId = '${requestId}_tool_${round + 1}';
      final followUpPayload = prepareChatCompletionPayload({
        'model': modelName,
        'messages': prepareOpenAIChatCompletionMessages(messages),
        'max_tokens': maxTokens,
        if (requestTools.isNotEmpty) 'tools': requestTools,
        if (requestTools.isNotEmpty) 'tool_choice': 'auto',
        if (onDelta != null) 'stream': true,
      });
      _logRequestPrefix(
        '$cacheScope|$requestId|tool_chain',
        followUpId,
        followUpPayload,
        const {},
      );
      final followUp = await _withCancellableClient(
        cancellationToken,
        (client) => client
            .post(
              Uri.parse('$baseUrl/chat/completions'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
              body: jsonEncode(followUpPayload),
            )
            .timeout(const Duration(seconds: 60)),
      );
      await cancellationToken?.checkRequestAllowed();
      if (followUp.statusCode != 200) {
        AppLogService.instance.add(
          'TOOLS',
          '工具后续请求失败：HTTP ${followUp.statusCode}',
        );
        replyTextCallback('工具执行后的回复请求失败，请查看工具执行结果。');
        return;
      }
      final decoded = decodeToolCompletion(utf8.decode(followUp.bodyBytes));
      final message = decoded['choices']?[0]?['message'];
      final fu = decoded['usage'];
      if (fu is Map) {
        AppLogService.instance.add(
          'CACHE',
          '工具后续响应：round=${round + 1} model=$modelName',
        );
        _logCacheUsage(
          fu,
          stage: 'tool_follow_up',
          requestId: followUpId,
          responseMetadata: {
            ...cacheResponseMetadata(decoded as Map),
            'provider_request_id':
                followUp.headers['x-request-id'] ??
                followUp.headers['request-id'],
          },
        );
        usageCallback(fu);
      }
      if (message is! Map) return;
      final parsedReply = parseChatReply(diaryResponseContent(message));
      final next = parsedReply.text;
      if (parsedReply.innerThought != null) {
        innerThoughtSetter(parsedReply.innerThought!);
      }
      final nextCalls = message['tool_calls'] is List
          ? (message['tool_calls'] as List)
                .whereType<Map>()
                .map((call) => Map<String, dynamic>.from(call))
                .toList()
          : <Map<String, dynamic>>[];
      if (nextCalls.isEmpty) {
        final stillMissing = requiredToolNames.difference(completedTools);
        if (stillMissing.isNotEmpty && round < 1) {
          messages.add({'role': 'assistant', 'content': message['content']});
          messages.add({
            'role': 'system',
            'content':
                '你刚刚遗漏了本轮强制工具调用：${stillMissing.join('、')}。请立即调用这些工具，然后给出可见文字回复。',
          });
          continue;
        }
        if (stillMissing.isNotEmpty) {
          AppLogService.instance.add(
            'TOOLS',
            '工具补全重试后仍缺少：${stillMissing.join('、')}',
          );
        }
        if (next.isNotEmpty) {
          replyTextCallback(next);
          onDelta?.call(next);
        }
        return;
      }
      messages.add(toolAssistantMessage(message));
      for (final call in nextCalls) {
        final result = await executeOnce(call);
        final name = (call['function'] as Map?)?['name']?.toString() ?? '';
        await consumeToolResult(result, name: name);
        messages.add({
          'role': 'tool',
          'tool_call_id': call['id']?.toString() ?? '',
          'content': jsonEncode(result['result'] ?? result),
        });
      }
    }
    replyTextCallback('任务已达到连续操作上限，请确认当前结果后再继续。');
  }

  Future<List<String>> _availableStickerEmotions(DBManager db) async {
    if (await db.getKV('bot_stickers_enabled') != 'true') {
      return const [];
    }
    final emotions = <String>{};
    for (final sticker in await db.queryStickers()) {
      final emotion = sticker['emotion']?.toString().trim() ?? '';
      if (emotion.isNotEmpty) emotions.add(emotion);
    }
    return emotions.toList()..sort();
  }

  Future<bool> _shouldSuggestStickerForTurn(DBManager db) async {
    final chance =
        (int.tryParse(await db.getKV('bot_sticker_chance') ?? '') ?? 30).clamp(
          0,
          100,
        );
    final selected =
        chance >= 100 || (chance > 0 && Random.secure().nextInt(100) < chance);
    AppLogService.instance.add(
      'STICKER',
      selected ? '本轮建议发送表情包（概率 $chance%），由模型决定' : '本轮无表情包建议，模型仍可自主发送',
    );
    return selected;
  }

  Future<List<Map<String, dynamic>>> _buildNativeTools(
    DBManager db, {
    required String botId,
    bool includeEmotion = false,
    bool allowSticker = false,
    bool allowSilence = true,
    Set<String> stickerTypes = const {},
  }) async {
    final tools = <Map<String, dynamic>>[];
    if (includeEmotion) {
      tools.add(_setEmotionToolSchema());
    }
    if (allowSticker && stickerTypes.isNotEmpty) {
      tools.add(sendStickerToolSchema(stickerTypes.toList()..sort()));
    }
    tools.add(viewVideoToolSchema());
    tools.add(inspectImageToolSchema(name: 'inspect_image'));
    tools.add(inspectImageToolSchema(name: 'look_at_image'));
    if (await db.getKV('web_search_enabled') == 'true' &&
        (await db.getKV('web_search_api_key') ?? '').trim().isNotEmpty) {
      tools.add({
        'type': 'function',
        'function': {
          'name': 'web_search',
          'description': '查询需要实时性、外部来源或事实核验的信息。',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '简洁明确的搜索关键词'},
            },
            'required': ['query'],
            'additionalProperties': false,
          },
        },
      });
    }
    if (await db.getKV('bot_image_generation_enabled') != 'false') {
      // 具体 bot 是否配置生图模型由执行阶段校验，未配置时返回明确 tool 结果。
      final hasPortraitReference =
          (await db.getKV('bot_image_reference_$botId') ?? '')
              .trim()
              .isNotEmpty;
      tools.add(botImageToolSchema(hasPortraitReference: hasPortraitReference));
      // Availability belongs to the per-request image maps, never the schema.
      // Keep this definition present even for text turns; execution validates it.
      tools.add(userImageEditToolSchema());
    }
    tools.add({
      'type': 'function',
      'function': {
        'name': 'create_future_task',
        'description':
            '仅在用户明确要求提醒、定时、稍后执行或安排未来事项时创建未来任务。创建前必须确认当前未来任务中没有同一事项；相同标题、时间或目的的任务不得重复创建。run_at 必须是当地未来时间，格式 YYYY-MM-DD HH:mm。',
        'parameters': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string', 'description': '简短任务标题'},
            'prompt': {'type': 'string', 'description': '到时要执行或提醒的完整内容'},
            'run_at': {
              'type': 'string',
              'description': '当地未来时间，YYYY-MM-DD HH:mm',
            },
            'frequency': {
              'type': 'string',
              'enum': ['once', 'daily'],
              'description': '一次或每天',
            },
          },
          'required': ['title', 'run_at'],
          'additionalProperties': false,
        },
      },
    });
    if (await LifeScheduleService.instance.enabled()) {
      tools.add({
        'type': 'function',
        'function': {
          'name': 'update_life_state',
          'description': '仅当真实聊天使生活状态确有必要改变时，更新自己的详细穿搭、心情或今日可变日程。绝不可删除或改写刚性事项。',
          'parameters': {
            'type': 'object',
            'properties': {
              'kind': {
                'type': 'string',
                'enum': ['outfit', 'schedule'],
                'description': 'outfit 仅换穿搭；schedule 替换今日可变日程且必须原样保留刚性事项',
              },
              'outfit': {'type': 'string', 'description': '换装时的完整从头到脚穿搭描述'},
              'mood': {'type': 'string', 'description': '可选的新心情'},
              'timeline': {
                'type': 'array',
                'items': {'type': 'object'},
                'description': '改日程时的完整时间线；刚性事项必须保留 time、activity 与 rigid:true',
              },
            },
            'required': ['kind'],
            'additionalProperties': false,
          },
        },
      });
    }
    if (allowSilence && await db.getKV('adaptive_silence_enabled') != 'false') {
      tools.add(_adaptiveSilenceToolSchema());
    }
    tools.add(_memoryToolSchema());
    tools.add(_createMemoryCategoryToolSchema());
    tools.add(_searchMemoryToolSchema()); // 新增：记忆库搜索工具
    tools.add(_diaryToolSchema());
    tools.add(_queryDiaryToolSchema());
    if (await db.getKV('voice_reply_enabled') == 'true') {
      final bot = await db.getBotById(botId);
      if ((bot?['tts_model']?.toString().trim() ?? '').isNotEmpty) {
        tools.add(_requestVoiceReplyToolSchema());
      }
    }
    tools.addAll(await _buildExternalTools(db, botId));

    // 发起语音通话工具
    tools.add({
      'type': 'function',
      'function': {
        'name': 'initiate_voice_call',
        'description':
            '给用户发起语音通话。只在真实需要实时交流、讨论复杂话题或用户明确表示希望通话时调用。调用后会给用户发送通知，用户可以接听或拒接。',
        'parameters': {
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        },
      },
    });

    return tools;
  }

  Future<ToolPackageCatalog> _toolPackages(DBManager db, String botId) async =>
      ToolPackageCatalog(
        skills: await db.querySkills(botId: botId),
        servers: await db.queryMcpServers(botId: botId),
        skillTools: await db.queryEnabledSkillTools(botId: botId),
        mcpTools: await db.queryEnabledMcpTools(botId: botId),
      );

  Future<List<Map<String, dynamic>>> _buildExternalTools(
    DBManager db,
    String botId,
  ) async => [
    ...(await _toolPackages(db, botId)).schemas(),
    ...await PluginService.instance.schemas(),
  ];

  Future<Map<String, dynamic>> _executePackageTool({
    required DBManager db,
    required String botId,
    required String name,
    required Map<String, dynamic> args,
  }) async {
    try {
      return await executeToolPackage(
        catalog: await _toolPackages(db, botId),
        name: name,
        args: args,
        execute: (source, id, toolName, arguments, referenceReader) async {
          if (source == 'skill') {
            if (referenceReader) {
              return _executeNativeToolCall(
                db: db,
                botId: botId,
                call: {
                  'function': {
                    'name': 'read_skill_file',
                    'arguments': jsonEncode({...arguments, 'id': id}),
                  },
                },
              );
            }
            return _executeSkillToolCall(
              db: db,
              botId: botId,
              name: skillToolName(id, toolName),
              args: arguments,
            );
          }
          return _executeMcpToolCall(
            db: db,
            botId: botId,
            name: mcpToolName(id, toolName),
            args: arguments,
          );
        },
      );
    } catch (error) {
      return {
        'result': {'ok': false, 'error': '工具包调用失败：$error'},
      };
    }
  }

  Map<String, dynamic> _setEmotionToolSchema() => {
    'type': 'function',
    'function': {
      'name': 'set_emotion',
      'description': '只有心情相较当前状态发生有意义变化时才调用，更新角色心情；没有变化无需调用。不得在聊天正文输出心情标签。',
      'parameters': {
        'type': 'object',
        'properties': {
          'mood': {
            'type': 'string',
            'enum': ['平静', '开心', '伤心', '生气', '害羞', '兴奋'],
          },
          'intensity': {'type': 'integer', 'minimum': 0, 'maximum': 100},
          'reason': {'type': 'string', 'maxLength': 160},
        },
        'required': ['mood', 'intensity'],
        'additionalProperties': false,
      },
    },
  };

  Map<String, dynamic> _adaptiveSilenceToolSchema() => {
    'type': 'function',
    'function': {
      'name': 'choose_silence',
      'description':
          '在角色自己的睡眠时段可自主选择暂不回复；或在用户明确不希望回复、对话自然结束且无需回应、主动问候判断不宜打扰时调用。调用后本轮不会发送任何文字。清醒时不可用于求助、悲伤、愤怒、困惑、危机、提问或任何需要回应的情况；绝不可作为惩罚、冷暴力、控制或施压。',
      'parameters': {
        'type': 'object',
        'properties': {},
        'additionalProperties': false,
      },
    },
  };
  Map<String, dynamic> _memoryToolSchema() => {
    'type': 'function',
    'function': {
      'name': 'save_memory',
      'description':
          '按记忆分类与写入步骤保存新事实。事件必须写入“记忆”，禁止写入人物画像或关系。更新已有条目须传 memory_id 并提交保留旧有效信息的完整新版。禁止重复保存；仅 ok:true 表示写入成功。',
      'parameters': {
        'type': 'object',
        'properties': {
          'content': {
            'type': 'string',
            'description':
                '事件须写清主体，可用姓名或指代明确的人称，你自己的经历可用“我”，他／她须性别已知；人物画像只写总结出的稳定特点，禁止写具体事件；更新须保留旧有效信息并提交完整内容',
          },
          'importance': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 5,
            'description': '记忆优先级：1低，3普通，5重要；仅相关记忆参与排序',
          },
          'keys': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                '用于检索的事件或主题关键词；绝对禁止你自己或对方的姓名、昵称、别名及包含这些名字的短语；无合适词时传空数组',
          },
          'memory_id': {
            'type': 'string',
            'description': '更新已有条目时填写最近世界书或搜索结果中的 id；新建时省略。不得跨类别覆盖。',
          },
          'category': {
            'type': 'string',
            'description': '从当前世界书类别中选择；默认记忆，新类别须先创建',
          },
          'type': {
            'type': 'string',
            'enum': ['long', 'short'],
            'description': 'long 用于稳定画像或偏好；short 用于重要近期事件',
          },
        },
        'required': ['content', 'type', 'category'],
        'additionalProperties': false,
      },
    },
  };

  Map<String, dynamic> _createMemoryCategoryToolSchema() => {
    'type': 'function',
    'function': {
      'name': 'create_memory_category',
      'description': '当现有记忆类别都不合适时创建一个简洁的类别；成功后再用 save_memory 添加记忆。',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '类别名称'},
        },
        'required': ['name'],
        'additionalProperties': false,
      },
    },
  };
  Map<String, dynamic> _diaryToolSchema() => {
    'type': 'function',
    'function': {
      'name': 'write_diary',
      'description':
          '在以下两种场景时调用：1）本轮聊天中出现明确的用户事件、稳定事实或真实感受；2）你自己今天的真实经历、想法、感受、做过的事、见到的人或场景。日记是你的私人记录，可以写用户的事，也可以写你自己的生活、心情或观察，但不能编造未发生的事。',
      'parameters': {
        'type': 'object',
        'properties': {
          'entry': {
            'type': 'string',
            'description': '第一人称日记正文，可以记录用户相关事件，也可以记录你自己今天的经历、心情或想法',
          },
        },
        'required': ['entry'],
        'additionalProperties': false,
      },
    },
  };
  Map<String, dynamic> _queryDiaryToolSchema() => {
    'type': 'function',
    'function': {
      'name': 'query_diary',
      'description':
          '仅在需要回顾自己某一天的日记且用户或当前对话已明确日期时调用。日记不会自动提供给你；只能查询自己的日记，date 必须为 YYYY-MM-DD。',
      'parameters': {
        'type': 'object',
        'properties': {
          'date': {'type': 'string', 'description': '要查询的本地日期，格式 YYYY-MM-DD'},
        },
        'required': ['date'],
        'additionalProperties': false,
      },
    },
  };

  Map<String, dynamic> _searchMemoryToolSchema() => {
    'type': 'function',
    'function': {
      'name': 'search_memory',
      'description':
          '当需要主动查找世界书记忆库中的特定信息时调用（例如用户询问"我的时薪是多少"、"你记得XX吗"、"我之前跟你说过什么"）。使用语义搜索，能匹配同义词（如"工资"能匹配到"时薪"）。不会自动注入记忆；需要时必须主动搜索。',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '搜索关键词或问题描述，例如"时薪"、"工资"、"收入信息"',
          },
          'limit': {
            'type': 'integer',
            'description': '返回结果数量，默认5条',
            'minimum': 1,
            'maximum': 10,
          },
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    },
  };

  Map<String, dynamic> _requestVoiceReplyToolSchema() => {
    'type': 'function',
    'function': {
      'name': 'request_voice_reply',
      'description':
          '当本轮安排语音、用户明确要求语音，或内容适合用语音自然表达时调用。必须在 speech 中填写本条语音的情绪和演绎指导；正文不输出语音参数。不发送语音时无需调用。',
      'parameters': {
        'type': 'object',
        'properties': {'speech': voiceMessageSpeechSchema()},
        'required': ['speech'],
        'additionalProperties': false,
      },
    },
  };

  String _redactToolInput(Map<String, dynamic> args) => redactToolInput(args);

  Future<Map<String, dynamic>> _executeSkillToolCall({
    required String botId,
    required DBManager db,
    required String name,
    required Map<String, dynamic> args,
  }) async {
    final rows = await db.queryEnabledSkillTools(botId: botId);
    final row = rows
        .where((item) => skillToolName(item['skill_id'], item['name']) == name)
        .firstOrNull;
    if (row == null)
      return {
        'result': {'ok': false, 'error': 'Skill 工具不可用'},
      };
    final skillId = row['skill_id'];
    final toolName = row['name'];
    final skillRows = await db.querySkills(botId: botId);
    final skill = skillRows.firstWhere(
      (item) => item['id'] == skillId,
      orElse: () => <String, dynamic>{},
    );
    final manifest = jsonDecode(skill['manifest_json']?.toString() ?? '{}');
    final definitions = manifest is Map ? manifest['tools'] : null;
    final definition = definitions is List
        ? definitions.cast<dynamic>().firstWhere(
            (item) => item is Map && item['name']?.toString() == toolName,
            orElse: () => null,
          )
        : null;
    if (definition is! Map) {
      return {
        'result': {'ok': false, 'error': 'Skill 工具定义不存在'},
      };
    }
    final executor = row['executor']?.toString() ?? '';
    if (executor == 'mcp_proxy') {
      return _executeSkillMcpProxy(
        botId: botId,
        db: db,
        skillName: name,
        definition: Map<String, dynamic>.from(definition),
        args: args,
      );
    }
    if (executor == 'prompt') {
      final template = definition['prompt']?.toString().trim() ?? '';
      return {
        'result': {'ok': true, 'content': template, 'arguments': args},
      };
    }
    if (executor != 'http') {
      return {
        'result': {'ok': false, 'error': '该 Skill 执行器不支持直接调用'},
      };
    }
    final started = DateTime.now();
    try {
      final uri = Uri.tryParse(definition['url']?.toString() ?? '');
      if (uri == null || !uri.hasScheme)
        throw const FormatException('HTTP URL 无效');
      final headers = <String, String>{'Content-Type': 'application/json'};
      final secret = await const FlutterSecureStorage().read(
        key: 'skill_headers_$skillId',
      );
      if (secret != null && secret.isNotEmpty) {
        final decoded = jsonDecode(secret);
        if (decoded is Map)
          decoded.forEach(
            (key, value) => headers[key.toString()] = value.toString(),
          );
      }
      final response = await http
          .post(uri, headers: headers, body: jsonEncode(args))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP Skill ${response.statusCode}');
      }
      final body = response.body.length > 100000
          ? response.body.substring(0, 100000)
          : response.body;
      await db.insertToolAudit(
        source: 'skill',
        toolName: name,
        inputSummary: _redactToolInput(args),
        status: 'success',
        durationMs: DateTime.now().difference(started).inMilliseconds,
      );
      return {
        'result': {'ok': true, 'content': body},
      };
    } catch (error) {
      await db.insertToolAudit(
        source: 'skill',
        toolName: name,
        inputSummary: _redactToolInput(args),
        status: 'error',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: '工具执行失败（${error.runtimeType}）',
      );
      return {
        'result': {'ok': false, 'error': 'HTTP Skill 调用失败：$error'},
      };
    }
  }

  Future<Map<String, dynamic>> _executeSkillMcpProxy({
    required String botId,
    required DBManager db,
    required String skillName,
    required Map<String, dynamic> definition,
    required Map<String, dynamic> args,
  }) async {
    final serverId = definition['mcp_server_id']?.toString().trim() ?? '';
    final targetTool = definition['mcp_tool']?.toString().trim() ?? '';
    final started = DateTime.now();
    try {
      final server = (await db.queryMcpServers(botId: botId)).firstWhere(
        (item) => item['id']?.toString() == serverId && item['enabled'] == 1,
        orElse: () => <String, dynamic>{},
      );
      if (server.isEmpty) {
        throw StateError('目标 MCP 服务不可用');
      }
      final enabledTool = (await db.queryEnabledMcpTools(botId: botId)).any(
        (item) =>
            item['server_id']?.toString() == serverId &&
            item['name']?.toString() == targetTool,
      );
      if (!enabledTool) {
        throw StateError('目标 MCP 工具未发现或已禁用');
      }
      const secure = FlutterSecureStorage();
      final storedHeaders = await secure.read(key: 'mcp_headers_$serverId');
      final headers = <String, String>{};
      if (storedHeaders != null && storedHeaders.isNotEmpty) {
        final decoded = jsonDecode(storedHeaders);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            headers[key.toString()] = value.toString();
          });
        }
      }
      final timeoutMs = (server['timeout_ms'] as num?)?.toInt() ?? 20000;
      final client = McpClient(
        url: server['url'].toString(),
        headers: headers,
        timeout: Duration(milliseconds: timeoutMs),
      );
      dynamic content;
      try {
        await client.initialize();
        content = await client.callTool(targetTool, args);
      } finally {
        try {
          await client.close();
        } catch (_) {
          // Session cleanup must not replace the tool result or original error.
        } finally {
          client.dispose();
        }
      }
      await db.insertToolAudit(
        source: 'skill:mcp_proxy',
        toolName: skillName,
        inputSummary: _redactToolInput(args),
        status: 'success',
        durationMs: DateTime.now().difference(started).inMilliseconds,
      );
      return {
        'result': {'ok': true, 'content': content},
      };
    } catch (error) {
      await db.insertToolAudit(
        source: 'skill:mcp_proxy',
        toolName: skillName,
        inputSummary: _redactToolInput(args),
        status: 'error',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: '工具执行失败（${error.runtimeType}）',
      );
      return {
        'result': {'ok': false, 'error': 'Skill MCP 代理调用失败：$error'},
      };
    }
  }

  Future<Map<String, dynamic>> _executeMcpToolCall({
    required String botId,
    required DBManager db,
    required String name,
    required Map<String, dynamic> args,
  }) async {
    final rows = await db.queryEnabledMcpTools(botId: botId);
    final row = resolveMcpTool(rows, name);
    if (row == null)
      return {
        'result': {'ok': false, 'error': 'MCP 工具不可用'},
      };
    final serverId = row['server_id'].toString();
    final toolName = row['name'].toString();
    final started = DateTime.now();
    try {
      const secure = FlutterSecureStorage();
      final storedHeaders = await secure.read(key: 'mcp_headers_$serverId');
      final headers = <String, String>{};
      if (storedHeaders != null && storedHeaders.isNotEmpty) {
        final decoded = jsonDecode(storedHeaders);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key.toString().toLowerCase() != 'authorization') {
              headers[key.toString()] = value.toString();
            } else {
              headers[key.toString()] = value.toString();
            }
          });
        }
      }
      final timeoutMs = (row['timeout_ms'] as num?)?.toInt() ?? 20000;
      final client = McpClient(
        url: row['url'].toString(),
        headers: headers,
        timeout: Duration(milliseconds: timeoutMs),
      );
      dynamic value;
      try {
        await client.initialize();
        value = await client.callTool(toolName, args);
      } finally {
        try {
          await client.close();
        } catch (_) {
          // Session cleanup must not replace the tool result or original error.
        } finally {
          client.dispose();
        }
      }
      await db.insertToolAudit(
        source: 'mcp',
        toolName: name,
        inputSummary: _redactToolInput(args),
        status: 'success',
        durationMs: DateTime.now().difference(started).inMilliseconds,
      );
      // callTool 返回的 value 已包含 content 字段，直接提取避免嵌套
      final content = value is Map && value.containsKey('content')
          ? value['content']
          : value;
      return {
        'result': {
          'ok': true,
          'content': content,
          if (value is Map && value.containsKey('structuredContent'))
            'structuredContent': value['structuredContent'],
        },
      };
    } catch (error) {
      await db.insertToolAudit(
        source: 'mcp',
        toolName: name,
        inputSummary: _redactToolInput(args),
        status: 'error',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: '工具执行失败（${error.runtimeType}）',
      );
      return {
        'result': {'ok': false, 'error': 'MCP 调用失败：$error'},
      };
    } finally {
      AppLogService.instance.add(
        'MCP',
        '调用 $serverId/$toolName，耗时 ${DateTime.now().difference(started).inMilliseconds}ms',
      );
    }
  }

  Future<Map<String, dynamic>> _executeNativeToolCall({
    required DBManager db,
    required String botId,
    required Map<String, dynamic> call,
    Set<String> allowedStickerTypes = const {},
    Map<int, String> inspectableImages = const {},
    Map<int, String> currentImages = const {},
  }) async {
    final before = await PluginService.instance.hook('tool.before', {
      'botId': botId,
      'call': call,
    });
    final Map<String, dynamic> result;
    if (before['handled'] == true && before['result'] is Map) {
      result = Map<String, dynamic>.from(before['result'] as Map);
    } else {
      result = await _executeNativeToolCallCore(
        db: db,
        botId: botId,
        call: before['call'] is Map
            ? Map<String, dynamic>.from(before['call'] as Map)
            : call,
        allowedStickerTypes: allowedStickerTypes,
        inspectableImages: inspectableImages,
        currentImages: currentImages,
      );
    }
    final after = await PluginService.instance.hook('tool.after', {
      'botId': botId,
      'call': call,
      'result': result,
    });
    return after['result'] is Map
        ? Map<String, dynamic>.from(after['result'] as Map)
        : result;
  }

  Future<Map<String, dynamic>> _executeNativeToolCallCore({
    required DBManager db,
    required String botId,
    required Map<String, dynamic> call,
    Set<String> allowedStickerTypes = const {},
    Map<int, String> inspectableImages = const {},
    Map<int, String> currentImages = const {},
  }) async {
    final function = call['function'];
    if (function is! Map)
      return {
        'result': {'ok': false, 'error': '无效工具调用'},
      };
    final name = function['name']?.toString() ?? '';
    Map<String, dynamic> args;
    try {
      args = _decodeToolArguments(function['arguments']);
    } on FormatException {
      return {
        'result': {'ok': false, 'error': '工具参数不是合法 JSON'},
      };
    }
    if (name.startsWith('tp_')) {
      return PluginService.instance.execute(name, args, botId: botId);
    }
    if (name == 'get_tool_package' || name == 'call_package_tool') {
      return _executePackageTool(db: db, botId: botId, name: name, args: args);
    }
    // Keep old in-flight calls compatible without disclosing raw executors.
    if (name == 'read_skill') {
      return _executePackageTool(
        db: db,
        botId: botId,
        name: 'get_tool_package',
        args: {'package_id': 'skill:${args['id']}'},
      );
    }
    if (name == 'read_skill_file') {
      try {
        final skill = (await db.querySkills(
          botId: botId,
        )).where((s) => s['id'] == args['id'] && s['enabled'] == 1).firstOrNull;
        if (skill == null) throw const FormatException('技能不存在或已停用');
        final manifest = Map<String, dynamic>.from(
          jsonDecode(skill['manifest_json'].toString()) as Map,
        );
        final path = SkillPackage.safePath(args['path']?.toString() ?? '');
        if (!(manifest['files'] as List? ?? []).contains(path))
          throw const FormatException('文件不属于此技能');
        final base = manifest['storage_path']?.toString();
        if (base == null) throw const FormatException('旧技能需重新导入后读取附带文件');
        final file = File('$base/$path');
        if (await file.length() > 2 * 1024 * 1024)
          throw const FormatException('文本文件超过 2 MB');
        final text = utf8.decode(await file.readAsBytes());
        if (text.contains('\u0000')) throw const FormatException('不支持读取二进制文件');
        final offset = args['offset'] is int ? args['offset'] as int : 0;
        if (offset < 0 || offset > text.length)
          throw const FormatException('offset 超出文件范围');
        final end = min(offset + 24000, text.length);
        return {
          'result': {
            'ok': true,
            'content': text.substring(offset, end),
            'next_offset': end < text.length ? end : null,
            'total_characters': text.length,
          },
        };
      } catch (error) {
        return {
          'result': {'ok': false, 'error': '读取 Skill 失败：$error'},
        };
      }
    }
    if (name.startsWith('mcp_')) {
      return _executeMcpToolCall(db: db, botId: botId, name: name, args: args);
    }
    if (name.startsWith('skill_')) {
      return _executeSkillToolCall(
        db: db,
        botId: botId,
        name: name,
        args: args,
      );
    }
    if (name == 'set_emotion') {
      const moods = {'平静', '开心', '伤心', '生气', '害羞', '兴奋'};
      final mood = args['mood']?.toString().trim() ?? '';
      final intensity = (args['intensity'] as num?)?.toInt();
      if (!moods.contains(mood) ||
          intensity == null ||
          intensity < 0 ||
          intensity > 100) {
        return {
          'result': {'ok': false, 'error': '心情或强度无效'},
        };
      }
      await EmotionStateService.instance.setMood(
        botId,
        mood,
        intensity: intensity,
      );
      await db.insertToolAudit(
        source: 'native',
        toolName: name,
        inputSummary: _redactToolInput(args),
        status: 'success',
        durationMs: 0,
      );
      return {
        'result': {'ok': true, 'mood': mood, 'message': '当前心情已写入。'},
      };
    }
    if (name == 'send_sticker') {
      final type = (args['type'] ?? args['emotion'])?.toString().trim() ?? '';
      if (type.isEmpty || !allowedStickerTypes.contains(type)) {
        return {
          'result': {'ok': false, 'error': '表情包类型不在本轮允许列表中'},
        };
      }
      final stickers = await db.queryStickers(emotion: type);
      if (stickers.isEmpty) {
        return {
          'result': {'ok': false, 'error': '该类型表情包素材池为空'},
        };
      }
      final sticker = Map<String, dynamic>.from(
        stickers[Random.secure().nextInt(stickers.length)],
      );
      await db.insertToolAudit(
        source: 'native',
        toolName: name,
        inputSummary: _redactToolInput({'type': type}),
        status: 'success',
        durationMs: 0,
      );
      return {
        'result': {
          'ok': true,
          'sticker': sticker,
          'type': type,
          'message': '已按类型 $type 选择表情包并加入本轮发送队列。',
        },
      };
    }
    if (name == 'inspect_image' || name == 'look_at_image') {
      final number = parseImageNumber(args['image_number'] ?? args['number']);
      if (number == null) {
        return {
          'result': {'ok': false, 'error': '缺少有效的图片编号'},
        };
      }
      final path = inspectableImages[number] ?? '';
      if (path.isEmpty) {
        return {
          'result': {'ok': false, 'error': '图片编号 $number 不在当前上下文中'},
        };
      }
      if (!await File(path).exists()) {
        return {
          'result': {'ok': false, 'error': '图片#$number 文件不存在或已失效'},
        };
      }
      try {
        final description = await _inspectImageForBot(
          botId: botId,
          imagePath: path,
          imageNumber: number,
        );
        await db.insertToolAudit(
          source: 'native',
          toolName: name,
          inputSummary: _redactToolInput({'number': number}),
          status: 'success',
          durationMs: 0,
        );
        return {
          'result': {'ok': true, 'image_path': path},
          'message': description,
        };
      } catch (error) {
        return {
          'result': {'ok': false, 'error': '图片识别失败：$error'},
        };
      }
    }
    if (name == 'view_video') {
      final videoId = args['video_id']?.toString().trim() ?? '';
      if (videoId.isEmpty || !videoId.startsWith('VID')) {
        return {
          'result': {'ok': false, 'error': '缺少有效的视频编号（格式：VIDxxxx）'},
        };
      }

      try {
        // 从SharedPreferences读取视频历史
        final prefs = await SharedPreferences.getInstance();
        final videoHistory = prefs.getStringList('video_history_$botId') ?? [];

        // 查找匹配的视频
        Map<String, dynamic>? videoInfo;
        for (final videoJson in videoHistory.reversed) {
          try {
            final video = json.decode(videoJson) as Map<String, dynamic>;
            if (video['id'] == videoId) {
              videoInfo = video;
              break;
            }
          } catch (_) {}
        }

        if (videoInfo == null) {
          return {
            'result': {'ok': false, 'error': '视频编号 $videoId 不在当前对话历史中'},
          };
        }
        // Original-model analysis has no frame files. Reuse the saved result
        // rather than treating an intentionally empty frame list as lost media.
        final savedAnalysis =
            videoInfo['analysis_context']?.toString().trim() ?? '';
        if (args['full_video'] != true &&
            savedAnalysis.isNotEmpty &&
            (videoInfo['frame_paths'] as List?)?.isEmpty == true) {
          return {
            'result': {'ok': true, 'video_id': videoId},
            'message': savedAnalysis,
          };
        }
        if (args['full_video'] == true) {
          final path = videoInfo['original_video_path']?.toString() ?? '';
          if (path.isEmpty || !await File(path).exists()) {
            throw StateError('完整视频文件不可用，请重新发送视频');
          }
          final bot = await db.getBotById(botId);
          final modelId =
              (prefs.getString('video_model_$botId') ??
                      bot?['video_model']?.toString() ??
                      '')
                  .trim();
          if (modelId.isNotEmpty) {
            final analysis = await describeVideoForBot(
              videoPath: path,
              botId: botId,
              providerId: modelId,
              userText: '请分析整个视频，补充预览未覆盖的内容。',
            );
            return {
              'result': {'ok': true, 'video_id': videoId, 'full_video': true},
              'message': analysis,
            };
          }
          final service = VideoProcessingService.instance;
          final fullDuration = await service.getVideoDuration(path);
          if (fullDuration <= 0) throw StateError('无法读取完整视频时长');
          final frames = await service.extractFrames(
            videoPath: path,
            frameCount: (fullDuration / 8).ceil().clamp(1, 120),
            duration: fullDuration,
            previewLongVideo: false,
          );
          if (frames.isEmpty) throw StateError('完整视频抽帧失败');
          return {
            'result': {
              'ok': true,
              'video_id': videoId,
              'full_video': true,
              'duration': fullDuration,
            },
            'message': '未选择视频解析模型，以下为覆盖全片的采样画面，音频请结合先前转写；采样不能保证覆盖每个细节。',
            'images': frames,
          };
        }
        // 构建视频信息响应

        var duration = (videoInfo['duration'] as num?)?.toDouble() ?? 0.0;
        var framePaths =
            (videoInfo['frame_paths'] as List?)?.cast<String>() ?? [];
        final platformLink = videoInfo['platform_link'] as String?;
        final platform = videoInfo['platform'] as String?;
        final title = videoInfo['title'] as String?;
        final originalVideoPath = videoInfo['original_video_path'] as String?;

        // 检查帧文件是否存在
        final existingFrames = <String>[];
        for (final path in framePaths) {
          if (await File(path).exists()) {
            existingFrames.add(path);
          }
        }

        // 如果帧文件不存在
        if (existingFrames.isEmpty) {
          // 检查是否有保存的原始视频文件（用户上传视频）
          if (originalVideoPath != null &&
              originalVideoPath.isNotEmpty &&
              await File(originalVideoPath).exists()) {
            // 重新从保存的视频文件中抽帧
            try {
              await db.insertToolAudit(
                source: 'native',
                toolName: name,
                inputSummary: _redactToolInput({'video_id': videoId}),
                status: 'info',
                durationMs: 0,
                error: '视频帧已失效，正在从保存的视频文件重新抽帧...',
              );

              final videoService = VideoProcessingService.instance; // 需要导入该类
              if (duration <= 0) {
                duration = await videoService.getVideoDuration(
                  originalVideoPath,
                );
                if (duration <= 0) throw StateError('无法读取历史视频时长');
                videoInfo['duration'] = duration;
              }
              final config = videoService.calculateFrameConfig(duration);
              final newFramePaths = await videoService.extractFrames(
                videoPath: originalVideoPath,
                frameCount: config.frameCount,
                duration: duration,
              );

              if (newFramePaths.isNotEmpty) {
                framePaths = newFramePaths;

                // 更新历史记录中的帧路径
                videoInfo['frame_paths'] = newFramePaths;
                final prefs = await SharedPreferences.getInstance();
                final videoHistory =
                    prefs.getStringList('video_history_$botId') ?? [];
                for (int i = 0; i < videoHistory.length; i++) {
                  try {
                    final video =
                        json.decode(videoHistory[i]) as Map<String, dynamic>;
                    if (video['id'] == videoId) {
                      videoHistory[i] = json.encode(videoInfo);
                      break;
                    }
                  } catch (_) {}
                }
                await prefs.setStringList('video_history_$botId', videoHistory);
              } else {
                return {
                  'result': {'ok': false, 'error': '重新抽帧失败，无法获取视频内容。'},
                };
              }
            } catch (e) {
              return {
                'result': {'ok': false, 'error': '重新抽帧时出错：$e'},
              };
            }
          } else if (platformLink != null && platformLink.isNotEmpty) {
            // 平台视频：无法恢复
            await db.insertToolAudit(
              source: 'native',
              toolName: name,
              inputSummary: _redactToolInput({'video_id': videoId}),
              status: 'error',
              durationMs: 0,
              error: '视频帧文件已失效，平台视频需要重新分享链接',
            );
            return {
              'result': {
                'ok': false,
                'error': '视频帧文件已失效。平台视频文件不会长期保存，请重新分享该视频链接。',
                'platform_link': platformLink,
              },
            };
          } else {
            // 既没有原始视频也没有平台链接
            await db.insertToolAudit(
              source: 'native',
              toolName: name,
              inputSummary: _redactToolInput({'video_id': videoId}),
              status: 'error',
              durationMs: 0,
              error: '视频文件不存在或已被清理',
            );
            return {
              'result': {'ok': false, 'error': '视频文件不存在或已被清理，无法获取视频内容。'},
            };
          }
        }

        framePaths = existingFrames;

        final durationText = _formatVideoDuration(duration.toInt());
        final parts = <String>[];

        parts.add('[视频详情]');
        parts.add('编号：$videoId');
        parts.add('时长：$durationText');
        parts.add('实际可用帧数：${framePaths.length} 帧');

        if (platformLink != null && platform != null) {
          final platformName = platform == 'douyin'
              ? '抖音'
              : platform == 'xiaohongshu'
              ? '小红书'
              : platform == 'bilibili'
              ? 'B站'
              : platform;
          parts.add('来源：$platformName');
          if (title != null && title.isNotEmpty) {
            parts.add('标题：$title');
          }
          parts.add('链接：$platformLink');
        }

        final message = parts.join('\n');

        await db.insertToolAudit(
          source: 'native',
          toolName: name,
          inputSummary: _redactToolInput({'video_id': videoId}),
          status: 'success',
          durationMs: 0,
        );

        return {
          'result': {
            'ok': true,
            'video_id': videoId,
            'duration': duration,
            'frame_count': framePaths.length,
            'platform': platform,
            'platform_link': platformLink,
            'title': title,
          },
          'message': message,
          'images': framePaths,
        };
      } catch (error) {
        return {
          'result': {'ok': false, 'error': '查看视频失败：$error'},
        };
      }
    }
    if (name == 'choose_silence') {
      return {
        'result': {'ok': true, 'silent': true},
      };
    }
    if (name == 'create_memory_category') {
      final category = args['name']?.toString().trim() ?? '';
      if (category.isEmpty || category.length > 40 || category.contains('\n')) {
        return {
          'result': {'ok': false, 'error': '类别名称须为1至40个字符的单行文本'},
        };
      }
      if (!(await db.memoryCategories()).contains(category)) {
        await db.setKV('wb_category_$category', '4284513675');
      }
      return {
        'result': {
          'ok': true,
          'category': category,
          'categories': await db.memoryCategories(),
        },
      };
    }
    if (name == 'save_memory') {
      var content = args['content']?.toString().trim() ?? '';
      final type = args['type']?.toString() == 'long' ? 'long' : 'short';
      final category = args['category']?.toString().trim() ?? '记忆';
      if (!(await db.memoryCategories()).contains(category)) {
        return {
          'result': {
            'ok': false,
            'error': '请选择现有类别或先调用 create_memory_category',
            'categories': await db.memoryCategories(),
          },
        };
      }
      if (content.isEmpty) {
        return {
          'result': {'ok': false, 'error': '缺少记忆内容'},
        };
      }
      if (type == 'long') content = _cleanLongMemoryText(content);
      content = _stripLooseWo(content).trim();
      if (content.isEmpty) {
        return {
          'result': {'ok': false, 'error': '记忆内容无效'},
        };
      }
      try {
        final memoryId = args['memory_id']?.toString().trim() ?? '';
        Map<String, dynamic>? previous;
        if (memoryId.isNotEmpty) {
          final rows = await db.queryMemories(botId);
          for (final row in rows) {
            if (row['id'] == memoryId && row['category'] == category) {
              previous = row;
              break;
            }
          }
          if (previous == null) {
            return {
              'result': {'ok': false, 'error': '更新目标不存在或类别不一致，禁止跨类别覆盖'},
            };
          }
        }
        await db.upsertMemoryItem(
          botId: botId,
          id: memoryId.isEmpty ? null : memoryId,
          title: previous?['title']?.toString() ?? '',
          importance: (args['importance'] as num?)?.toInt(),
          keys: args['keys'] is List
              ? (args['keys'] as List).whereType<String>().toList()
              : null,
          expiresAt: (previous?['expires_at'] as num?)?.toInt(),
          type: previous?['type']?.toString() ?? type,
          content: content,
          category: category,
        );
        AppLogService.instance.add(
          'MEMORY',
          '机器人通过 save_memory 工具写入$type 记忆：${content.length} 字',
        );
        return {
          'result': {'ok': true, 'message': '记忆已写入本地数据库。'},
        };
      } catch (error) {
        AppLogService.instance.add('MEMORY', 'save_memory 写入失败：$error');
        return {
          'result': {'ok': false, 'error': '本地记忆写入失败：$error'},
        };
      }
    }
    if (name == 'query_diary') {
      final date = args['date']?.toString().trim() ?? '';
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
          DateTime.tryParse(date) == null) {
        return {
          'result': {'ok': false, 'error': 'date 必须是有效的 YYYY-MM-DD 日期'},
        };
      }
      final diary = await db.getDiary(botId, date);
      final displayDate =
          '${date.substring(0, 4)}年${date.substring(5, 7)}月${date.substring(8, 10)}日';
      await db.insertToolAudit(
        source: 'native',
        toolName: name,
        inputSummary: _redactToolInput({'date': date}),
        status: 'success',
        durationMs: 0,
      );
      if (diary == null) {
        return {
          'result': {
            'ok': true,
            'found': false,
            'message': '$displayDate没有可查询的日记。',
          },
        };
      }
      return {
        'result': {
          'ok': true,
          'found': true,
          'date': date,
          'content': diary['content']?.toString() ?? '',
        },
      };
    }
    if (name == 'search_memory') {
      final query = args['query']?.toString().trim() ?? '';
      final limit = (args['limit'] as int?) ?? 5;

      if (query.isEmpty) {
        return {
          'result': {'ok': false, 'error': '搜索关键词不能为空'},
        };
      }

      try {
        final startTime = DateTime.now().millisecondsSinceEpoch;
        final searchResult = await WorldBookService.instance
            .searchMemoryForTool(
              botId: botId,
              query: query,
              limit: limit.clamp(1, 10),
            );
        final durationMs = DateTime.now().millisecondsSinceEpoch - startTime;

        await db.insertToolAudit(
          source: 'native',
          toolName: name,
          inputSummary: _redactToolInput({'query': query, 'limit': limit}),
          status: searchResult['success'] == true ? 'success' : 'error',
          durationMs: durationMs,
        );

        AppLogService.instance.add(
          'MEMORY',
          '机器人搜索记忆库：query="$query" limit=$limit found=${searchResult['count'] ?? 0}条 耗时${durationMs}ms',
        );

        return {'result': searchResult};
      } catch (error) {
        AppLogService.instance.add('MEMORY', 'search_memory 执行异常：$error');
        return {
          'result': {'ok': false, 'error': '搜索失败：$error'},
        };
      }
    }
    if (name == 'request_voice_reply') {
      if (parseVoiceMessageSpeech(args['speech']) == null) {
        return {
          'result': {'ok': false, 'error': '请填写 speech 情绪和演绎参数后重试。'},
        };
      }
      return {
        'result': {
          'ok': true,
          'speech': args['speech'],
          'message': '本轮最终文字回复将按指定情绪生成语音；参数不要写进正文。',
        },
      };
    }
    if (name == 'write_diary') {
      final entry = args['entry']?.toString().trim() ?? '';
      if (entry.isEmpty || containsInternalTaskLeak(entry)) {
        return {
          'result': {'ok': false, 'error': '缺少日记内容'},
        };
      }
      final now = DateTime.now();
      final dateKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await db.upsertDiary(botId: botId, dateKey: dateKey, content: entry);
      AppLogService.instance.add(
        'DIARY',
        '机器人通过 write_diary 工具写入独立日记：${entry.length} 字',
      );
      return {
        'result': {'ok': true, 'message': '日记已安全写入，不要在聊天中复述日记正文。'},
      };
    }
    if (name == 'web_search') {
      final query = args['query']?.toString().trim() ?? '';
      if (query.isEmpty)
        return {
          'result': {'ok': false, 'error': '缺少 query'},
        };
      final rows = await _searchIfAuthorized(db, query, force: true);
      return {
        'sources': rows,
        'result': {
          'ok': rows.isNotEmpty,
          'results': rows,
          'message': rows.isEmpty ? '没有可用搜索结果。' : '搜索完成，请仅依据结果回答并引用来源。',
        },
      };
    }
    if (name == 'edit_user_image') {
      try {
        final selection = resolveUserImageEdit(
          args,
          currentImages: currentImages,
          historyImages: inspectableImages,
        );
        if (!await File(selection.path).exists()) {
          return {
            'result': {
              'ok': false,
              'error':
                  '所选 ${selection.source} 图片#${selection.imageNumber} 文件不存在或已失效，图片未修改，请让用户重新发送。',
            },
          };
        }
        final path = await _generateImageIfAuthorized(
          db: db,
          botId: botId,
          prompt: selection.prompt,
          force: true,
          userImageEdit: selection,
        );
        return {
          'result': {
            'ok': path != null,
            'source': selection.source,
            'image_number': selection.imageNumber,
            'mode': 'temporary_image_edit',
            if (path != null) 'image_path': path,
            'message': path == null
                ? '原图修改失败：请检查生图开关、模型配置及提供商图生图支持；图片未发送，禁止声称已修改，不得退回文生图冒充结果。'
                : '原图修改成功，将作为聊天图片发送。临时参考仅用于本次请求，永久参考图未变更。',
          },
        };
      } on FormatException catch (error) {
        return {
          'result': {'ok': false, 'error': error.message},
        };
      }
    }
    if (name == 'generate_image') {
      var prompt = args['prompt']?.toString().trim() ?? '';
      if (prompt.isEmpty) {
        return {
          'result': {'ok': false, 'error': '生图参数 prompt 不能为空，图片未生成，禁止声称已发送。'},
        };
      }
      final hasPortraitReference =
          (await db.getKV('bot_image_reference_$botId') ?? '')
              .trim()
              .isNotEmpty;
      late bool usePortraitReference;
      try {
        usePortraitReference = resolvePortraitReference(
          hasPortraitReference: hasPortraitReference,
          selection: args['use_portrait_reference'],
        );
      } on FormatException catch (error) {
        return {
          'result': {
            'ok': false,
            'error': error.message,
            'message': '图片未生成，请修正参数后重新调用。',
          },
        };
      }
      if (usePortraitReference) {
        final life = await LifeScheduleService.instance.ensureToday(botId);
        final outfit = life?['outfit']?.toString().trim() ?? '';
        if (outfit.isNotEmpty) {
          prompt =
              '$prompt。角色当前的日常穿搭参考为：$outfit。请严格按画面场景、活动、姿势和镜头范围选择其中合理且可见的部分；室内休息、床上、睡前或被遮挡时不要强行写完整穿搭、鞋或白天正装。';
        }
      } else if (hasPortraitReference) {
        prompt = '$prompt。本次画面不包含人物、人像、手部或身体局部，不添加人物元素。';
      }
      final path = prompt.isEmpty
          ? null
          : await _generateImageIfAuthorized(
              db: db,
              botId: botId,
              prompt: prompt,
              force: true,
              usePortraitReference: usePortraitReference,
            );
      return {
        'result': {
          'ok': path != null,
          'image_path': path,
          'use_portrait_reference': usePortraitReference,
          'mode': usePortraitReference ? 'image_edit' : 'text_to_image',
          'message': path == null
              ? '图片生成失败或未配置生图模型，图片未发送，必须如实说明失败，禁止声称已发送。'
              : '图片已生成并将作为聊天图片发送。',
        },
      };
    }
    if (name == 'initiate_voice_call') {
      try {
        final now = DateTime.now();
        final callId = '${now.millisecondsSinceEpoch}_$botId';

        final cardMessage = <String, dynamic>{
          'id': 'card_$callId',
          'bot_id': botId,
          'role': 'assistant',
          'content': '[语音通话，等待接听]',
          'type': 'voice_call_card',
          'call_id': callId,
          'call_status': 'ringing',
          'call_duration': 0,
          'duration': 0,
          'timestamp': now.millisecondsSinceEpoch,
        };
        // Ring only after both the detail and its card commit successfully.
        await db.insertVoiceCallRecord(
          callId: callId,
          botId: botId,
          initiator: 'assistant',
          status: 'ringing',
          transcript: '',
          summary: '',
          startTime: now,
          endTime: now,
          chatMessage: cardMessage,
        );

        // 延迟响铃：等待工具执行完毕、机器人回复完成后再弹出来电提示
        // 这样用户看到的顺序是：先看到机器人说"给你打电话"，再弹出接听/拒接按钮
        Future.delayed(const Duration(milliseconds: 1500), () async {
          final record = await db.getVoiceCallRecord(callId);
          if (record?['status'] != 'ringing') return;
          VoiceCallStateService.instance.startRinging(
            callId,
            botId,
            isIncoming: true,
            startedAt: now,
          );

          // 发送通知
          await MessageDeliveryService.instance.sendNotification(
            title: (await db.getBotData(botId))?['name']?.toString() ?? '机器人',
            body: '给你发起了语音通话',
            payload: {'type': 'voice_call', 'bot_id': botId, 'call_id': callId},
          );
        }).catchError((Object error) {
          print('Incoming call notification failed: $error');
        });

        AppLogService.instance.add('VOICE_CALL', '机器人发起语音通话：$callId（延迟响铃）');

        return {
          'result': {
            'ok': true,
            'message': '语音通话已发起，等待用户接听。不要在聊天中说"已发起通话"，用户会收到通知。',
          },
        };
      } catch (error) {
        AppLogService.instance.add('VOICE_CALL', '发起通话失败：$error');
        return {
          'result': {'ok': false, 'error': '发起通话失败：$error'},
        };
      }
    }
    if (name == 'create_future_task') {
      final title = args['title']?.toString().trim() ?? '';
      final prompt = args['prompt']?.toString().trim() ?? title;
      final rawRunAt = args['run_at']?.toString().trim() ?? '';
      final parsed = DateTime.tryParse(rawRunAt.replaceFirst(' ', 'T'));
      if (title.isEmpty || parsed == null) {
        return {
          'result': {
            'ok': false,
            'error': '缺少 title 或 run_at 格式不正确，应为 YYYY-MM-DD HH:mm',
          },
        };
      }
      final runAt = parsed.millisecondsSinceEpoch;
      if (runAt <= DateTime.now().millisecondsSinceEpoch) {
        return {
          'result': {'ok': false, 'error': '未来任务必须设置在当前时间之后'},
        };
      }
      final frequency = args['frequency']?.toString() == 'daily'
          ? 'daily'
          : 'once';
      final existingTasks = await db.querySchedules(botId);
      final normalizedTitle = title
          .replaceAll(RegExp(r'\s+'), '')
          .toLowerCase();
      final duplicate = existingTasks.any((task) {
        final oldTitle = (task['title']?.toString() ?? '')
            .replaceAll(RegExp(r'\s+'), '')
            .toLowerCase();
        final oldRunAt = (task['run_at'] as num?)?.toInt() ?? 0;
        return oldTitle == normalizedTitle &&
            oldRunAt == runAt &&
            task['status']?.toString() != 'done';
      });
      if (duplicate)
        return {
          'result': {
            'ok': true,
            'duplicate': true,
            'message': '相同未来任务已存在，未重复创建。',
          },
        };
      final id = 'future_${botId}_${runAt}_${title.hashCode.abs()}';
      final task = {
        'id': id,
        'bot_id': botId,
        'title': title,
        'note': prompt,
        'time': runAt,
        'is_done': 0,
        'frequency': frequency,
        'prompt': prompt,
        'run_at': runAt,
        'status': 'pending',
      };
      await db.insertFutureTask(task);
      await FutureTaskScheduler.schedule(task);
      return {
        'result': {'ok': true, 'id': id, 'message': '未来任务已创建：$title'},
      };
    }
    if (name == 'update_life_state') {
      final updated = await LifeScheduleService.instance.updateFromTool(
        botId,
        args,
      );
      return {
        'result': {
          'ok': updated != null,
          'message': updated == null
              ? '未修改：日程不存在、参数无效，或试图改动刚性事项。'
              : '今日生活状态已更新。',
        },
      };
    }
    return {
      'result': {'ok': false, 'error': '未知工具：$name'},
    };
  }

  Future<String> _buildToolContext(
    DBManager db, {
    required String botId,
    required RequestPromptFeatures features,
    List<String> stickerEmotions = const [],
  }) => buildRequestToolContext(
    readSetting: db.getKV,
    normalizeSearchProvider: _normalizeSearchProvider,
    botId: botId,
    features: features,
    stickerEmotions: stickerEmotions,
  );

  String _sharedPostHistoryKey(Map<String, dynamic> msg) {
    final id = msg['id']?.toString() ?? '';
    if (id.isNotEmpty) return id;
    return '${msg['timestamp']}_${msg['content']}';
  }

  String? _modelContextForHistoryMessage(
    Map<String, dynamic> msg, {
    required Map<String, int> imageNumberByPath,
    required Map<String, String> sharedPostContexts,
  }) {
    final type = msg['type']?.toString() ?? 'text';
    final content = msg['content']?.toString() ?? '';
    final role = msg['role']?.toString() ?? 'user';
    if (type == 'call_summary') return null;
    if (type == 'image') {
      final path = msg['file_path']?.toString() ?? '';
      final number = imageNumberByPath[path];
      if (number == null) return content.trim().isEmpty ? null : content;
      return formatImagePlaceholder(number, caption: content);
    }
    if (type == 'sticker') {
      final emotion = content.trim();
      return stickerModelContext(role: role, type: emotion);
    }
    if (type == 'emoji') {
      final label = content.trim();
      return label.isEmpty ? '[表情]' : '[表情：$label]';
    }
    if (type == 'shared_post') {
      return sharedPostContexts[_sharedPostHistoryKey(msg)] ??
          sharedPostDeletedModelCopy;
    }
    return content;
  }

  Future<String> _sharedPostModelContextForMessage(
    DBManager db,
    Map<String, dynamic> msg,
  ) async {
    Map<String, dynamic>? payload;
    try {
      final raw = jsonDecode(msg['content']?.toString() ?? '');
      if (raw is Map) payload = Map<String, dynamic>.from(raw);
    } catch (_) {}
    final postId =
        payload?['post_id']?.toString().trim() ??
        payload?['id']?.toString().trim() ??
        '';
    if (postId.isNotEmpty) {
      final post = await db.getPostById(postId);
      if (post == null) return sharedPostDeletedModelCopy;
      return sharedPostModelContext(
        deleted: false,
        author:
            post['author_id']?.toString() ??
            payload?['author']?.toString() ??
            '',
        content:
            post['content']?.toString() ??
            payload?['content']?.toString() ??
            '',
        time:
            payload?['timestamp']?.toString() ??
            post['timestamp']?.toString() ??
            '',
        hasImage:
            (post['image_path']?.toString() ??
                    payload?['image_path']?.toString() ??
                    '')
                .isNotEmpty,
      );
    }
    final author = payload?['author']?.toString() ?? '';
    final content = payload?['content']?.toString() ?? '';
    if (author.isEmpty && content.isEmpty) return sharedPostDeletedModelCopy;
    return sharedPostModelContext(
      deleted: false,
      author: author,
      content: content,
      time: payload?['timestamp']?.toString() ?? '',
      hasImage: (payload?['image_path']?.toString() ?? '').isNotEmpty,
    );
  }

  Future<String> _inspectImageForBot({
    required String botId,
    required String imagePath,
    required int imageNumber,
  }) async {
    const primaryVisionModel = '__use_primary_vision__';
    final prefs = await SharedPreferences.getInstance();
    final visionId = (prefs.getString('vision_model_$botId') ?? '').trim();
    final userText = '请转述 [图片#$imageNumber]。';
    if (visionId == primaryVisionModel) {
      final bots = await DBManager().getAllBots();
      final bot = bots.firstWhere(
        (item) => item['id'] == botId,
        orElse: () => {},
      );
      final providerId = bot['chat_model']?.toString().trim() ?? '';
      final provider = providerId.isEmpty
          ? null
          : await DBManager().getChatProviderById(providerId);
      if (provider == null) {
        return MediaPreprocessor().imageFallbackText(imagePath);
      }
      return _describeImage(
        provider: provider,
        imagePath: imagePath,
        userText: userText,
      );
    }
    final provider = visionId.isEmpty
        ? null
        : await DBManager().getChatProviderById(visionId);
    if (provider == null) {
      return MediaPreprocessor().imageFallbackText(imagePath);
    }
    return _describeImage(
      provider: provider,
      imagePath: imagePath,
      userText: userText,
    );
  }

  // 构建核心防御护栏与游戏机制注入
  Future<String?> generateTTS(
    String text,
    String providerId, {
    AICancellationToken? cancellationToken,
    CallSpeechStyle? speechStyle,
  }) => _generateTTS(
    text,
    providerId,
    cancellationToken: cancellationToken,
    speechStyle: speechStyle,
  );
  Future<Map<String, dynamic>> testProviderCapabilities(
    String baseUrl,
    String apiKey,
    String model,
  ) async {
    final root = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final modelName = model.split(',').first.trim();
    if (root.isEmpty || apiKey.trim().isEmpty || modelName.isEmpty) {
      return {'capabilities': <String>[], 'error': '请填写 API 地址、Key 和模型名'};
    }
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };
    bool success(http.Response response) =>
        response.statusCode >= 200 && response.statusCode < 300;

    // 每个探测返回 (是否成功, 耗时毫秒)；失败也返回耗时便于诊断。
    Future<Map<String, dynamic>> probe(
      String name,
      Future<bool> Function() run,
    ) async {
      final t0 = DateTime.now();
      var ok = false;
      var latency = 0;
      try {
        ok = await run();
      } catch (_) {
        ok = false;
      }
      latency = DateTime.now().difference(t0).inMilliseconds;
      return {'name': name, 'ok': ok, 'latency': latency};
    }

    String lastError = '';
    Future<bool> postJson(String path, Map<String, dynamic> body) async {
      try {
        final response = await http
            .post(
              Uri.parse('$root$path'),
              headers: headers,
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 30));
        final responseText = utf8.decode(
          response.bodyBytes,
          allowMalformed: true,
        );
        if (!success(response) || response.bodyBytes.isEmpty) {
          final compact = responseText.replaceAll(RegExp(r'\s+'), ' ').trim();
          final summary = compact.length <= 240
              ? compact
              : compact.substring(0, 240);
          lastError = 'HTTP ${response.statusCode}: $summary';
          return false;
        }
        try {
          final decoded = jsonDecode(responseText);
          if (decoded is! Map || decoded['error'] != null) {
            lastError = decoded is Map
                ? (decoded['error']?.toString() ?? '响应格式异常')
                : '响应格式异常';
            return false;
          }
          if (path == '/chat/completions') {
            final content = _extractChatContent(decoded);
            // Some OpenAI-compatible gateways deliberately return an empty
            // probe completion (or only reasoning/tool metadata) while normal
            // conversations work. HTTP 2xx plus a valid choices envelope is a
            // usable connectivity result; keep the parsing note for diagnosis.
            final choices = decoded['choices'];
            final hasChoices = choices is List && choices.isNotEmpty;
            if (content.isEmpty && !hasChoices) {
              lastError = 'HTTP 200，但响应中没有 choices';
              return false;
            }
            if (content.isEmpty) {
              lastError = 'HTTP 200，服务已连通但测试响应未包含可见正文';
            }
            return true;
          }
          if (path == '/images/generations') {
            return decoded['data'] is List &&
                (decoded['data'] as List).isNotEmpty;
          }
          return true;
        } catch (error) {
          lastError = '响应解析失败：$error';
          return false;
        }
      } catch (error) {
        lastError = '请求异常：$error';
        return false;
      }
    }

    Future<bool> stt() async {
      try {
        // A minimal valid PCM WAV avoids treating a missing multipart file as a test.
        const wav = <int>[
          82,
          73,
          70,
          70,
          36,
          0,
          0,
          0,
          87,
          65,
          86,
          69,
          102,
          109,
          116,
          32,
          16,
          0,
          0,
          0,
          1,
          0,
          1,
          0,
          128,
          62,
          0,
          0,
          0,
          125,
          0,
          0,
          2,
          0,
          16,
          0,
          100,
          97,
          116,
          97,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ];
        final request =
            http.MultipartRequest(
                'POST',
                Uri.parse('$root/audio/transcriptions'),
              )
              ..headers['Authorization'] = 'Bearer $apiKey'
              ..fields['model'] = modelName
              ..files.add(
                http.MultipartFile.fromBytes(
                  'file',
                  wav,
                  filename: 'tidebot-test.wav',
                  contentType: null,
                ),
              );
        final response = await request.send().timeout(
          const Duration(seconds: 20),
        );
        return response.statusCode >= 200 && response.statusCode < 300;
      } catch (_) {
        return false;
      }
    }

    const onePixel =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

    // 并发探测文本、STT、识图、生图四项能力，任意一项成功即判定通过，
    // 并返回四项中「最快成功」的延迟（毫秒）。
    final probes = await Future.wait<Map<String, dynamic>>([
      probe(
        '文本',
        () => postJson('/chat/completions', {
          'model': modelName,
          'messages': [
            {'role': 'user', 'content': 'ping'},
          ],
          'max_tokens': 32,
        }),
      ),
      probe('STT', stt),
      probe(
        '识图',
        () => postJson('/chat/completions', {
          'model': modelName,
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Describe this image in one word.'},
                {
                  'type': 'image_url',
                  'image_url': {'url': onePixel},
                },
              ],
            },
          ],
          'max_tokens': 8,
        }),
      ),
      probe(
        '生图',
        () => postJson('/images/generations', {
          'model': modelName,
          'prompt': 'A single blue pixel.',
          'size': '256x256',
          'n': 1,
        }),
      ),
    ]);

    final capabilities = <String>[];
    final latencies = <String, int>{};
    int? fastest;
    String? fastestName;
    for (final p in probes) {
      final name = p['name'] as String;
      final ok = p['ok'] as bool;
      final latency = p['latency'] as int;
      latencies[name] = latency;
      if (ok) {
        capabilities.add(name);
        if (fastest == null || latency < fastest) {
          fastest = latency;
          fastestName = name;
        }
      }
    }

    final passed = capabilities.contains('文本');
    return {
      'capabilities': capabilities,
      'passed': passed,
      'latencies': latencies,
      'fastest_latency': fastest,
      'fastest_name': fastestName,
      // 基础聊天请求成功才算配置可用；其他能力是附加探测。
      if (!passed) 'error': lastError.isEmpty ? '聊天模型基础请求失败' : lastError,
    };
  }

  String _safetyContext(String userText) {
    final risky = RegExp(
      r'(色情|裸聊|成人视频|强奸|轮奸|未成年.{0,6}(性|裸|色情)|自杀|自残|割腕|炸弹|爆炸物|制毒|毒品|枪支|杀人|恐怖袭击|极端组织|诈骗|洗钱|盗号|破解|木马|勒索|人肉|仇恨|种族灭绝)',
      caseSensitive: false,
    ).hasMatch(userText);
    return risky
        ? '\n【安全处理】用户消息可能涉及违法、危险、露骨、仇恨、欺诈、隐私或自伤内容。不要生成、补全、鼓励或提供可执行细节；保持你的人设，以温和、不评判的方式拒绝或转移到安全话题。若涉及即时自伤或他伤风险，优先鼓励联系当地紧急服务、可信赖的人或专业支持。'
        : '\n【安全规则】不得生成违法、危险、露骨色情、剥削未成年人、仇恨骚扰、欺诈、隐私侵害或自伤他伤的可执行内容；遇到此类请求应保持人设并温和转移到安全话题。';
  }

  Future<String> _lifeStateContext(
    String botId, {
    bool instructions = true,
  }) async {
    if (!await LifeScheduleService.instance.enabled()) return '';
    final row = await LifeScheduleService.instance.ensureToday(botId);
    if (row == null) return '';
    if (!instructions) return '\n【生活计划，仅作背景，不等于已完成】${jsonEncode(row)}';
    return '\n${LifeScheduleService.instance.compactContext(row)}';
  }

  /// 解析模型通过内部协议 [记忆:类型|内容]（可多条）主动要求记住的信息，
  /// 以第一人称、无标题、逐条写入 memories 表。
  /// - [记忆:长期|...] -> type=long（用户画像、机器人身份、自我认识等稳定信息）
  /// - [记忆:...]      -> type=short（近期日记式事件）
  ///
  /// 注：当前世界书基于标准记忆，模型直接写入世界书功能暂未使用，保留为备用接口。
  // ignore: unused_element
  Future<void> _persistModelMemories(
    DBManager db,
    String botName,
    String botId,
    String rawReply,
  ) async {
    try {
      final regex = RegExp(r'\[记忆\s*[:：]\s*([^\]]+)\]');
      final matches = regex.allMatches(rawReply).toList();
      if (matches.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      var idx = 0;
      for (final m in matches) {
        var content = m.group(1)?.trim() ?? '';
        if (content.isEmpty) continue;
        var type = 'short';
        // 支持 [记忆:长期|内容] 显式分类；其余事件/感受按第一人称日记写为短期。
        final longPrefix = RegExp(r'^长期\s*[|｜]\s*');
        if (longPrefix.hasMatch(content)) {
          type = 'long';
          content = content.replaceFirst(longPrefix, '').trim();
        }
        content = content
            .replaceFirst(
              RegExp(r'^(?:内容|短期|short)\s*[|｜]\s*', caseSensitive: false),
              '',
            )
            .trim();
        if (content.isEmpty) continue;
        // 长期记忆绝对不能出现任何时间相关词汇（用户硬性要求）。“我记得”
        // 前缀也绝不写入（统一走 _cleanLongMemoryText）。
        if (type == 'long') {
          content = _cleanLongMemoryText(content);
        }
        // 记忆采用第一人称，但不强制以“我”开头：例如“京太郎每天睡够8小时”
        // 就是正确写法。若模型写出了“我京太郎...”，去掉误加的“我”，避免把
        // 第三人称称呼误当成机器人自己的名字。绝不添加“我记得”前缀。
        content = _stripLooseWo(content);
        content = content.trim();
        if (content.isEmpty) continue;
        await db.upsertMemoryItem(
          botId: botId,
          type: type,
          title: '',
          content: content,
          timestamp: now + idx * 1000,
        );
        idx++;
      }
    } catch (e) {
      print('[memory] persist requested memory failed: $e');
    }
  }

  /// 长期记忆清洗：去掉所有时间相关词，并把“我记得/我记起”开头替换为其后正文，
  /// 保证长期记忆为稳定的第一人称，且绝不残留时间词。写入与注入路径共用，
  /// 兜底处理历史遗留的未清洗长期记忆，确保展示给模型的一定符合规则。
  String _cleanLongMemoryText(String content) {
    var s = content.trim();
    s = s.replaceAll(RegExp(r'^(我)?\s*记得\s*[，,:：]?\s*'), '');
    s = s.replaceAll(
      RegExp(
        r'今天上午|今天中午|今天下午|今天早上|今天夜里|今天|昨天下午|昨天早上|昨天夜里|昨天|明天|前天|后天|昨晚|今晚|今早|近日|最近|上周|本周|下周|刚才|刚刚|现在|此刻|之前|以前|几小时前|几天前|几个星期前|一个月前|凌晨|早上|中午|下午|晚上',
      ),
      '',
    );
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    // 不强制以“我”开头。若模型写出了“我京太郎...”，去掉误加的“我”。
    s = _stripLooseWo(s);
    return s.trim();
  }

  /// 去掉记忆正文前被模型误加的“我”，避免“我京太郎…”。只会在“我”之后
  /// 直接跟着一个疑似人名/称呼（非常见第一人称搭配词）时移除；而“我今天
  /// 很高兴”“我觉得…”等正确的第一人称写法会被保留。
  String _stripLooseWo(String s) {
    // 常见第一人称后续词，遇到这些就说明“我”是真实主语，不能删除。
    const keepList = [
      '今天',
      '今天上午',
      '今天中午',
      '今天下午',
      '今天早上',
      '今天夜里',
      '昨天',
      '明天',
      '前天',
      '后天',
      '昨晚',
      '记得',
      '觉得',
      '想',
      '会',
      '要',
      '是',
      '爱',
      '喜欢',
      '希望',
      '知道',
      '认为',
      '正在',
      '已经',
      '刚',
      '最近',
      '现在',
      '能',
      '可以',
      '应该',
      '很',
      '真的',
      '有点',
      '有些',
      '其实',
      '也',
      '都',
      '还',
      '总',
      '常',
      '曾经',
      '终于',
      '忽然',
      '突然',
      '打算',
      '准备',
      '决定',
      '答应',
      '保证',
      '没有',
      '不是',
      '不会',
      '不想',
      '说不出',
      '很好',
      '很累',
      '很开心',
    ];
    final keep = keepList.map((w) => RegExp.escape(w)).join('|');
    final re = RegExp('^我(?=[\\u4e00-\\u9fa5]{2})(?!$keep)');
    return s.replaceAll(re, '');
  }
}

// 辅助函数：格式化视频时长
String _formatVideoDuration(int seconds) {
  if (seconds < 60) {
    return '$seconds秒';
  } else if (seconds < 3600) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return remainingSeconds > 0 ? '$minutes分$remainingSeconds秒' : '$minutes分钟';
  } else {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSeconds = seconds % 60;
    if (remainingSeconds > 0) {
      return '$hours小时$minutes分$remainingSeconds秒';
    } else if (minutes > 0) {
      return '$hours小时$minutes分钟';
    } else {
      return '$hours小时';
    }
  }
}
