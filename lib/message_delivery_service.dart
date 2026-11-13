import 'dart:convert';

import 'app_state.dart';
import 'package:flutter/foundation.dart';
import 'chat_event_bus.dart';
import 'db.dart';
import 'ops.dart';

/// Single entry point for messages that become visible outside the caller.
class MessageDeliveryService {
  MessageDeliveryService._();
  static final MessageDeliveryService instance = MessageDeliveryService._();

  final DBManager _db = DBManager();
  final _activeReplies = <String, int>{};
  final _releaseRequested = <String>{};
  final _deferredReplies = <String>{};
  final _pluginQueues = <String, Map<String, Map<String, dynamic>>>{};

  Map<String, dynamic>? pendingPluginMessage(String id, String botId) {
    final row = _pluginQueues[botId]?[id];
    return row?['bot_id'] == botId ? row : null;
  }

  Future<void> insertPluginMessage(Map<String, dynamic> message) async {
    final queue = _pluginQueues[message['bot_id']];
    if (queue == null) {
      await insert(message);
      return;
    }
    queue.putIfAbsent(message['id'] as String, () => Map.of(message));
    await _db.setKV(
      'plugin_reply_queue_${message['bot_id']}',
      jsonEncode(queue),
    );
  }

  /// Keep tool receipts usable inside the turn, then publish after its reply.
  Future<T> afterReply<T>(
    String botId,
    Future<T> Function() work, {
    bool deferDelivery = false,
  }) async {
    _activeReplies[botId] = (_activeReplies[botId] ?? 0) + 1;
    if (deferDelivery) _deferredReplies.add(botId);
    final queue = _pluginQueues.putIfAbsent(botId, () => {});
    try {
      final saved = await _db.getKV('plugin_reply_queue_$botId');
      if (saved != null && saved.isNotEmpty) {
        final recovered = jsonDecode(saved) as Map;
        for (final entry in recovered.entries) {
          queue[entry.key as String] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
      return await work();
    } finally {
      final remaining = (_activeReplies[botId] ?? 1) - 1;
      if (remaining > 0) {
        _activeReplies[botId] = remaining;
      } else {
        _activeReplies.remove(botId);
        if (!_deferredReplies.contains(botId) ||
            _releaseRequested.contains(botId)) {
          await flushPluginMessages(botId);
        }
      }
    }
  }

  Future<void> flushPluginMessages(String botId) async {
    _releaseRequested.add(botId);
    if ((_activeReplies[botId] ?? 0) > 0) return;
    _deferredReplies.remove(botId);
    _releaseRequested.remove(botId);
    final queue = _pluginQueues[botId];
    if (queue == null) return;
    try {
      if (queue.isNotEmpty) {
        final database = await _db.database;
        final latest = await database.rawQuery(
          'SELECT MAX(timestamp) AS latest FROM chat_history WHERE bot_id = ?',
          [botId],
        );
        var timestamp = DateTime.now().millisecondsSinceEpoch;
        final last = (latest.first['latest'] as num?)?.toInt() ?? 0;
        if (timestamp <= last) timestamp = last + 1;
        for (final row in queue.values) {
          final existing = await database.query(
            'chat_history',
            columns: ['id'],
            where: 'id = ? AND bot_id = ?',
            whereArgs: [row['id'], botId],
            limit: 1,
          );
          if (existing.isNotEmpty) continue;
          row['timestamp'] = timestamp++;
          await insert(row);
        }
        await _db.setKV('plugin_reply_queue_$botId', '{}');
      }
      _pluginQueues.remove(botId);
    } catch (error) {
      debugPrint('Plugin delivery deferred for retry: $error');
    }
  }

  Future<void> insert(
    Map<String, dynamic> message, {
    bool notify = true,
  }) async {
    message = await _db.insertChatMessage(message, publishEvent: false);
    final botId = message['bot_id']?.toString();
    final messageId = message['id']?.toString();
    ChatEventBus.instance.publish(
      ChatEvent(
        type: ChatEventType.inserted,
        botId: botId,
        messageId: messageId,
        message: Map<String, dynamic>.from(message),
      ),
    );

    if (notify &&
        message['role'] == 'assistant' &&
        botId != null &&
        await _db.getKV('unread_notifications') != 'false' &&
        !AppState.isViewingChat(botId)) {
      final botName = (await _db.getBotData(botId))?['name']?.toString().trim();
      final title = botName != null && botName.isNotEmpty ? botName : '机器人';
      await OpsManager().showSystemNotification(
        id: messageId.hashCode,
        title: title,
        body: message['content']?.toString().trim().isEmpty == false
            ? message['content'].toString()
            : '$title 有一条新消息',
        botId: botId,
        messageId: messageId,
      );
    }
  }

  Future<void> markRead(String botId) async {
    await _db.markBotRead(botId);
  }

  Future<void> sendNotification({
    required String title,
    required String body,
    Map<String, dynamic>? payload,
  }) async {
    if (await _db.getKV('unread_notifications') == 'false') return;
    if (AppState.isViewingChat(payload?['bot_id']?.toString())) return;

    await OpsManager().showSystemNotification(
      id: DateTime.now().millisecondsSinceEpoch.hashCode,
      title: title,
      body: body,
      botId: payload?['bot_id']?.toString(),
      messageId: payload?['call_id']?.toString(),
    );
  }
}
