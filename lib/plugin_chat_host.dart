import 'dart:io';
import 'package:http/http.dart' as http;
import 'db.dart';
import 'message_delivery_service.dart';
import 'plugin_chat_session.dart';
import 'plugin_coordinator.dart';
import 'package:path_provider/path_provider.dart';

class AppPluginChatHost implements PluginChatHost {
  const AppPluginChatHost();
  @override
  Future<bool> hasBot(String botId) async =>
      await DBManager().getBotData(botId) != null;
  @override
  Future<Map<String, dynamic>?> findMessage(String id, String botId) async {
    final db = await DBManager().database;
    final rows = await db.query(
      'chat_history',
      where: 'id = ? AND bot_id = ?',
      whereArgs: [id, botId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<void> insert(Map<String, dynamic> message) =>
      MessageDeliveryService.instance.insert(message);
  @override
  Future<Directory> documents() => getApplicationDocumentsDirectory();
  @override
  Future<Directory> temporary() => getTemporaryDirectory();
  @override
  Future<T> locked<T>(String key, Future<T> Function() work) =>
      PluginCoordinator.locked(key, work);
  @override
  http.Client createClient() => http.Client();
}
