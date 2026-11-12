import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Production write-ahead recovery, independent of Flutter and database plugins.
class PluginInstallJournal {
  PluginInstallJournal({
    required this.queryRows,
    required this.deleteRow,
    required this.deleteData,
    required this.invalidate,
  });
  final Future<List<Map<String, dynamic>>> Function() queryRows;
  final Future<void> Function(String) deleteRow;
  final Future<void> Function(String) deleteData;
  final Future<void> Function(String) invalidate;
  void _checkId(String id) {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{2,63}$').hasMatch(id)) {
      throw const FormatException('插件恢复 ID 无效');
    }
  }

  Future<void> write(Directory root, Map<String, dynamic> value) async {
    final pending = File(p.join(root.path, '.transaction.pending'));
    final journal = File(p.join(root.path, '.transaction.json'));
    if (await pending.exists() || await journal.exists()) {
      throw StateError('插件事务日志尚未恢复');
    }
    await pending.writeAsString(jsonEncode(value), flush: true);
    await pending.rename(journal.path);
  }

  /// The DB transaction marker decides whether interrupted installation commits
  /// or rolls back. Deletion is idempotent and always rolls forward.
  Future<void> recover(Directory root) async {
    final journal = File(p.join(root.path, '.transaction.json'));
    final pending = File(p.join(root.path, '.transaction.pending'));
    // Directory mutations start only after the pending log has been renamed.
    if (await pending.exists()) await pending.delete();
    if (!await journal.exists()) return;
    final record = jsonDecode(await journal.readAsString()) as Map;
    final id = record['id'] as String;
    _checkId(id);
    Directory child(String key) {
      final name = record[key] as String;
      if (p.basename(name) != name || !name.startsWith('$id.')) {
        throw const FormatException('插件恢复记录路径无效');
      }
      return Directory(p.join(root.path, name));
    }

    final target = Directory(p.join(root.path, id));
    if (record['op'] == 'delete') {
      await invalidate(id);
      await deleteData(id);
      if (await target.exists()) await target.delete(recursive: true);
      await deleteRow(id);
    } else if (record['op'] == 'install') {
      final staging = child('staging');
      final backup = child('backup');
      final rows = await queryRows();
      final current = rows.where((row) => row['id'] == id).firstOrNull;
      final committed =
          current != null &&
          current['updated_at'] == record['marker'] &&
          current['manifest_json'] == record['manifest'];
      if (committed) {
        if (!await target.exists()) {
          throw StateError('已提交插件目录丢失，保留恢复记录：$id');
        }
        if (await backup.exists()) await backup.delete(recursive: true);
      } else if (await backup.exists()) {
        if (await target.exists()) await target.delete(recursive: true);
        await backup.rename(target.path);
      } else if (record['existed'] != true && await target.exists()) {
        await target.delete(recursive: true);
      }
      if (await staging.exists()) await staging.delete(recursive: true);
    } else {
      throw const FormatException('插件恢复操作无效');
    }
    await journal.delete();
  }
}
