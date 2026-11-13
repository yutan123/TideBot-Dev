import 'user_profile_changes.dart';
import 'proactive_request_gate.dart';
import 'tool_bot_scope.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'native_background_coordinator.dart';
import 'media_storage_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'data_transfer.dart';
import 'transfer_media.dart';
import 'json_records.dart';
import 'chat_event_bus.dart';
import 'voice_call_schema.dart';

/// 标准化的 token 估算（当 API 未返回 usage 时的近似值，而非真实记账）。
///
/// 采用与 cl100k 接近的中英文分层规则：
/// - CJK（中文/日文/韩文等）约占 0.6 token/字符（cl100k 中中文约 1.7 字符/token）；
/// - 其余（英文、数字、常用符号）约占 0.25 token/字符（约 4 字符/token）。
/// 空串返回 0，永远返回 >= 0 的整数。仅供估算，不做精确记账。
int estimateTokens(String text) {
  if (text.isEmpty) return 0;
  var cjk = 0;
  var rest = 0;
  for (final rune in text.runes) {
    if ((rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意文字
        (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
        (rune >= 0x3040 && rune <= 0x30FF) || // 日文假名
        (rune >= 0xAC00 && rune <= 0xD7AF) || // 韩文音节
        (rune >= 0xF900 && rune <= 0xFAFF) || // CJK 兼容表意文字
        (rune >= 0x20000 && rune <= 0x2FA1F)) {
      // 扩展 B-F
      cjk++;
    } else {
      rest++;
    }
  }
  final cjkTokens = cjk / 1.7;
  final restTokens = rest / 4.0;
  return (cjkTokens + restTokens).ceil();
}

class DBManager {
  static final DBManager _instance = DBManager._internal();
  factory DBManager() => _instance;
  DBManager._internal();

  Database? _db;
  Future<Database>? _openingDatabase;
  Future<void>? _closingDatabase;

  Future<Database> get database async {
    final closing = _closingDatabase;
    if (closing != null) await closing;
    final current = _db;
    if (current != null) return current;

    // Concurrent startup callers must await one opening/upgrade operation.
    // Without this guard, each caller can try to open and migrate the same
    // SQLite file, which may leave a native database lock during launch.
    final opening = _openingDatabase;
    if (opening != null) return opening;

    final future = _initDB();
    _openingDatabase = future;
    try {
      final database = await future;
      _db = database;
      return database;
    } finally {
      _openingDatabase = null;
    }
  }

  Future<Map<String, Object>> databaseDiagnostics() async {
    final path = p.join(await getDatabasesPath(), 'tidebot.db');
    final file = File(path);
    final existedBeforeOpen = await file.exists();
    final bytesBeforeOpen = existedBeforeOpen ? await file.length() : 0;
    final db = await database;
    final tables = <String, int>{};
    for (final table in const [
      'bots',
      'chat_history',
      'posts',
      'post_comments',
      'feed_events',
      'call_sessions',
    ]) {
      try {
        final rows = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
        tables[table] = (rows.first['count'] as num?)?.toInt() ?? 0;
      } catch (_) {
        tables[table] = -1;
      }
    }
    final version = await db.rawQuery('PRAGMA user_version');
    return {
      'path': path,
      'existedBeforeOpen': existedBeforeOpen,
      'bytesBeforeOpen': bytesBeforeOpen,
      'bytesAfterOpen': await file.length(),
      'userVersion': (version.first.values.first as num?)?.toInt() ?? 0,
      'tables': tables,
    };
  }

  Future<void> close() {
    return _closingDatabase ??= _closeDatabase().whenComplete(() {
      _closingDatabase = null;
    });
  }

  Future<void> _closeDatabase() async {
    final opening = _openingDatabase;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {}
    }
    final current = _db;
    _db = null;
    if (current != null) await current.close();
  }

  Future<void> _execSql(DatabaseExecutor db, String sql) async {
    try {
      await db.execute(sql);
    } catch (error) {
      print('[db] schema sql skipped: $error');
    }
  }

  Future<Set<String>> _tableColumns(DatabaseExecutor db, String table) async {
    try {
      final info = await db.rawQuery('PRAGMA table_info($table)');
      return info
          .map((row) => row['name']?.toString() ?? '')
          .where((name) => name.isNotEmpty)
          .toSet();
    } catch (error) {
      print('[db] table_info $table failed: $error');
      return <String>{};
    }
  }

  Future<void> _ensureColumns(
    DatabaseExecutor db,
    String table,
    Map<String, String> columns,
  ) async {
    final existing = await _tableColumns(db, table);
    if (existing.isEmpty) return;
    for (final entry in columns.entries) {
      if (existing.contains(entry.key)) continue;
      await _execSql(
        db,
        'ALTER TABLE $table ADD COLUMN ${entry.key} ${entry.value}',
      );
    }
  }

  Future<void> _createRepairCoreTables(DatabaseExecutor db) async {
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS memories (
        id TEXT PRIMARY KEY, bot_id TEXT, title TEXT DEFAULT '', type TEXT,
        content TEXT, category TEXT DEFAULT '记忆', importance INTEGER DEFAULT 3,
        expires_at INTEGER, timestamp INTEGER, updated_at INTEGER,
        keys_json TEXT DEFAULT '[]', trigger_count INTEGER DEFAULT 0,
        last_triggered_at INTEGER, auto_created INTEGER DEFAULT 0,
        source_chat_id TEXT, is_deleted INTEGER DEFAULT 0,
        FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
      )
    ''');
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS schedule_tasks (
        id TEXT PRIMARY KEY, bot_id TEXT, title TEXT, note TEXT, time INTEGER,
        is_done INTEGER, frequency TEXT DEFAULT 'once', prompt TEXT DEFAULT '',
        run_at INTEGER, status TEXT DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT, retry_at INTEGER, locked_at INTEGER, idempotency_key TEXT,
        FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
      )
    ''');

    // 后台任务注册表
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS background_tasks (
        task_id TEXT PRIMARY KEY,
        task_type TEXT NOT NULL,
        bot_id TEXT,
        trigger_time INTEGER NOT NULL,
        repeating INTEGER DEFAULT 0,
        enabled INTEGER DEFAULT 1,
        config_json TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
      )
    ''');

    // 后台任务执行记录（幂等性保证）
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS background_task_executions (
        execution_id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        scheduled_time INTEGER NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER,
        status TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 1,
        result_json TEXT,
        error_message TEXT,
        UNIQUE(task_id, scheduled_time)
      )
    ''');

    // 后台消息表（Kotlin 写入，Flutter 读取显示）
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS background_messages (
        message_id TEXT PRIMARY KEY,
        bot_id TEXT NOT NULL,
        task_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        image_path TEXT,
        timestamp INTEGER NOT NULL,
        displayed INTEGER DEFAULT 0,
        synced_to_chat INTEGER DEFAULT 0,
        FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
      )
    ''');

    await _execSql(db, '''
      CREATE INDEX IF NOT EXISTS idx_background_messages_bot 
      ON background_messages(bot_id, displayed, timestamp DESC)
    ''');
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS post_comments (
        id TEXT PRIMARY KEY, post_id TEXT NOT NULL, author_id TEXT,
        content TEXT NOT NULL, parent_id TEXT, timestamp INTEGER,
        FOREIGN KEY (post_id) REFERENCES posts (id) ON DELETE CASCADE
      )
    ''');
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS feed_events (
        id TEXT PRIMARY KEY, post_id TEXT NOT NULL, actor_id TEXT NOT NULL,
        event_type TEXT NOT NULL, timestamp INTEGER NOT NULL,
        UNIQUE(post_id, actor_id, event_type),
        FOREIGN KEY (post_id) REFERENCES posts (id) ON DELETE CASCADE
      )
    ''');
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS stickers (
        id TEXT PRIMARY KEY, emotion TEXT NOT NULL, file_path TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS bot_diaries (
        id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, date_key TEXT NOT NULL,
        content TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE,
        UNIQUE(bot_id, date_key)
      )
    ''');

    await ensureVoiceCallSchema(db);
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS bot_life_schedules (
        id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, date_key TEXT NOT NULL,
        theme TEXT DEFAULT '', mood TEXT DEFAULT '', outfit_style TEXT DEFAULT '',
        outfit TEXT DEFAULT '', timeline_json TEXT DEFAULT '[]',
        generated_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        UNIQUE(bot_id, date_key),
        FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
      )
    ''');
    await _execSql(db, '''
      CREATE TABLE IF NOT EXISTS ai_usage_events (
        id TEXT PRIMARY KEY, bot_id TEXT, event_type TEXT NOT NULL,
        prompt_tokens INTEGER NOT NULL DEFAULT 0,
        completion_tokens INTEGER NOT NULL DEFAULT 0,
        total_tokens INTEGER NOT NULL DEFAULT 0,
        reply_count INTEGER NOT NULL DEFAULT 0, timestamp INTEGER NOT NULL
      )
    ''');
  }

  Future<bool> _shouldRepairSchema(Database db) async {
    try {
      final result = await db.rawQuery(
        "SELECT value FROM kv_store WHERE key = 'schema_repair_version'",
      );
      if (result.isEmpty) return true;
      final stored = int.tryParse(result.first['value']?.toString() ?? '') ?? 0;
      return stored < 36; // 36：修复旧库通话时间字段和卡片关联字段
    } catch (_) {
      return true; // kv_store 不存在时需要修复
    }
  }

  Future<void> _markSchemaRepaired(Database db) async {
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS kv_store (
          key TEXT PRIMARY KEY, value TEXT
        )
      ''');
      await db.insert('kv_store', {
        'key': 'schema_repair_version',
        'value': '36',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (error) {
      print('[db] mark schema repaired failed: $error');
    }
  }

  Future<bool> _repairExistingDatabase(Database db) async {
    try {
      await _execSql(db, '''
        CREATE TABLE IF NOT EXISTS bots (
          id TEXT PRIMARY KEY, name TEXT, desc TEXT, prompt TEXT,
          avatar TEXT, chat_model TEXT, stt_model TEXT, tts_model TEXT,
          video_model TEXT, max_tokens INTEGER, created_at INTEGER, daily_quote TEXT,
          last_msg_time INTEGER, is_pinned INTEGER DEFAULT 0,
          last_read_at INTEGER DEFAULT 0, is_disabled INTEGER DEFAULT 0
        )
      ''');
      await _execSql(db, '''
        CREATE TABLE IF NOT EXISTS chat_history (
          id TEXT PRIMARY KEY, bot_id TEXT, role TEXT, type TEXT,
          content TEXT, file_path TEXT, mood TEXT, duration INTEGER,
          error_log TEXT, error_code TEXT, error_message TEXT,
          retry_status TEXT NOT NULL DEFAULT 'none', reply_to_id TEXT,
          reply_group_id TEXT, sources_json TEXT, timestamp INTEGER,
          FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
        )
      ''');
      await _execSql(db, '''
        CREATE TABLE IF NOT EXISTS posts (
          id TEXT PRIMARY KEY, author_id TEXT, content TEXT, image_path TEXT,
          likes INTEGER DEFAULT 0, comments INTEGER DEFAULT 0,
          user_liked INTEGER DEFAULT 0, user_collected INTEGER DEFAULT 0,
          timestamp INTEGER
        )
      ''');
      await _createRepairCoreTables(db);
      await _createCallTables(db);
      await _createSkillTables(db);
      await _ensureColumns(db, 'skills', const {
        'built_in': 'INTEGER NOT NULL DEFAULT 0',
        'recommended': 'INTEGER NOT NULL DEFAULT 0',
      });
      await _ensureColumns(db, 'bots', const {
        'name': 'TEXT',
        'desc': 'TEXT',
        'prompt': 'TEXT',
        'avatar': 'TEXT',
        'chat_model': 'TEXT',
        'stt_model': 'TEXT',
        'tts_model': 'TEXT',
        'video_model': 'TEXT',
        'max_tokens': 'INTEGER',
        'created_at': 'INTEGER',
        'daily_quote': 'TEXT',
        'last_msg_time': 'INTEGER',
        'is_pinned': 'INTEGER DEFAULT 0',
        'last_read_at': 'INTEGER DEFAULT 0',
        'is_disabled': 'INTEGER DEFAULT 0',
      });
      await _ensureColumns(db, 'chat_history', const {
        'bot_id': 'TEXT',
        'role': 'TEXT',
        'type': 'TEXT',
        'content': 'TEXT',
        'file_path': 'TEXT',
        'mood': 'TEXT',
        'duration': 'INTEGER',
        'error_log': 'TEXT',
        'error_code': 'TEXT',
        'error_message': 'TEXT',
        'retry_status': "TEXT NOT NULL DEFAULT 'none'",
        'reply_to_id': 'TEXT',
        'reply_group_id': 'TEXT',
        'sources_json': 'TEXT',
        'timestamp': 'INTEGER',
        'inner_thought': 'TEXT',
        'call_id': 'TEXT',
        'call_status': 'TEXT',
        'call_duration': 'INTEGER',
      });
      await _ensureColumns(db, 'posts', const {
        'author_id': 'TEXT',
        'content': 'TEXT',
        'image_path': 'TEXT',
        'likes': 'INTEGER DEFAULT 0',
        'comments': 'INTEGER DEFAULT 0',
        'user_liked': 'INTEGER DEFAULT 0',
        'user_collected': 'INTEGER DEFAULT 0',
        'timestamp': 'INTEGER',
      });
      await _ensureColumns(db, 'memories', const {
        'bot_id': 'TEXT',
        'title': "TEXT DEFAULT ''",
        'type': 'TEXT',
        'content': 'TEXT',
        'category': "TEXT DEFAULT '记忆'",
        'importance': 'INTEGER DEFAULT 3',
        'expires_at': 'INTEGER',
        'timestamp': 'INTEGER',
        'updated_at': 'INTEGER',
        'keys_json': "TEXT DEFAULT '[]'",
        'trigger_count': 'INTEGER DEFAULT 0',
        'last_triggered_at': 'INTEGER',
        'auto_created': 'INTEGER DEFAULT 0',
        'source_chat_id': 'TEXT',
        'is_deleted': 'INTEGER DEFAULT 0',
      });
      await _ensureColumns(db, 'schedule_tasks', const {
        'bot_id': 'TEXT',
        'title': 'TEXT',
        'note': 'TEXT',
        'time': 'INTEGER',
        'is_done': 'INTEGER',
        'frequency': "TEXT DEFAULT 'once'",
        'prompt': "TEXT DEFAULT ''",
        'run_at': 'INTEGER',
        'status': "TEXT DEFAULT 'pending'",
        'attempts': 'INTEGER NOT NULL DEFAULT 0',
        'last_error': 'TEXT',
        'retry_at': 'INTEGER',
        'locked_at': 'INTEGER',
        'idempotency_key': 'TEXT',
      });
      await _ensureColumns(db, 'post_comments', const {
        'post_id': 'TEXT',
        'author_id': 'TEXT',
        'content': 'TEXT',
        'parent_id': 'TEXT',
        'timestamp': 'INTEGER',
      });
      await _ensureColumns(db, 'mcp_servers', const {
        'timeout_ms': 'INTEGER NOT NULL DEFAULT 20000',
        'auto_connect': 'INTEGER NOT NULL DEFAULT 0',
        'resources_json': "TEXT NOT NULL DEFAULT '[]'",
        'prompts_json': "TEXT NOT NULL DEFAULT '[]'",
      });
      await _ensureColumns(db, 'skill_tools', const {
        'risk_level': "TEXT NOT NULL DEFAULT 'normal'",
        'authorized': 'INTEGER NOT NULL DEFAULT 0',
      });
      for (final sql in const [
        'CREATE INDEX IF NOT EXISTS idx_chat_history_bot_timestamp ON chat_history(bot_id, timestamp)',
        'CREATE INDEX IF NOT EXISTS idx_chat_history_reply_group ON chat_history(reply_group_id, timestamp)',
        'CREATE INDEX IF NOT EXISTS idx_stickers_emotion ON stickers(emotion)',
        'CREATE INDEX IF NOT EXISTS idx_post_comments_parent ON post_comments(post_id, parent_id, timestamp)',
        'CREATE INDEX IF NOT EXISTS idx_bot_diaries_bot_date ON bot_diaries(bot_id, date_key)',
        'CREATE INDEX IF NOT EXISTS idx_life_schedule_bot_date ON bot_life_schedules(bot_id, date_key)',
        'CREATE INDEX IF NOT EXISTS idx_schedule_tasks_due ON schedule_tasks(status, retry_at, run_at)',
        'CREATE INDEX IF NOT EXISTS idx_memories_bot_type_timestamp ON memories(bot_id, type, timestamp)',
      ]) {
        await _execSql(db, sql);
      }
      return true;
    } catch (error) {
      print('[db] schema repair failed: $error');
      return false;
    }
  }

  Future<Database> _initDB() async {
    final support = await getApplicationSupportDirectory();
    final marker = File(p.join(support.path, 'restore_credentials_pending'));
    if (await marker.exists()) {
      const secure = FlutterSecureStorage();
      final entries = await secure.readAll();
      for (final key in entries.keys) {
        if (key.startsWith('mcp_headers_') ||
            key.startsWith('skill_headers_')) {
          await secure.delete(key: key);
        }
      }
      if (await marker.exists()) await marker.delete();
    }
    final path = p.join(await getDatabasesPath(), 'tidebot.db');
    final database = await openDatabase(
      path,
      version: 36,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onOpen: (db) async {
        await _createSkillTables(db);
        await MediaStorageService.ensureSchema(db);
        await db.execute(
          'CREATE TABLE IF NOT EXISTS foreground_message_events (message_id TEXT PRIMARY KEY)',
        );
        await _ensureColumns(db, 'mcp_servers', const {
          'description': "TEXT NOT NULL DEFAULT ''",
          'service_description': "TEXT NOT NULL DEFAULT ''",
        });
        // 只在首次打开或版本变更时执行完整修复，避免每次启动重复检查
        final needsRepair = await _shouldRepairSchema(db);
        if (needsRepair) {
          final repaired = await _repairExistingDatabase(db);
          await _ensureVoiceCallStorage(db);
          if (repaired) await _markSchemaRepaired(db);
          // 历史数据库保留原数据，停用照片回忆迁移。
        } else {
          await _ensureVoiceCallStorage(db);
        }
        await _ensureColumns(db, 'skills', const {'bot_scope': 'TEXT'});
        await _ensureColumns(db, 'mcp_servers', const {'bot_scope': 'TEXT'});
        await db.update(
          'memories',
          {'category': '记忆'},
          where: "category = 'fact' OR category IS NULL OR category = ''",
        );
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE bots (
            id TEXT PRIMARY KEY, name TEXT, desc TEXT, prompt TEXT,
            avatar TEXT, chat_model TEXT, stt_model TEXT, tts_model TEXT,
            video_model TEXT, max_tokens INTEGER, created_at INTEGER, daily_quote TEXT,
            last_msg_time INTEGER, is_pinned INTEGER DEFAULT 0,
            last_read_at INTEGER DEFAULT 0,
            is_disabled INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE chat_history (
            id TEXT PRIMARY KEY, bot_id TEXT, role TEXT, type TEXT,
            content TEXT, file_path TEXT, mood TEXT, duration INTEGER,
            error_log TEXT, error_code TEXT, error_message TEXT, retry_status TEXT NOT NULL DEFAULT 'none', reply_to_id TEXT, reply_group_id TEXT, sources_json TEXT, timestamp INTEGER,

            FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE memories (
            id TEXT PRIMARY KEY, bot_id TEXT, title TEXT DEFAULT '', type TEXT,
            content TEXT, category TEXT DEFAULT '记忆', importance INTEGER DEFAULT 3,
            expires_at INTEGER, timestamp INTEGER, updated_at INTEGER,
            FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE schedule_tasks (
            id TEXT PRIMARY KEY, bot_id TEXT, title TEXT, note TEXT, time INTEGER, is_done INTEGER, frequency TEXT DEFAULT 'once', prompt TEXT DEFAULT '', run_at INTEGER, status TEXT DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, retry_at INTEGER, locked_at INTEGER, idempotency_key TEXT,
            FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_schedule_tasks_due
          ON schedule_tasks(status, retry_at, run_at)
        ''');
        await db.execute('''
          CREATE TABLE bot_life_schedules (
            id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, date_key TEXT NOT NULL,
            theme TEXT DEFAULT '', mood TEXT DEFAULT '', outfit_style TEXT DEFAULT '',
            outfit TEXT DEFAULT '', timeline_json TEXT DEFAULT '[]',
            generated_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            UNIQUE(bot_id, date_key),
            FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE posts (
            id TEXT PRIMARY KEY, author_id TEXT, content TEXT, image_path TEXT,
            likes INTEGER DEFAULT 0, comments INTEGER DEFAULT 0,
            user_liked INTEGER DEFAULT 0, user_collected INTEGER DEFAULT 0,
            timestamp INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE post_comments (
            id TEXT PRIMARY KEY, post_id TEXT NOT NULL, author_id TEXT,
            content TEXT NOT NULL, parent_id TEXT, timestamp INTEGER,
            FOREIGN KEY (post_id) REFERENCES posts (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE kv_store (
            key TEXT PRIMARY KEY, value TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE stickers (
            id TEXT PRIMARY KEY, emotion TEXT NOT NULL, file_path TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE feed_events (
            id TEXT PRIMARY KEY, post_id TEXT NOT NULL, actor_id TEXT NOT NULL,
            event_type TEXT NOT NULL, timestamp INTEGER NOT NULL,
            UNIQUE(post_id, actor_id, event_type),
            FOREIGN KEY (post_id) REFERENCES posts (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE bot_diaries (
            id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, date_key TEXT NOT NULL,
            content TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE,
            UNIQUE(bot_id, date_key)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_bot_diaries_bot_date ON bot_diaries(bot_id, date_key)',
        );
        await db.execute('''
          CREATE TABLE ai_usage_events (
            id TEXT PRIMARY KEY, bot_id TEXT, event_type TEXT NOT NULL,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            reply_count INTEGER NOT NULL DEFAULT 0, timestamp INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE world_books (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT DEFAULT '',
            bot_id TEXT,
            is_global INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE TABLE world_book_entries (
            id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            bot_id TEXT,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            comment TEXT DEFAULT '',
            keys TEXT NOT NULL,
            secondary_keys TEXT DEFAULT '[]',
            key_mode TEXT DEFAULT 'any',
            case_sensitive INTEGER DEFAULT 0,
            match_whole_words INTEGER DEFAULT 0,
            use_regex INTEGER DEFAULT 0,
            position TEXT DEFAULT 'after_char',
            insertion_order INTEGER DEFAULT 100,
            priority INTEGER DEFAULT 50,
            enabled INTEGER DEFAULT 1,
            activation_count INTEGER DEFAULT 0,
            last_activated_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (book_id) REFERENCES world_books (id) ON DELETE CASCADE,
            FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_world_book_entries_book ON world_book_entries(book_id, enabled)
        ''');
        await db.execute('''
          CREATE INDEX idx_world_book_entries_bot ON world_book_entries(bot_id, enabled)
        ''');
        await _createCallTables(db);
        await _createSkillTables(db);
      },
      onDowngrade: (db, oldVersion, newVersion) async {
        print('[db] onDowngrade $oldVersion -> $newVersion; preserving data');
        await _repairExistingDatabase(db);
        await db.update(
          'memories',
          {'category': '记忆'},
          where: "category = 'fact' OR category IS NULL OR category = ''",
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _repairExistingDatabase(db);
        await db.update(
          'memories',
          {'category': '记忆'},
          where: "category = 'fact' OR category IS NULL OR category = ''",
        );
        try {
          if (oldVersion < 2) {
            try {
              await db.execute('ALTER TABLE bots ADD COLUMN avatar TEXT');
            } catch (_) {}
            try {
              await db.execute('ALTER TABLE bots ADD COLUMN daily_quote TEXT');
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE schedule_tasks ADD COLUMN note TEXT',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE posts ADD COLUMN likes INTEGER DEFAULT 0',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE posts ADD COLUMN comments INTEGER DEFAULT 0',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE bots ADD COLUMN last_msg_time INTEGER',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE bots ADD COLUMN is_pinned INTEGER DEFAULT 0',
              );
            } catch (_) {}
          }
          if (oldVersion < 4) {
            try {
              await db.execute(
                'ALTER TABLE chat_history ADD COLUMN duration INTEGER',
              );
            } catch (_) {}
          }
          if (oldVersion < 5) {
            try {
              await db.execute(
                'ALTER TABLE posts ADD COLUMN user_liked INTEGER DEFAULT 0',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE posts ADD COLUMN user_collected INTEGER DEFAULT 0',
              );
            } catch (_) {}
            await db.execute('''
            CREATE TABLE IF NOT EXISTS post_comments (
              id TEXT PRIMARY KEY, post_id TEXT NOT NULL, author_id TEXT,
              content TEXT NOT NULL, parent_id TEXT, timestamp INTEGER,
              FOREIGN KEY (post_id) REFERENCES posts (id) ON DELETE CASCADE
            )
          ''');
          }
          if (oldVersion < 6) {
            try {
              await db.execute(
                'ALTER TABLE chat_history ADD COLUMN error_log TEXT',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE chat_history ADD COLUMN error_code TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 7) {
            try {
              await db.execute(
                'ALTER TABLE chat_history ADD COLUMN error_message TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 8) {
            await db.execute('''
            CREATE TABLE IF NOT EXISTS feed_events (
              id TEXT PRIMARY KEY, post_id TEXT NOT NULL, actor_id TEXT NOT NULL,
              event_type TEXT NOT NULL, timestamp INTEGER NOT NULL,
              UNIQUE(post_id, actor_id, event_type),
              FOREIGN KEY (post_id) REFERENCES posts (id) ON DELETE CASCADE
            )
          ''');
          }
          if (oldVersion < 9) {
            await db.execute('''
            CREATE TABLE IF NOT EXISTS ai_usage_events (
              id TEXT PRIMARY KEY, bot_id TEXT, event_type TEXT NOT NULL,
              prompt_tokens INTEGER NOT NULL DEFAULT 0,
              completion_tokens INTEGER NOT NULL DEFAULT 0,
              total_tokens INTEGER NOT NULL DEFAULT 0,
              reply_count INTEGER NOT NULL DEFAULT 0, timestamp INTEGER NOT NULL
            )
          ''');
          }
          if (oldVersion < 10) {
            try {
              await db.execute(
                'ALTER TABLE chat_history ADD COLUMN reply_to_id TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 11) {
            try {
              await db.execute(
                'ALTER TABLE chat_history ADD COLUMN sources_json TEXT',
              );
            } catch (_) {}
            await db.execute('''
            CREATE TABLE IF NOT EXISTS stickers (
              id TEXT PRIMARY KEY, emotion TEXT NOT NULL, file_path TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )
          ''');
          }
          if (oldVersion < 12) {
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_stickers_emotion ON stickers(emotion)',
            );
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_chat_history_bot_timestamp ON chat_history(bot_id, timestamp)',
            );
          }
          if (oldVersion < 13) {
            try {
              await db.execute(
                "ALTER TABLE memories ADD COLUMN category TEXT DEFAULT '记忆'",
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE memories ADD COLUMN importance INTEGER DEFAULT 3',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE memories ADD COLUMN expires_at INTEGER',
              );
            } catch (_) {}
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_memories_bot_type_timestamp ON memories(bot_id, type, timestamp)',
            );
          }
          if (oldVersion < 16) {
            try {
              await db.execute(
                'ALTER TABLE memories ADD COLUMN updated_at INTEGER',
              );
            } catch (_) {}
            await db.execute(
              'UPDATE memories SET updated_at = timestamp WHERE updated_at IS NULL',
            );
          }
          if (oldVersion < 17) {
            try {
              await db.execute(
                'ALTER TABLE post_comments ADD COLUMN parent_id TEXT',
              );
            } catch (_) {}
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_post_comments_parent ON post_comments(post_id, parent_id, timestamp)',
            );
          }
          if (oldVersion < 18) {
            try {
              await db.execute(
                'ALTER TABLE bots ADD COLUMN last_read_at INTEGER DEFAULT 0',
              );
            } catch (_) {}
          }
          if (oldVersion < 19) {
            try {
              await db.execute(
                'ALTER TABLE bots ADD COLUMN is_disabled INTEGER DEFAULT 0',
              );
            } catch (_) {}
          }
          if (oldVersion < 20) {
            await db.execute('''
            CREATE TABLE IF NOT EXISTS bot_diaries (
              id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, date_key TEXT NOT NULL,
              content TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE,
              UNIQUE(bot_id, date_key)
            )
          ''');
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_bot_diaries_bot_date ON bot_diaries(bot_id, date_key)',
            );
            await db.execute(
              "UPDATE memories SET type = 'long' WHERE type NOT IN ('long', 'short') OR type IS NULL",
            );
          }
          if (oldVersion < 21) {
            try {
              await db.execute(
                'ALTER TABLE chat_history ADD COLUMN reply_group_id TEXT',
              );
            } catch (_) {}
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_chat_history_reply_group ON chat_history(reply_group_id, timestamp)',
            );
          }
          if (oldVersion < 22) await _createSkillTables(db);
          if (oldVersion < 23) {
            for (final sql in [
              'ALTER TABLE mcp_servers ADD COLUMN timeout_ms INTEGER NOT NULL DEFAULT 20000',
              'ALTER TABLE mcp_servers ADD COLUMN auto_connect INTEGER NOT NULL DEFAULT 0',
              'ALTER TABLE mcp_servers ADD COLUMN resources_json TEXT NOT NULL DEFAULT \'[]\'',
              'ALTER TABLE mcp_servers ADD COLUMN prompts_json TEXT NOT NULL DEFAULT \'[]\'',
              'ALTER TABLE skill_tools ADD COLUMN risk_level TEXT NOT NULL DEFAULT \'normal\'',
            ]) {
              try {
                await db.execute(sql);
              } catch (_) {}
            }
          }
          if (oldVersion < 24) {
            try {
              await db.execute(
                'ALTER TABLE skill_tools ADD COLUMN authorized INTEGER NOT NULL DEFAULT 0',
              );
            } catch (_) {}
          }

          if (oldVersion < 25) {
            for (final column in [
              'attempts INTEGER NOT NULL DEFAULT 0',
              'last_error TEXT',
              'retry_at INTEGER',
              'locked_at INTEGER',
              'idempotency_key TEXT',
            ]) {
              try {
                await db.execute(
                  'ALTER TABLE schedule_tasks ADD COLUMN $column',
                );
              } catch (_) {}
            }
            try {
              await db.execute('''
              CREATE INDEX IF NOT EXISTS idx_schedule_tasks_due
              ON schedule_tasks(status, retry_at, run_at)
            ''');
            } catch (_) {}
          }

          if (oldVersion < 26) {
            try {
              await db.execute(
                "ALTER TABLE chat_history ADD COLUMN retry_status TEXT NOT NULL DEFAULT 'none'",
              );
            } catch (_) {}
          }
          if (oldVersion < 29) await _createCallTables(db);
          if (oldVersion < 30) {
            print('[db] schema repair pass for version 30');
          }
          if (oldVersion < 31) {
            // 世界书功能：扩展memories表
            for (final sql in [
              "ALTER TABLE memories ADD COLUMN keys_json TEXT DEFAULT '[]'",
              'ALTER TABLE memories ADD COLUMN trigger_count INTEGER DEFAULT 0',
              'ALTER TABLE memories ADD COLUMN last_triggered_at INTEGER',
              'ALTER TABLE memories ADD COLUMN auto_created INTEGER DEFAULT 0',
              'ALTER TABLE memories ADD COLUMN source_chat_id TEXT',
              'ALTER TABLE memories ADD COLUMN is_deleted INTEGER DEFAULT 0',
            ]) {
              try {
                await db.execute(sql);
              } catch (_) {}
            }
            // 初始化已有记忆的keys_json（从content提取简单关键词）
            try {
              await db.execute(
                "UPDATE memories SET keys_json = '[]' WHERE keys_json IS NULL",
              );
            } catch (_) {}
          }
          if (oldVersion < 32) {
            // 世界书独立表
            try {
              await db.execute('''
                CREATE TABLE IF NOT EXISTS world_books (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  description TEXT DEFAULT '',
                  bot_id TEXT,
                  is_global INTEGER DEFAULT 0,
                  created_at INTEGER NOT NULL,
                  updated_at INTEGER NOT NULL,
                  FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
                )
              ''');
            } catch (_) {}
            try {
              await db.execute('''
                CREATE TABLE IF NOT EXISTS world_book_entries (
                  id TEXT PRIMARY KEY,
                  book_id TEXT NOT NULL,
                  bot_id TEXT,
                  title TEXT NOT NULL,
                  content TEXT NOT NULL,
                  comment TEXT DEFAULT '',
                  keys TEXT NOT NULL,
                  secondary_keys TEXT DEFAULT '[]',
                  key_mode TEXT DEFAULT 'any',
                  case_sensitive INTEGER DEFAULT 0,
                  match_whole_words INTEGER DEFAULT 0,
                  use_regex INTEGER DEFAULT 0,
                  position TEXT DEFAULT 'after_char',
                  insertion_order INTEGER DEFAULT 100,
                  priority INTEGER DEFAULT 50,
                  enabled INTEGER DEFAULT 1,
                  activation_count INTEGER DEFAULT 0,
                  last_activated_at INTEGER,
                  created_at INTEGER NOT NULL,
                  updated_at INTEGER NOT NULL,
                  FOREIGN KEY (book_id) REFERENCES world_books (id) ON DELETE CASCADE,
                  FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
                )
              ''');
            } catch (_) {}
            try {
              await db.execute('''
                CREATE INDEX IF NOT EXISTS idx_world_book_entries_book
                ON world_book_entries(book_id, enabled)
              ''');
            } catch (_) {}
            try {
              await db.execute('''
                CREATE INDEX IF NOT EXISTS idx_world_book_entries_bot
                ON world_book_entries(bot_id, enabled)
              ''');
            } catch (_) {}
          }
          if (oldVersion < 15) {
            for (final column in [
              "frequency TEXT DEFAULT 'once'",
              "prompt TEXT DEFAULT ''",
              'run_at INTEGER',
              "status TEXT DEFAULT 'pending'",
            ]) {
              try {
                await db.execute(
                  'ALTER TABLE schedule_tasks ADD COLUMN $column',
                );
              } catch (_) {}
            }
            try {
              await db.update(
                'memories',
                {'type': 'long'},
                where: 'type = ?',
                whereArgs: ['medium'],
              );
            } catch (_) {}
          }
          if (oldVersion < 14) {
            await db.execute('''
            CREATE TABLE IF NOT EXISTS bot_life_schedules (
              id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, date_key TEXT NOT NULL,
              theme TEXT DEFAULT '', mood TEXT DEFAULT '', outfit_style TEXT DEFAULT '',
              outfit TEXT DEFAULT '', timeline_json TEXT DEFAULT '[]',
              generated_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              UNIQUE(bot_id, date_key),
              FOREIGN KEY (bot_id) REFERENCES bots (id) ON DELETE CASCADE
            )
          ''');
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_life_schedule_bot_date ON bot_life_schedules(bot_id, date_key)',
            );
          }
          if (oldVersion < 35) {
            // 添加视频解析模型字段
            try {
              await db.execute('ALTER TABLE bots ADD COLUMN video_model TEXT');
            } catch (_) {}
          }
          if (oldVersion < 36) {
            await _createSkillTables(db);
          }
        } catch (error) {
          print('[db] onUpgrade continued after error: $error');
        }
        await _repairExistingDatabase(db);
        await db.update(
          'memories',
          {'category': '记忆'},
          where: "category = 'fact' OR category IS NULL OR category = ''",
        );
      },
    );
    // Legacy summaries are optional cleanup. Schedule it after the database
    // future completes so it cannot queue ahead of the caller's first query.
    unawaited(
      Future<void>.delayed(Duration.zero, () async {
        await _migrateLegacyCallSummaries(database);
      }).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          print('[db] call summary migration deferred: timed out');
        },
      ),
    );
    return database;
  }

  Future<void> _migrateLegacyCallSummaries(Database db) async {
    try {
      final summaries = await db.query(
        'chat_history',
        where: "type = 'call_summary'",
        orderBy: 'timestamp ASC',
      );
      if (summaries.isEmpty) return;

      // Keep the legacy row as the source of truth. A failed or interrupted
      // conversion must never remove a user's historical record. The call view
      // reads call_sessions, while the legacy chat row remains recoverable.
      for (final summary in summaries) {
        final id = summary['id']?.toString() ?? '';
        final botId = summary['bot_id']?.toString() ?? '';
        if (id.isEmpty || botId.isEmpty) continue;
        await db.insert('call_sessions', {
          'id': 'legacy_$id',
          'bot_id': botId,
          'summary': summary['content']?.toString() ?? '',
          'duration': (summary['duration'] as num?)?.toInt() ?? 0,
          'status': 'completed',
          'created_at': (summary['timestamp'] as num?)?.toInt() ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    } catch (error) {
      // Preserve legacy rows if migration cannot complete. Database open must
      // remain available; this idempotent cleanup will retry next open.
      print('[db] call summary migration deferred: $error');
    }
  }

  Future<void> _createCallTables(DatabaseExecutor db) async {
    await _execSql(db, '''CREATE TABLE IF NOT EXISTS call_sessions (
      id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, summary TEXT NOT NULL,
      duration INTEGER NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL,
      FOREIGN KEY(bot_id) REFERENCES bots(id) ON DELETE CASCADE)''');
    await _execSql(
      db,
      '''CREATE TABLE IF NOT EXISTS call_messages (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
      content TEXT NOT NULL, timestamp INTEGER NOT NULL,
      FOREIGN KEY(session_id) REFERENCES call_sessions(id) ON DELETE CASCADE)''',
    );
    await _execSql(
      db,
      'CREATE INDEX IF NOT EXISTS idx_call_sessions_bot_created ON call_sessions(bot_id, created_at DESC)',
    );
    await _execSql(
      db,
      'CREATE INDEX IF NOT EXISTS idx_call_messages_session_time ON call_messages(session_id, timestamp)',
    );
  }

  Future<void> _createSkillTables(DatabaseExecutor db) async {
    await _execSql(db, '''CREATE TABLE IF NOT EXISTS plugins (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '', author TEXT NOT NULL DEFAULT '',
      manifest_json TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0,
      config_json TEXT NOT NULL DEFAULT '{}', updated_at INTEGER NOT NULL
    )''');
    await _execSql(db, '''CREATE TABLE IF NOT EXISTS skills (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL,
      description TEXT DEFAULT '', manifest_json TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL DEFAULT 'ready',
      built_in INTEGER NOT NULL DEFAULT 0, recommended INTEGER NOT NULL DEFAULT 0,
      bot_scope TEXT,
      error TEXT, updated_at INTEGER NOT NULL)''');
    await _execSql(db, '''CREATE TABLE IF NOT EXISTS skill_tools (
      id TEXT PRIMARY KEY, skill_id TEXT NOT NULL, name TEXT NOT NULL,
      description TEXT DEFAULT '', executor TEXT NOT NULL,
      schema_json TEXT NOT NULL, risk_level TEXT NOT NULL DEFAULT 'normal',
      authorized INTEGER NOT NULL DEFAULT 0,
      enabled INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(skill_id) REFERENCES skills(id) ON DELETE CASCADE,
      UNIQUE(skill_id, name))''');
    await _execSql(db, '''CREATE TABLE IF NOT EXISTS mcp_servers (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, url TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      service_description TEXT NOT NULL DEFAULT '',
      bot_scope TEXT,
      headers_key TEXT, timeout_ms INTEGER NOT NULL DEFAULT 20000,
      auto_connect INTEGER NOT NULL DEFAULT 0,
      resources_json TEXT NOT NULL DEFAULT '[]',
      prompts_json TEXT NOT NULL DEFAULT '[]',
      enabled INTEGER NOT NULL DEFAULT 1,
      status TEXT NOT NULL DEFAULT 'disconnected', error TEXT,
      updated_at INTEGER NOT NULL)''');
    await _execSql(db, '''CREATE TABLE IF NOT EXISTS mcp_tools (
      id TEXT PRIMARY KEY, server_id TEXT NOT NULL, name TEXT NOT NULL,
      description TEXT DEFAULT '', schema_json TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1, discovered_at INTEGER NOT NULL,
      FOREIGN KEY(server_id) REFERENCES mcp_servers(id) ON DELETE CASCADE,
      UNIQUE(server_id, name))''');
    await _execSql(db, '''CREATE TABLE IF NOT EXISTS tool_audit (
      id TEXT PRIMARY KEY, source TEXT NOT NULL, tool_name TEXT NOT NULL,
      input_summary TEXT NOT NULL, status TEXT NOT NULL, duration_ms INTEGER NOT NULL,
      error TEXT, created_at INTEGER NOT NULL)''');
  }

  Future<List<Map<String, dynamic>>> queryPlugins() async =>
      (await database).query('plugins', orderBy: 'updated_at DESC');
  Future<void> savePlugin(Map<String, dynamic> plugin) async => (await database)
      .insert('plugins', plugin, conflictAlgorithm: ConflictAlgorithm.replace);
  Future<void> setPluginEnabled(String id, bool enabled) async =>
      (await database).update(
        'plugins',
        {'enabled': enabled ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );
  Future<void> deletePlugin(String id) async =>
      (await database).delete('plugins', where: 'id = ?', whereArgs: [id]);
  Future<void> savePluginConfig(String id, String config) async =>
      (await database).update(
        'plugins',
        {'config_json': config},
        where: 'id = ?',
        whereArgs: [id],
      );
  Future<String?> pluginConfig(String id) async {
    final rows = await (await database).query(
      'plugins',
      columns: ['config_json'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['config_json']?.toString();
  }

  Future<List<Map<String, dynamic>>> queryEnabledSkillTools({
    String? botId,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      "SELECT t.*, s.bot_scope FROM skill_tools t JOIN skills s ON s.id=t.skill_id WHERE t.enabled=1 AND s.enabled=1 AND (t.risk_level != 'sensitive' OR t.authorized=1)",
    );
    return toolRowsForBot(rows, botId);
  }

  Future<List<Map<String, dynamic>>> queryEnabledMcpTools({
    String? botId,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT t.*, s.url, s.headers_key, s.timeout_ms, s.bot_scope FROM mcp_tools t JOIN mcp_servers s ON s.id=t.server_id WHERE t.enabled=1 AND s.enabled=1',
    );
    return toolRowsForBot(rows, botId);
  }

  Future<List<Map<String, dynamic>>> querySkills({String? botId}) async =>
      toolRowsForBot(
        await (await database).query('skills', orderBy: 'updated_at DESC'),
        botId,
      );
  Future<List<Map<String, dynamic>>> queryMcpServers({String? botId}) async =>
      toolRowsForBot(
        await (await database).query('mcp_servers', orderBy: 'updated_at DESC'),
        botId,
      );

  Future<void> setToolBotScope(
    String id, {
    required bool skill,
    String? scope,
  }) async {
    await (await database).update(
      skill ? 'skills' : 'mcp_servers',
      {'bot_scope': scope},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveSkill(
    Map<String, dynamic> skill,
    List<Map<String, dynamic>> tools,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'skills',
        skill,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete(
        'skill_tools',
        where: 'skill_id = ?',
        whereArgs: [skill['id']],
      );
      for (final tool in tools)
        await txn.insert(
          'skill_tools',
          tool,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
    });
  }

  Future<void> saveMcpServer(Map<String, dynamic> server) async =>
      (await database).insert(
        'mcp_servers',
        server,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> saveMcpTools(
    String serverId,
    List<Map<String, dynamic>> tools,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      final previous = <String, int>{
        for (final row in await txn.query(
          'mcp_tools',
          columns: ['name', 'enabled'],
          where: 'server_id = ?',
          whereArgs: [serverId],
        ))
          row['name'].toString(): (row['enabled'] as num?)?.toInt() ?? 1,
      };
      await txn.delete(
        'mcp_tools',
        where: 'server_id = ?',
        whereArgs: [serverId],
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final tool in tools) {
        final name = tool['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        await txn.insert('mcp_tools', {
          'id': 'mcp_tool_${serverId}_$name',
          'server_id': serverId,
          'name': name,
          'description': tool['description']?.toString() ?? '',
          'schema_json': jsonEncode(tool['inputSchema'] ?? {'type': 'object'}),
          'enabled': previous[name] ?? 1,
          'discovered_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.update(
        'mcp_servers',
        {'status': 'connected', 'error': null, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [serverId],
      );
    });
  }

  Future<void> updateMcpStatus(
    String id,
    String status, [
    String? error,
  ]) async => (await database).update(
    'mcp_servers',
    {
      'status': status,
      'error': error,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    },
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> insertToolAudit({
    required String source,
    required String toolName,
    required String inputSummary,
    required String status,
    required int durationMs,
    String? error,
  }) async => (await database).insert('tool_audit', {
    'id': 'audit_${DateTime.now().microsecondsSinceEpoch}',
    'source': source,
    'tool_name': toolName,
    'input_summary': inputSummary,
    'status': status,
    'duration_ms': durationMs,
    'error': error,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });

  Future<void> removeLegacyVideoSkill() async {
    final db = await database;
    await db.transaction((txn) async {
      const where = 'id = ? AND built_in = 1';
      const args = ['view_video'];
      final legacy = await txn.query('skills', where: where, whereArgs: args);
      if (legacy.isEmpty) return;
      await txn.delete('skill_tools', where: 'skill_id = ?', whereArgs: args);
      await txn.delete('skills', where: where, whereArgs: args);
    });
  }

  Future<void> deleteSkill(String id) async {
    final db = await database;
    // 检查是否为内置skill
    final skill = await db.query('skills', where: 'id = ?', whereArgs: [id]);
    if (skill.isNotEmpty && skill.first['built_in'] == 1) {
      throw Exception('内置Skill无法删除');
    }
    await db.delete('skills', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMcpServer(String id) async =>
      (await database).delete('mcp_servers', where: 'id = ?', whereArgs: [id]);

  Future<void> setSkillEnabled(String id, bool enabled) async =>
      (await database).update(
        'skills',
        {
          'enabled': enabled ? 1 : 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> setMcpServerEnabled(String id, bool enabled) async =>
      (await database).update(
        'mcp_servers',
        {
          'enabled': enabled ? 1 : 0,
          'status': enabled ? 'disconnected' : 'disabled',
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> setSkillToolEnabled(String id, bool enabled) async =>
      (await database).update(
        'skill_tools',
        {'enabled': enabled ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> setSkillToolAuthorized(String id, bool authorized) async =>
      (await database).update(
        'skill_tools',
        {'authorized': authorized ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> setMcpToolEnabled(String id, bool enabled) async =>
      (await database).update(
        'mcp_tools',
        {'enabled': enabled ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<List<Map<String, dynamic>>> querySkillTools(String skillId) async =>
      (await database).query(
        'skill_tools',
        where: 'skill_id = ?',
        whereArgs: [skillId],
        orderBy: 'name',
      );

  Future<List<Map<String, dynamic>>> queryMcpTools(String serverId) async =>
      (await database).query(
        'mcp_tools',
        where: 'server_id = ?',
        whereArgs: [serverId],
        orderBy: 'name',
      );

  Future<void> updateMcpServer(
    String id,
    Map<String, dynamic> values, {
    bool clearTools = false,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      // UPDATE preserves child rows; REPLACE can cascade-delete tool settings.
      final count = await txn.update(
        'mcp_servers',
        {...values, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );
      if (count != 1) throw StateError('MCP server no longer exists');
      if (clearTools) {
        await txn.delete('mcp_tools', where: 'server_id = ?', whereArgs: [id]);
      }
    });
  }

  Future<void> saveMcpMetadata(
    String id, {
    required List<Map<String, dynamic>> resources,
    required List<Map<String, dynamic>> prompts,
    String? serviceDescription,
  }) async => (await database).update(
    'mcp_servers',
    {
      'resources_json': jsonEncode(resources),
      'prompts_json': jsonEncode(prompts),
      if (serviceDescription != null) 'service_description': serviceDescription,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    },
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<Map<String, dynamic>?> getLifeSchedule(
    String botId,
    String dateKey,
  ) async {
    final db = await database;
    final rows = await db.query(
      'bot_life_schedules',
      where: 'bot_id = ? AND date_key = ?',
      whereArgs: [botId, dateKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> upsertLifeSchedule(Map<String, dynamic> schedule) async {
    final db = await database;
    await db.insert(
      'bot_life_schedules',
      schedule,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ================= Bots CRUD =================
  Future<List<Map<String, dynamic>>> getAllBots({
    bool throwOnError = false,
  }) async {
    final db = await database;
    try {
      return await db.query('bots', orderBy: 'created_at DESC');
    } catch (error) {
      print('[db] getAllBots ordered query failed: $error');
      try {
        return await db.query('bots');
      } catch (fallbackError) {
        print('[db] getAllBots fallback failed: $fallbackError');
        if (throwOnError) rethrow;
        return const [];
      }
    }
  }

  Future<void> insertBot(Map<String, dynamic> bot) async {
    final db = await database;
    await db.insert('bots', bot, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Returns a single bot for notification deep links, or null if it was deleted.
  Future<Map<String, dynamic>?> getBotById(String id) async {
    final db = await database;
    final rows = await db.query(
      'bots',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> updateBot(String id, Map<String, dynamic> data) async {
    final db = await database;
    if (data.containsKey('is_disabled')) {
      await db.transaction((txn) async {
        await txn.update('bots', data, where: 'id = ?', whereArgs: [id]);
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final entry in {
          'bot_resumed_at_$id': '$now',
          'proactive_due_at_$id': '0',
          'proactive_unanswered_$id': '0',
        }.entries) {
          await txn.insert('kv_store', {
            'key': entry.key,
            'value': entry.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
      await NativeBackgroundCoordinator.synchronize();
      return;
    }
    await db.update('bots', data, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteBot(String id) async {
    final db = await database;
    await clearChatHistory(id);
    // Foreign keys remove the remaining bot-owned rows.
    await db.delete('bots', where: 'id = ?', whereArgs: [id]);
    await NativeBackgroundCoordinator.synchronize();
  }

  // ================= 消息流管理 =================
  Future<void> updateMessageContent(String id, String content) async {
    final db = await database;
    await db.update(
      'chat_history',
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _publishMessageEvent(id, ChatEventType.updated);
  }

  Future<void> updateMessageSources(
    String id,
    List<Map<String, String>> sources,
  ) async {
    final db = await database;
    await db.update(
      'chat_history',
      {'sources_json': jsonEncode(sources)},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _publishMessageEvent(id, ChatEventType.updated);
  }

  Future<void> updateMessageError(
    String id, {
    required String errorLog,
    String? errorCode,
    String? errorMessage,
  }) async {
    final db = await database;
    await db.update(
      'chat_history',
      {
        'error_log': errorLog,
        'error_code': errorCode,
        'error_message': errorMessage,
        'retry_status': 'failed',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _publishMessageEvent(id, ChatEventType.failed);
  }

  Future<void> markMessageRetrying(String id) async {
    final db = await database;
    await db.update(
      'chat_history',
      {'retry_status': 'retrying'},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _publishMessageEvent(id, ChatEventType.retrying);
  }

  Future<void> clearMessageError(String id) async {
    final db = await database;
    await db.update(
      'chat_history',
      {
        'error_log': null,
        'error_code': null,
        'error_message': null,
        'retry_status': 'none',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _publishMessageEvent(id, ChatEventType.updated);
  }

  Future<void> _publishMessageEvent(String id, ChatEventType type) async {
    final row = await getMessageById(id);
    if (row == null) return;
    ChatEventBus.instance.publish(
      ChatEvent(
        type: type,
        botId: row['bot_id']?.toString(),
        messageId: id,
        message: row,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getChatHistory(String botId) async {
    return queryMessages(botId);
  }

  Future<Map<String, dynamic>> insertChatMessage(
    Map<String, dynamic> msg, {
    bool publishEvent = true,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      if (msg['role'] == 'user' && msg['bot_id'] != null) {
        await ProactiveRequestGate.userActivity(txn, msg['bot_id'].toString());
      }
      final path = msg['file_path'];
      if (path is String) {
        final aliases = await txn.query(
          'media_storage_jobs',
          columns: ['target'],
          where: "source = ? AND state IN ('cleanup', 'done')",
          whereArgs: [path],
        );
        if (aliases.isNotEmpty && aliases.first['target'] is String) {
          msg = {...msg, 'file_path': aliases.first['target']};
        }
      }

      await txn.insert(
        'chat_history',
        msg,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await MediaStorageService.enqueue(txn, msg);
      if (!ChatEventBus.instance.foregroundOwner) {
        await txn.insert('foreground_message_events', {
          'message_id': msg['id'],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final timestamp =
          (msg['timestamp'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'bots',
        {'last_msg_time': timestamp},
        where: 'id = ?',
        whereArgs: [msg['bot_id']],
      );
    });
    MediaStorageService.instance.kick();
    if (publishEvent) {
      ChatEventBus.instance.publish(
        ChatEvent(
          type: ChatEventType.inserted,
          botId: msg['bot_id']?.toString(),
          messageId: msg['id']?.toString(),
          message: Map<String, dynamic>.from(msg),
        ),
      );
    }
    return Map<String, dynamic>.from(msg);
  }

  Future<int> unreadBotCount() async {
    final db = await database;
    try {
      final rows = await db.rawQuery('''
        SELECT COUNT(*) AS count FROM bots b
        WHERE COALESCE((SELECT MAX(timestamp) FROM chat_history h
          WHERE h.bot_id = b.id AND h.role = 'assistant'), 0)
          > COALESCE(b.last_read_at, 0)
      ''');
      return (rows.first['count'] as num?)?.toInt() ?? 0;
    } catch (error) {
      print('[db] unreadBotCount failed: $error');
      return 0;
    }
  }

  /// Physical database footprint, including pending WAL writes and journals.
  /// This is shared by all app data; do not add it once per bot.
  Future<int> databaseStorageBytes() async {
    final db = await database;
    var bytes = 0;
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      try {
        final file = File('${db.path}$suffix');
        if (await file.exists()) bytes += await file.length();
      } on FileSystemException {
        // SQLite may remove a journal between exists() and length().
      }
    }
    return bytes;
  }

  /// Logical row payload plus referenced media, estimated per bot.
  /// Shared SQLite pages, indexes and journals are reported separately.
  Future<Map<String, int>> chatStorageByBot() async {
    final db = await database;
    try {
      final rows = await db.rawQuery('''
        SELECT bot_id, id, type, file_path,
          length(CAST(COALESCE(content, '') AS BLOB)) +
          length(CAST(COALESCE(file_path, '') AS BLOB)) +
          length(CAST(COALESCE(error_log, '') AS BLOB)) +
          length(CAST(COALESCE(sources_json, '') AS BLOB)) +
          length(CAST(COALESCE(id, '') AS BLOB)) +
          length(CAST(COALESCE(bot_id, '') AS BLOB)) +
          length(CAST(COALESCE(role, '') AS BLOB)) +
          length(CAST(COALESCE(type, '') AS BLOB)) +
          length(CAST(COALESCE(mood, '') AS BLOB)) +
          length(CAST(COALESCE(error_code, '') AS BLOB)) +
          length(CAST(COALESCE(error_message, '') AS BLOB)) +
          length(CAST(COALESCE(retry_status, '') AS BLOB)) +
          length(CAST(COALESCE(reply_to_id, '') AS BLOB)) +
          length(CAST(COALESCE(reply_group_id, '') AS BLOB)) + 96
          AS row_bytes
        FROM chat_history
      ''');
      final result = <String, int>{};
      final mediaByBot = <String, Set<String>>{};
      for (final row in rows) {
        final botId = row['bot_id']?.toString() ?? '';
        result[botId] =
            (result[botId] ?? 0) + ((row['row_bytes'] as num?)?.toInt() ?? 0);
        final type = row['type']?.toString() ?? '';
        final path = row['file_path']?.toString().trim() ?? '';
        if (path.isNotEmpty &&
            const {'image', 'video', 'audio', 'shared_post'}.contains(type)) {
          mediaByBot.putIfAbsent(botId, () => <String>{}).add(path);
        }
      }
      for (final entry in mediaByBot.entries) {
        for (final path in entry.value) {
          try {
            final file = File(path);
            if (await file.exists()) {
              result[entry.key] =
                  (result[entry.key] ?? 0) + await file.length();
            }
          } catch (_) {}
        }
      }
      final prefs = await SharedPreferences.getInstance();
      for (final botId in result.keys.toList()) {
        final history = prefs.getStringList('video_history_$botId') ?? [];
        final paths = <String>{};
        for (final raw in history) {
          try {
            final item = jsonDecode(raw);
            if (item is! Map) continue;
            final original =
                item['original_video_path']?.toString().trim() ?? '';
            if (original.isNotEmpty) paths.add(original);
            final audio = item['audio_path']?.toString().trim() ?? '';
            if (audio.isNotEmpty) paths.add(audio);
            final frames = item['frame_paths'];
            if (frames is List) {
              paths.addAll(
                frames
                    .map((path) => path.toString().trim())
                    .where((path) => path.isNotEmpty),
              );
            }
          } catch (_) {}
        }
        for (final path in paths) {
          try {
            final file = File(path);
            if (await file.exists()) {
              result[botId] = (result[botId] ?? 0) + await file.length();
            }
          } catch (_) {}
        }
      }
      return result;
    } catch (error) {
      print('[db] chatStorageByBot failed: $error');
      try {
        final rows = await db.rawQuery('''
          SELECT bot_id, SUM(length(CAST(COALESCE(content, '') AS BLOB)) + 96) AS bytes
          FROM chat_history GROUP BY bot_id
        ''');
        return {
          for (final row in rows)
            row['bot_id']?.toString() ?? '':
                (row['bytes'] as num?)?.toInt() ?? 0,
        };
      } catch (fallbackError) {
        print('[db] chatStorageByBot fallback failed: $fallbackError');
        return const {};
      }
    }
  }

  Future<void> _deleteChatRows(String where, List<Object?> args) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'chat_history',
        columns: ['id', 'file_path'],
        where: where,
        whereArgs: args,
      );
      await MediaStorageService.queueGarbage(
        txn,
        rows.map((row) => row['file_path']).whereType<String>(),
      );
      for (final row in rows) {
        await txn.delete(
          'background_messages',
          where: 'message_id = ?',
          whereArgs: [row['id']],
        );
        await txn.delete(
          'foreground_message_events',
          where: 'message_id = ?',
          whereArgs: [row['id']],
        );
        await txn.delete(
          'voice_call_records',
          where: 'id = (SELECT call_id FROM chat_history WHERE id = ?)',
          whereArgs: [row['id']],
        );
      }
      await txn.delete('chat_history', where: where, whereArgs: args);
    });
    MediaStorageService.instance.kick();
  }

  Future<void> deleteMessage(String msgId) =>
      _deleteChatRows('id = ?', [msgId]);
  Future<Map<String, dynamic>?> getMessageById(String msgId) async {
    final db = await database;
    final rows = await db.query(
      'chat_history',
      where: 'id = ?',
      whereArgs: [msgId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> insertCallSession({
    required Map<String, dynamic> session,
    required List<Map<String, dynamic>> messages,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'call_sessions',
        session,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final message in messages) {
        await txn.insert(
          'call_messages',
          message,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> queryCallSessions(String botId) async {
    final db = await database;
    return db.query(
      'call_sessions',
      where: 'bot_id = ?',
      whereArgs: [botId],
      orderBy: 'created_at DESC',
    );
  }

  Future<List<Map<String, dynamic>>> queryCallMessages(String sessionId) async {
    final db = await database;
    return db.query(
      'call_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
  }

  Future<void> clearChatHistory(String botId) async {
    await _deleteChatRows('bot_id = ?', [botId]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final history = prefs.getStringList('video_history_$botId') ?? [];
    final paths = <String>[];
    void collect(Object? value) {
      if (value is String && p.isAbsolute(value)) paths.add(value);
      if (value is Map) value.values.forEach(collect);
      if (value is List) value.forEach(collect);
    }

    for (final item in history) {
      try {
        collect(jsonDecode(item));
      } catch (_) {}
    }
    await prefs.remove('video_history_$botId');
    final db = await database;
    await db.transaction((txn) async {
      await MediaStorageService.queueGarbage(txn, paths);
      await txn.delete(
        'background_messages',
        where: 'bot_id = ?',
        whereArgs: [botId],
      );
    });
    MediaStorageService.instance.kick();
  }

  // ================= 表情包素材池 =================
  Future<List<Map<String, dynamic>>> queryStickers({String? emotion}) async {
    final db = await database;
    return db.query(
      'stickers',
      where: emotion == null ? null : 'emotion = ?',
      whereArgs: emotion == null ? null : [emotion],
      orderBy: 'created_at DESC',
    );
  }

  Future<void> insertSticker(Map<String, dynamic> sticker) async {
    final db = await database;
    await db.insert(
      'stickers',
      sticker,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteSticker(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'stickers',
        where: 'id = ?',
        whereArgs: [id],
      );
      await MediaStorageService.queueGarbage(
        txn,
        rows.map((row) => row['file_path']).whereType<String>(),
      );
      await txn.delete('stickers', where: 'id = ?', whereArgs: [id]);
    });
    MediaStorageService.instance.kick();
  }

  Future<List<String>> stickerEmotions() async {
    final db = await database;
    final rows = await db.query(
      'stickers',
      columns: ['emotion'],
      distinct: true,
      orderBy: 'emotion COLLATE NOCASE',
    );
    return rows
        .map((row) => row['emotion']?.toString().trim() ?? '')
        .where((emotion) => emotion.isNotEmpty)
        .toList();
  }

  // ================= 潜意识记忆 =================
  Future<void> clearMemories(String botId) async {
    final db = await database;
    await db.delete('memories', where: 'bot_id = ?', whereArgs: [botId]);
  }

  // ================= KV 与 API 配置 =================
  Future<void> setKV(String key, String value) async {
    final db = await database;
    await db.insert('kv_store', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (key == 'user_name' || key == 'user_avatar') UserProfileChanges.notify();
    if (key == 'proactive_min_minutes' || key == 'proactive_max_minutes') {
      await db.rawUpdate(
        "UPDATE kv_store SET value = '0' WHERE key GLOB 'proactive_due_at_*'",
      );
    }
    if (key == 'proactive_reply' ||
        key == 'proactive_min_minutes' ||
        key == 'proactive_max_minutes' ||
        key.startsWith('proactive_due_at_') ||
        key.startsWith('proactive_unanswered_')) {
      unawaited(NativeBackgroundCoordinator.synchronize());
    }
  }

  Future<String?> getKV(String key) async {
    final db = await database;
    final res = await db.query('kv_store', where: 'key = ?', whereArgs: [key]);
    if (res.isNotEmpty) return res.first['value'] as String;
    return null;
  }

  Future<List<Map<String, dynamic>>> exportableBots() async => queryBots();

  /// Writes bounded pages to JSON, then archives files without loading media.
  Future<({String fileName, File file, int missingMedia})> buildChatExport(
    String botId,
  ) async {
    final bot = await getBotById(botId);
    if (bot == null) throw StateError('机器人不存在');
    final work = await DataTransfer.workspace();
    try {
      final safeName = (bot['name']?.toString() ?? 'bot').replaceAll(
        RegExp(r'[^a-zA-Z0-9_\-\u4e00-\u9fff]'),
        '_',
      );
      final fileName =
          'tidebot_chat_${safeName}_${DateTime.now().millisecondsSinceEpoch}.zip';
      final json = File('${work.path}/chat_history.json');
      final sink = json.openWrite();
      final files = <String, String>{'chat_history.json': json.path};
      final media = TransferMedia(
        await getApplicationDocumentsDirectory(),
        await getTemporaryDirectory(),
        files,
      );
      final mapPath = media.mapPath;

      try {
        sink.write('{"format":"tidebot.chat","version":2,"exported_at":');
        sink.write(jsonEncode(DateTime.now().toIso8601String()));
        sink.write(
          ',"bot":${jsonEncode({'id': botId, 'name': bot['name']})},"video_history":[',
        );
        final prefs = await SharedPreferences.getInstance();
        var firstVideo = true;
        for (final encoded
            in prefs.getStringList('video_history_$botId') ?? <String>[]) {
          dynamic decoded;
          try {
            decoded = jsonDecode(encoded);
          } on FormatException {
            continue;
          }
          if (decoded is! Map) continue;
          final item = await mapTransferValue(decoded, mapPath);
          if (!firstVideo) sink.write(',');
          firstVideo = false;
          sink.write(jsonEncode(item));
          await sink.flush();
        }
        sink.write('],"messages":[');
        final db = await database;
        await db.transaction((txn) async {
          var offset = 0;
          var first = true;
          while (true) {
            final page = await txn.query(
              'chat_history',
              where: 'bot_id = ?',
              whereArgs: [botId],
              orderBy: 'timestamp ASC, id ASC',
              limit: 100,
              offset: offset,
            );
            if (page.isEmpty) break;
            for (final row in page) {
              final msg = await mapTransferValue(
                Map<String, dynamic>.from(row)..remove('bot_id'),
                mapPath,
              );
              if (!first) sink.write(',');
              first = false;
              sink.write(jsonEncode(msg));
            }
            await sink.flush();
            offset += page.length;
          }
        });
        sink.write('],"missing_media_references":${media.missingReferences}}');
        await sink.flush();
      } finally {
        await sink.close();
      }
      final file = File('${work.path}/$fileName');
      await DataTransfer.ensureSpace(
        work,
        await DataTransfer.totalBytes(files.values),
      );
      await DataTransfer.zip(file.path, files);
      return (
        fileName: fileName,
        file: file,
        missingMedia: media.missingReferences,
      );
    } catch (_) {
      await work.delete(recursive: true);
      rethrow;
    }
  }

  Future<String> exportBotChat(String botId) =>
      DataTransfer.exclusive(() async {
        final export = await buildChatExport(botId);
        try {
          final dir = await getApplicationDocumentsDirectory();
          final target = File('${dir.path}/TideBot/exports/${export.fileName}');
          await target.parent.create(recursive: true);
          await export.file.copy(target.path);
          return target.path;
        } finally {
          await export.file.parent.delete(recursive: true);
        }
      });
  Future<int> importBotChat(
    String botId,
    String sourcePath,
  ) => DataTransfer.exclusive(() async {
    final work = await DataTransfer.workspace();
    Directory? installedMedia;
    var committed = false;
    try {
      final source = File(sourcePath);
      final handle = await source.open();
      late List<int> signature;
      try {
        signature = await handle.read(4);
      } finally {
        await handle.close();
      }
      File json = source;
      if (signature.length == 4 &&
          signature[0] == 0x50 &&
          signature[1] == 0x4b) {
        await DataTransfer.extract(sourcePath, work.path);
        json = File('${work.path}/chat_history.json');
      }
      if (!await json.exists()) throw const FormatException('未找到聊天记录');
      String? format;
      int? version;
      var hasMessages = false;
      // Validate the entire stream before replacing any existing rows.
      await for (final record in JsonRecords.read(json)) {
        if (record.key == 'format') format = record.value as String?;
        if (record.key == 'version') version = record.value as int?;
        if (record.key == 'messages') {
          hasMessages = true;
          if (record.element && record.value is! Map)
            throw const FormatException('聊天消息格式无效');
        }
      }
      if (format != 'tidebot.chat' ||
          !const [1, 2].contains(version) ||
          !hasMessages) {
        throw const FormatException('仅支持 TideBot 导出的聊天记录文件');
      }
      final media = Directory('${work.path}/media');
      if (await media.exists()) {
        final docs = await getApplicationDocumentsDirectory();
        installedMedia = Directory(
          '${docs.path}/imported_media/${DateTime.now().microsecondsSinceEpoch}',
        );
        await installedMedia.parent.create(recursive: true);
        installedMedia = await media.rename(installedMedia.path);
      }
      final mediaMapper = installedMedia == null
          ? null
          : ImportedMedia(installedMedia, allowLegacyBasename: true);
      Future<dynamic> mapRecord(dynamic value) => mapTransferValue(
        value,
        (path) async =>
            mediaMapper == null ? path : await mediaMapper.mapPath(path),
      );

      final base = DateTime.now().microsecondsSinceEpoch;
      var count = 0;
      var latest = 0;
      final videos = <String>[];
      final db = await database;
      await db.transaction((txn) async {
        await txn.delete(
          'chat_history',
          where: 'bot_id = ?',
          whereArgs: [botId],
        );
        await for (final record in JsonRecords.read(json)) {
          if (!record.element) continue;
          if (record.key == 'video_history' && record.value is Map) {
            final item = await mapRecord(record.value) as Map;
            videos.add(jsonEncode(item));
          }
          if (record.key != 'messages') continue;
          final item = await mapRecord(record.value) as Map;
          final oldId = item['id']?.toString() ?? '';
          final reply = item['reply_to_id']?.toString() ?? '';
          final timestamp =
              (item['timestamp'] as num?)?.toInt() ?? base ~/ 1000 + count;
          if (timestamp > latest) latest = timestamp;
          await txn.insert('chat_history', {
            'id': oldId.isEmpty
                ? 'import_${base}_row_$count'
                : 'import_${base}_id_$oldId',
            'bot_id': botId,
            'role': item['role']?.toString() ?? 'user',
            'type': item['type']?.toString() ?? 'text',
            'content': item['content']?.toString() ?? '',
            'file_path': item['file_path']?.toString() ?? '',
            'mood': item['mood'],
            'duration': item['duration'],
            'reply_to_id': reply.isEmpty ? null : 'import_${base}_id_$reply',
            'reply_group_id': item['reply_group_id'],
            'sources_json': item['sources_json'],
            'timestamp': timestamp,
          });
          count++;
        }
        await txn.update(
          'bots',
          {'last_msg_time': latest},
          where: 'id = ?',
          whereArgs: [botId],
        );
      });
      committed = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('video_history_$botId', videos);
      return count;
    } finally {
      if (!committed &&
          installedMedia != null &&
          await installedMedia.exists()) {
        await installedMedia.delete(recursive: true);
      }
      await work.delete(recursive: true);
    }
  });

  Future<({String fileName, File file})> buildMemoryExport(String botId) async {
    final bot = await getBotById(botId);
    if (bot == null) throw StateError('机器人不存在');
    final work = await DataTransfer.workspace();
    try {
      final name =
          'tidebot_memory_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = File('${work.path}/$name');
      final sink = file.openWrite();
      try {
        sink.write(
          '{"format":"tidebot.memory","version":1,"bot":${jsonEncode({'id': botId, 'name': bot['name'], 'created_at': bot['created_at'], 'daily_quote': bot['daily_quote']})},',
        );
        final db = await database;
        await db.transaction((txn) async {
          for (final table in ['memories', 'kv_store']) {
            sink.write(table == 'memories' ? '"memories":[' : ',"kv":[');
            var offset = 0;
            var first = true;
            while (true) {
              final rows = await txn.query(
                table,
                where: table == 'memories'
                    ? 'bot_id = ?'
                    : 'key LIKE ? OR key LIKE ?',
                whereArgs: table == 'memories'
                    ? [botId]
                    : ['%_$botId', '%_${botId}_%'],
                orderBy: table == 'memories'
                    ? 'timestamp ASC, id ASC'
                    : 'key ASC',
                limit: 100,
                offset: offset,
              );
              if (rows.isEmpty) break;
              for (final row in rows) {
                if (!first) sink.write(',');
                first = false;
                sink.write(jsonEncode(row));
              }
              await sink.flush();
              offset += rows.length;
            }
            sink.write(']');
          }
        });
        sink.write('}');
      } finally {
        await sink.close();
      }
      return (fileName: name, file: file);
    } catch (_) {
      await work.delete(recursive: true);
      rethrow;
    }
  }

  Future<int> importBotMemory(
    String botId,
    String sourcePath, {
    bool merge = false,
  }) => DataTransfer.exclusive(() async {
    final source = File(sourcePath);
    String? format;
    int? version;
    Map bot = {};
    final sections = <String>{};
    const arrays = {'memories', 'kv'};
    await for (final record in JsonRecords.read(source, arrays: arrays)) {
      if (record.key == 'format') format = record.value as String?;
      if (record.key == 'version') version = record.value as int?;
      if (record.key == 'bot' && record.value is Map) bot = record.value as Map;
      if (arrays.contains(record.key)) {
        sections.add(record.key);
        if (record.element && record.value is! Map)
          throw const FormatException('世界书内容无效');
      }
    }
    if (format != 'tidebot.memory' || version != 1 || sections.length != 2) {
      throw const FormatException('仅支持 TideBot 导出的世界书文件');
    }
    final sourceBotId = bot['id']?.toString() ?? '';
    var count = 0;
    final base = DateTime.now().microsecondsSinceEpoch;
    final db = await database;
    await db.transaction((txn) async {
      if (!merge) {
        await txn.delete('memories', where: 'bot_id = ?', whereArgs: [botId]);
        await txn.delete(
          'kv_store',
          where: 'key LIKE ? OR key LIKE ?',
          whereArgs: ['%_$botId', '%_${botId}_%'],
        );
      }
      await for (final record in JsonRecords.read(source, arrays: arrays)) {
        if (!record.element) continue;
        final item = record.value as Map;
        if (record.key == 'memories') {
          final row = Map<String, dynamic>.from(item);
          row['bot_id'] = botId;
          row['id'] = 'import_mem_${base}_${count++}';
          await txn.insert(
            'memories',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } else if (record.key == 'kv' && item['key'] != null) {
          var key = item['key'].toString();
          if (sourceBotId.isNotEmpty) key = key.replaceAll(sourceBotId, botId);
          await txn.insert('kv_store', {
            'key': key,
            'value': item['value']?.toString(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      if (!merge) {
        await txn.update(
          'bots',
          {'created_at': bot['created_at'], 'daily_quote': bot['daily_quote']},
          where: 'id = ?',
          whereArgs: [botId],
        );
      }
    });
    return count;
  });

  Future<void> markBotRead(String botId) async {
    if (botId.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Assistant segments can be persisted a few milliseconds ahead of `now`.
    // Record the latest row actually visible in this room, otherwise that final
    // segment is incorrectly counted as unread immediately after leaving.
    final rows = await db.rawQuery(
      '''
      SELECT COALESCE(MAX(timestamp), 0) AS latest FROM chat_history
      WHERE bot_id = ? AND role = 'assistant'
    ''',
      [botId],
    );
    final latest = (rows.first['latest'] as num?)?.toInt() ?? 0;
    await db.update(
      'bots',
      {'last_read_at': latest > now ? latest : now},
      where: 'id = ?',
      whereArgs: [botId],
    );
    ChatEventBus.instance.publish(
      ChatEvent(type: ChatEventType.read, botId: botId),
    );
  }

  // 旧版全量 Markdown 导出保留兼容，不再作为数据管理入口。
  Future<void> exportToMarkdown() => DataTransfer.exclusive(() async {
    final db = await database;
    final dir = await getDatabasesPath();
    final file = File('$dir/tidebot_export.md');
    final sink = file.openWrite();
    try {
      sink.writeln('# TideBot 数据导出');
      sink.writeln('导出时间: ${DateTime.now()}');
      await db.transaction((txn) async {
        for (final bot in await txn.query('bots')) {
          sink.writeln('## ${bot['name']}');
          sink.writeln('> ${bot['desc']}');
          var offset = 0;
          while (true) {
            final page = await txn.query(
              'chat_history',
              where: 'bot_id = ?',
              whereArgs: [bot['id']],
              orderBy: 'timestamp ASC, id ASC',
              limit: 100,
              offset: offset,
            );
            if (page.isEmpty) break;
            for (final message in page) {
              final role = message['role'] == 'user' ? '用户' : bot['name'];
              sink.writeln('**$role**: ${message['content']}\n');
            }
            await sink.flush();
            offset += page.length;
          }
        }
      });
    } finally {
      await sink.close();
    }
  });
  // 添加 path 依赖的导入需要确认已存在; File 来自 dart:io
  // 需要在文件顶部已 import 'dart:io';

  // 别名：新代码统一用 queryBots
  Future<List<Map<String, dynamic>>> queryBots({
    bool throwOnError = false,
  }) async => getAllBots(throwOnError: throwOnError);

  // 别名：新代码用 insertMessage
  Future<void> insertMessage(Map<String, dynamic> msg) async =>
      insertChatMessage(msg);

  // 别名：新代码用 queryMessages，支持可选 limit 与倒序
  Future<List<Map<String, dynamic>>> queryMessages(
    String botId, {
    int? limit,
    bool descending = false,
  }) async {
    final db = await database;
    final orderBy = descending
        ? 'timestamp DESC, id DESC'
        : 'timestamp ASC, id ASC';
    try {
      return await db.query(
        'chat_history',
        where: "bot_id = ? AND (type IS NULL OR type != 'call_summary')",
        whereArgs: [botId],
        orderBy: orderBy,
        limit: limit,
      );
    } catch (error) {
      print('[db] queryMessages typed query failed: $error');
      try {
        return await db.query(
          'chat_history',
          where: 'bot_id = ?',
          whereArgs: [botId],
          orderBy: orderBy,
          limit: limit,
        );
      } catch (fallbackError) {
        print('[db] queryMessages fallback failed: $fallbackError');
        return const [];
      }
    }
  }

  /// Shared daily totals for the dashboard and each bot's sidebar.
  /// Token usage includes every recorded request, including proactive chat.
  /// Replies count delivered text messages rather than model requests (which
  /// may choose silence or produce several message bubbles).
  Future<List<Map<String, Object?>>> dailyUsageStats({
    String? botId,
    int since = 0,
  }) async {
    final db = await database;
    final botFilter = botId == null ? '' : 'AND bot_id = ?';
    final args = <Object?>[since, if (botId != null) botId];
    return db.rawQuery(
      '''
      SELECT MIN(timestamp) AS timestamp,
             SUM(total_tokens) AS total_tokens,
             SUM(reply_count) AS reply_count
      FROM (
        SELECT timestamp, total_tokens, 0 AS reply_count
        FROM ai_usage_events WHERE timestamp >= ? $botFilter
        UNION ALL
        SELECT timestamp, 0 AS total_tokens, 1 AS reply_count
        FROM chat_history
        WHERE timestamp >= ? $botFilter
          AND role = 'assistant' AND type = 'text'
          AND COALESCE(error_log, '') = ''
          AND COALESCE(error_code, '') = ''
      )
      GROUP BY strftime('%Y-%m-%d', timestamp / 1000, 'unixepoch', 'localtime')
      ORDER BY timestamp
    ''',
      [...args, ...args],
    );
  }

  /// Daily assistant replies and recorded model usage for the chat sidebar.
  Future<Map<String, int>> todayBotStats(String botId) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final rows = await dailyUsageStats(botId: botId, since: start);
    return {
      'messages': rows.fold<int>(
        0,
        (sum, row) => sum + ((row['reply_count'] as num?)?.toInt() ?? 0),
      ),
      'tokens': rows.fold<int>(
        0,
        (sum, row) => sum + ((row['total_tokens'] as num?)?.toInt() ?? 0),
      ),
    };
  }

  // 别名：新代码用 deleteMessages (清空聊天)
  Future<void> deleteMessages(String botId) async => clearChatHistory(botId);

  // 查询日程 (schedule_tasks 表)
  Future<List<Map<String, dynamic>>> querySchedules(
    String botId, {
    int? limit,
  }) async {
    final db = await database;
    return await db.query(
      'schedule_tasks',
      where: 'bot_id = ?',
      whereArgs: [botId],
      orderBy: 'time ASC',
      limit: limit,
    );
  }

  Future<void> insertFutureTask(Map<String, dynamic> task) async {
    final db = await database;
    await db.insert(
      'schedule_tasks',
      task,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // 读取后台消息（Kotlin 写入的主动回复等）
  Future<List<Map<String, dynamic>>> getBackgroundMessages(
    String botId, {
    bool onlyUnread = true,
  }) async {
    final db = await database;
    final where = onlyUnread ? 'bot_id = ? AND displayed = 0' : 'bot_id = ?';
    return db.query(
      'background_messages',
      where: where,
      whereArgs: [botId],
      orderBy: 'timestamp ASC',
    );
  }

  // 标记后台消息为已显示
  Future<void> markBackgroundMessageDisplayed(String messageId) async {
    final db = await database;
    await db.update(
      'background_messages',
      {'displayed': 1},
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  // 同步后台消息到聊天历史
  Future<void> syncBackgroundMessageToChat(
    String messageId,
    String chatMessageId,
  ) async {
    final db = await database;
    await db.update(
      'background_messages',
      {'synced_to_chat': 1},
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> deleteFutureTask(String id) async {
    final db = await database;
    await db.delete('schedule_tasks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateFutureTask(String id, Map<String, dynamic> values) async {
    final db = await database;
    await db.update('schedule_tasks', values, where: 'id = ?', whereArgs: [id]);
  }

  /// Restores tasks stranded by a process kill or an expired execution lease.
  Future<int> recoverExpiredFutureTasks(int now, {int leaseMs = 180000}) async {
    final db = await database;
    return db.update(
      'schedule_tasks',
      {
        'status': 'pending',
        'locked_at': null,
        'retry_at': now,
        'last_error': '执行租约超时，已恢复重试',
      },
      where: "status = ? AND (locked_at IS NULL OR locked_at <= ?)",
      whereArgs: ['running', now - leaseMs],
    );
  }

  /// Atomically claims one runnable task. A conditional update makes claims safe
  /// when multiple service instances wake at the same time.
  Future<Map<String, dynamic>?> claimDueFutureTask(int now) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'schedule_tasks',
        where:
            "status = ? AND run_at <= ? AND (retry_at IS NULL OR retry_at <= ?)",
        whereArgs: ['pending', now, now],
        orderBy: 'run_at ASC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final task = rows.first;
      final id = task['id']?.toString() ?? '';
      if (id.isEmpty) return null;
      final changed = await txn.update(
        'schedule_tasks',
        {'status': 'running', 'locked_at': now},
        where:
            "id = ? AND status = 'pending' AND (retry_at IS NULL OR retry_at <= ?)",
        whereArgs: [id, now],
      );
      if (changed != 1) return null;
      return {...task, 'status': 'running', 'locked_at': now};
    });
  }

  Future<void> completeFutureTask(Map<String, dynamic> task, int now) async {
    final id = task['id']?.toString() ?? '';
    if (id.isEmpty) return;
    if (task['frequency']?.toString() != 'daily') {
      await deleteFutureTask(id);
      return;
    }
    final previous = DateTime.fromMillisecondsSinceEpoch(
      int.tryParse(task['run_at']?.toString() ?? '') ?? now,
    );
    final nextRun = DateTime(
      previous.year,
      previous.month,
      previous.day + 1,
      previous.hour,
      previous.minute,
    ).millisecondsSinceEpoch;
    await updateFutureTask(id, {
      'run_at': nextRun,
      'status': 'pending',
      'attempts': 0,
      'last_error': null,
      'retry_at': null,
      'locked_at': null,
    });
  }

  Future<void> retryFutureTask(
    Map<String, dynamic> task,
    Object error,
    int now, {
    int maxAttempts = 5,
  }) async {
    final id = task['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final attempts =
        (task['attempts'] as num?)?.toInt() ??
        int.tryParse(task['attempts']?.toString() ?? '') ??
        0;
    final nextAttempts = attempts + 1;
    final failed = nextAttempts >= maxAttempts;
    final exponent = (nextAttempts - 1).clamp(0, 6);
    final delaySeconds = 30 * (1 << exponent);
    await updateFutureTask(id, {
      'status': failed ? 'failed' : 'pending',
      'attempts': nextAttempts,
      'last_error': error.toString(),
      'retry_at': failed ? null : now + delaySeconds * 1000,
      'locked_at': null,
    });
  }

  Future<List<Map<String, dynamic>>> dueFutureTasks(int now) async {
    final db = await database;
    return db.query(
      'schedule_tasks',
      where:
          "run_at <= ? AND status = ? AND (retry_at IS NULL OR retry_at <= ?)",
      whereArgs: [now, 'pending', now],
      orderBy: 'run_at ASC',
    );
  }

  // 查询记忆 (memories 表)
  Future<List<Map<String, dynamic>>> queryMemories(
    String botId, {
    String? type,
    int? limit,
    bool includeExpired = false,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final whereParts = <String>['bot_id = ?', 'COALESCE(is_deleted, 0) = 0'];
    final whereArgs = <dynamic>[botId];
    if (type != null) {
      whereParts.add('type = ?');
      whereArgs.add(type);
    }
    if (!includeExpired) {
      whereParts.add(
        '(expires_at IS NULL OR expires_at <= 0 OR expires_at > ?)',
      );
      whereArgs.add(now);
    }
    return await db.query(
      'memories',
      where: whereParts.join(' AND '),
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC, id DESC',
      limit: limit,
    );
  }

  Future<List<Map<String, dynamic>>> queryMemoriesRelevant(
    String botId,
    String query, {
    int limit = 8,
    bool includeExpired = false,
  }) async {
    final tokens = _memorySearchTokens(query);
    if (tokens.isEmpty) return queryMemories(botId, limit: limit);
    final candidates = await queryMemories(
      botId,
      includeExpired: includeExpired,
    );
    final scored = <Map<String, dynamic>>[];
    for (final row in candidates) {
      final haystack = '${row['title'] ?? ''} ${row['content'] ?? ''}'
          .toLowerCase();
      var hits = 0;
      for (final token in tokens) {
        if (haystack.contains(token)) hits++;
      }
      if (hits == 0) continue;
      final importance = (row['importance'] as num?)?.toInt() ?? 3;
      final score =
          hits * 100 +
          importance * 8 +
          ((row['type']?.toString() == 'long') ? 12 : 0);
      final copy = Map<String, dynamic>.from(row)..['_relevance'] = score;
      scored.add(copy);
    }
    scored.sort(
      (a, b) => (b['_relevance'] as int).compareTo(a['_relevance'] as int),
    );
    return scored.take(limit).map((row) {
      final copy = Map<String, dynamic>.from(row)..remove('_relevance');
      return copy;
    }).toList();
  }

  List<String> _memorySearchTokens(String query) {
    final normalized = query.toLowerCase().replaceAll(
      RegExp(r'[^\u3400-\u9fff\w]+'),
      ' ',
    );
    final tokens = <String>{};
    for (final word in normalized.split(RegExp(r'\s+'))) {
      if (word.length >= 2) tokens.add(word);
    }
    for (var i = 0; i < normalized.length - 1; i++) {
      final pair = normalized.substring(i, i + 2).trim();
      if (pair.length == 2 &&
          pair.runes.every((r) => r >= 0x3400 && r <= 0x9fff)) {
        tokens.add(pair);
      }
    }
    return tokens.toList();
  }

  Future<List<Map<String, dynamic>>> queryDiaryDates(
    String botId, {
    String? fromDate,
    String? toDate,
  }) async {
    final db = await database;
    final where = <String>['bot_id = ?'];
    final args = <dynamic>[botId];
    if (fromDate != null) {
      where.add('date_key >= ?');
      args.add(fromDate);
    }
    if (toDate != null) {
      where.add('date_key <= ?');
      args.add(toDate);
    }
    return db.query(
      'bot_diaries',
      columns: ['date_key'],
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'date_key ASC',
    );
  }

  Future<Map<String, dynamic>?> getDiary(String botId, String dateKey) async {
    final db = await database;
    final rows = await db.query(
      'bot_diaries',
      where: 'bot_id = ? AND date_key = ?',
      whereArgs: [botId, dateKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> deleteDiary(String botId, String dateKey) async {
    final db = await database;
    await db.delete(
      'bot_diaries',
      where: 'bot_id = ? AND date_key = ?',
      whereArgs: [botId, dateKey],
    );
  }

  Future<void> upsertDiary({
    required String botId,
    required String dateKey,
    required String content,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await getDiary(botId, dateKey);
    final db = await database;
    await db.insert('bot_diaries', {
      'id': existing?['id']?.toString() ?? 'diary_${botId}_$dateKey',
      'bot_id': botId,
      'date_key': dateKey,
      'content': content.trim(),
      'created_at': existing?['created_at'] ?? now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> queryDiaryRange(
    String botId,
    String fromDate,
    String toDate,
  ) async {
    final db = await database;
    return db.query(
      'bot_diaries',
      where: 'bot_id = ? AND date_key >= ? AND date_key <= ?',
      whereArgs: [botId, fromDate, toDate],
      orderBy: 'date_key ASC',
    );
  }

  Future<void> _ensureVoiceCallStorage(Database db) async {
    await db.transaction((txn) async {
      await ensureVoiceCallSchema(txn);
      final columns = await _tableColumns(txn, 'chat_history');
      for (final entry in const {
        'call_id': 'TEXT',
        'call_status': 'TEXT',
        'call_duration': 'INTEGER DEFAULT 0',
        'duration': 'INTEGER',
      }.entries) {
        if (!columns.contains(entry.key)) {
          await txn.execute(
            'ALTER TABLE chat_history ADD COLUMN ${entry.key} ${entry.value}',
          );
        }
      }
    });
  }

  // ========== 语音通话记录 ==========

  /// 保存通话记录
  Future<void> saveVoiceCallRecord(Map<String, dynamic> record) async {
    final db = await database;
    await _ensureVoiceCallStorage(db);
    await db.insert(
      'voice_call_records',
      record,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取通话记录
  Future<Map<String, dynamic>?> getVoiceCallRecord(String callId) async {
    final db = await database;
    await _ensureVoiceCallStorage(db);
    final rows = await db.query(
      'voice_call_records',
      where: 'id = ?',
      whereArgs: [callId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 查询机器人的通话记录列表
  Future<List<Map<String, dynamic>>> queryVoiceCallRecords(
    String botId, {
    int limit = 50,
  }) async {
    final db = await database;
    await _ensureVoiceCallStorage(db);
    return db.query(
      'voice_call_records',
      where: 'bot_id = ?',
      whereArgs: [botId],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }

  /// 更新通话记录状态
  Future<void> updateVoiceCallStatus(
    String callId,
    String status,
    int duration,
  ) async {
    final db = await database;
    await _ensureVoiceCallStorage(db);
    await db.update(
      'voice_call_records',
      {'status': status, 'duration': duration},
      where: 'id = ?',
      whereArgs: [callId],
    );
  }

  /// 更新通话摘要
  Future<void> updateVoiceCallSummary(
    String callId,
    String summary,
    String transcript,
  ) async {
    final db = await database;
    await _ensureVoiceCallStorage(db);
    await db.update(
      'voice_call_records',
      {'summary': summary, 'transcript': transcript},
      where: 'id = ?',
      whereArgs: [callId],
    );
  }

  Future<bool> claimBackgroundJob(
    String key, {
    Duration lease = const Duration(minutes: 30),
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'kv_store',
        where: 'key = ?',
        whereArgs: ['job_lease_$key'],
      );
      final until = rows.isEmpty
          ? 0
          : int.tryParse(rows.first['value']?.toString() ?? '') ?? 0;
      if (until > now) return false;
      await txn.insert('kv_store', {
        'key': 'job_lease_$key',
        'value': '${now + lease.inMilliseconds}',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  Future<void> releaseBackgroundJob(String key) async {
    await setKV('job_lease_$key', '0');
  }

  Future<List<String>> memoryCategories() async {
    final db = await database;
    final rows = await db.query(
      'kv_store',
      where: 'key LIKE ?',
      whereArgs: ['wb_category_%'],
    );
    final used = await db.rawQuery('SELECT DISTINCT category FROM memories');
    return <String>{
      '记忆',
      '事件',
      '日程',
      '人物',
      '规则',
      '偏好',
      '角色眼中的你',
      '角色的自我认知',
      '关系',
      ...rows.map((r) => r['key'].toString().substring('wb_category_'.length)),
      ...used
          .map((r) => r['category']?.toString() ?? '')
          .where((s) => s.isNotEmpty && s != 'fact'),
    }.toList();
  }

  Future<void> insertMemory(Map<String, dynamic> memory) async {
    final db = await database;
    await db.insert(
      'memories',
      memory,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 新记忆按条写入前做轻量去重：同一机器人、同一层级内的相同内容不重复占用。
  /// 相近内容保留最新一条，避免短期记忆越积越多。
  Future<void> upsertMemoryItem({
    required String botId,
    required String type,
    required String content,
    String? id,
    String title = '',
    String category = '记忆',
    int? importance,
    List<String>? keys,
    int? expiresAt,
    int? timestamp,
  }) async {
    final normalized = content.replaceAll(RegExp(r'\s+'), '').trim();
    if (normalized.isEmpty) return;
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final existing = await queryMemories(botId, type: type);
    Map<String, dynamic>? duplicate;
    for (final item in existing) {
      // Similar wording in a profile and an event does not make them the same
      // entry. Never move or overwrite another category during deduplication.
      if (item['category'] != category) continue;
      final old = (item['content']?.toString() ?? '')
          .replaceAll(RegExp(r'\s+'), '')
          .trim();
      if (old == normalized ||
          (old.length >= 12 &&
              normalized.length >= 12 &&
              (old.contains(normalized) || normalized.contains(old)))) {
        duplicate = item;
        break;
      }
    }
    final targetId = (id ?? '').trim();
    if (targetId.isNotEmpty) {
      final oldRows = await queryMemories(botId, includeExpired: true);
      final old = oldRows.where((r) => r['id'] == targetId).firstOrNull;
      await insertMemory({
        'keys_json': keys == null
            ? (old?['keys_json'] ?? '[]')
            : jsonEncode(keys),
        'id': targetId,
        'bot_id': botId,
        'title': title,
        'type': type,
        'content': content.trim(),
        'category': category,
        'importance': (importance ?? (old?['importance'] as num?)?.toInt() ?? 3)
            .clamp(1, 5),
        'expires_at': expiresAt,
        'timestamp': now,
        'updated_at': now,
      });
    } else if (duplicate != null) {
      final previous = duplicate['content']?.toString().trim() ?? '';
      if (previous.replaceAll(RegExp(r'\s+'), '').contains(normalized)) {
        // Preserve the longer fact and its recency. Explicit metadata edits
        // still take effect without treating a repetition as a new event.
        final metadata = <String, dynamic>{};
        if (importance != null &&
            importance.clamp(1, 5) != duplicate['importance']) {
          metadata['importance'] = importance.clamp(1, 5);
        }
        if (keys != null && jsonEncode(keys) != duplicate['keys_json']) {
          metadata['keys_json'] = jsonEncode(keys);
        }
        if (metadata.isNotEmpty) {
          metadata['updated_at'] = now;
          await updateMemory(duplicate['id'].toString(), metadata);
        }
        return;
      }
      if (previous != content.trim()) {
        await updateMemory(duplicate['id'].toString(), {
          'title': title.isEmpty ? duplicate['title'] : title,
          if (keys != null) 'keys_json': jsonEncode(keys),
          'content': content.trim(),
          'category': category,
          'importance':
              (importance ?? (duplicate['importance'] as num?)?.toInt() ?? 3)
                  .clamp(1, 5),
          'expires_at': expiresAt,
          'timestamp': now,
          'updated_at': now,
        });
      }
    } else {
      await insertMemory({
        'id': 'mem_${botId}_${now}_${normalized.hashCode.abs()}',
        'keys_json': jsonEncode(keys ?? <String>[]),
        'bot_id': botId,
        'title': title,
        'type': type,
        'content': content.trim(),
        'category': category,
        'importance': (importance ?? 3).clamp(1, 5),
        'expires_at': expiresAt,
        'timestamp': now,
        'updated_at': now,
      });
    }
    const caps = {'long': 60, 'short': 100};
    final cap = caps[type] ?? 80;
    final rows = (await queryMemories(botId, type: type))
        .where(
          (row) => !const [
            '角色眼中的你',
            '角色的自我认知',
            '关系',
            '角色档案',
          ].contains(row['category']),
        )
        .toList();
    rows.sort((a, b) {
      final importance = ((b['importance'] as num?) ?? 3).compareTo(
        (a['importance'] as num?) ?? 3,
      );
      return importance != 0
          ? importance
          : ((b['timestamp'] as num?) ?? 0).compareTo(
              (a['timestamp'] as num?) ?? 0,
            );
    });
    if (rows.length > cap) {
      for (final item in rows.skip(cap)) {
        await deleteMemory(item['id'].toString());
      }
    }
  }

  Future<void> applyCognitionUpdates(
    String botId,
    Map<String, String> updates,
  ) async {
    const categories = ['角色眼中的你', '角色的自我认知', '关系'];
    if (updates.keys.any((key) => !categories.contains(key)) ||
        updates.values.any((value) => value.trim().isEmpty)) {
      throw const FormatException('认知更新类别或内容无效');
    }
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      for (final entry in updates.entries) {
        final rows = await txn.query(
          'memories',
          where: 'bot_id = ? AND category = ?',
          whereArgs: [botId, entry.key],
          orderBy: 'timestamp DESC',
        );
        final values = <String, dynamic>{
          'bot_id': botId,
          'title': entry.key,
          'category': entry.key,
          'type': 'long',
          'content': entry.value.trim(),
          'importance': 5,
          'expires_at': null,
          'timestamp': now,
          'updated_at': now,
        };
        if (rows.isEmpty) {
          await txn.insert('memories', {
            ...values,
            'id': 'cognition_${botId}_${entry.key}_$now',
          });
        } else {
          await txn.update(
            'memories',
            values,
            where: 'id = ?',
            whereArgs: [rows.first['id']],
          );
          for (final duplicate in rows.skip(1)) {
            await txn.delete(
              'memories',
              where: 'id = ?',
              whereArgs: [duplicate['id']],
            );
          }
        }
      }
    });
  }

  Future<void> updateMemory(String id, Map<String, dynamic> values) async {
    final db = await database;
    await db.update('memories', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMemory(String id) async {
    final db = await database;
    await db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  // 删除指定机器人的记忆
  Future<void> deleteMemories(String botId) async => clearMemories(botId);

  // 别名：新代码用 insertKV
  Future<void> insertKV(String key, String value) async => setKV(key, value);

  // ================= Provider 管理 (兼容新旧接口) =================

  // 新接口：insertProvider(name, url, key)
  Future<void> insertProviderNew(String name, String url, String apiKey) async {
    final existing = await getProvidersByType('chat');
    // 新配置追加保存，不覆盖已有同名 provider
    existing.add({
      'id': 'provider_chat_${DateTime.now().microsecondsSinceEpoch}',
      'type': 'chat',
      'name': name,
      'base_url': url,
      'api_key': apiKey,
    });
    await setKV('providers_chat', jsonEncode(existing));
  }

  // 旧接口兼容
  Future<void> insertProvider(Map<String, dynamic> provider) async {
    final existing = await getProvidersByType(provider['type'] ?? 'chat');
    existing.add(provider);
    await setKV('providers_${provider['type']}', jsonEncode(existing));
  }

  // 查询所有 chat 类型的 provider
  Future<List<Map<String, dynamic>>> queryProviders() async {
    return await getProvidersByType('chat');
  }

  // 清空所有 provider (chat 类型)
  Future<void> deleteProviders() async {
    await setKV('providers_chat', '[]');
  }

  Future<List<Map<String, dynamic>>> getProvidersByType(String type) async {
    final data = await getKV('providers_$type');
    if (data == null) return [];
    List<dynamic> list = jsonDecode(data);
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  Future<Map<String, dynamic>?> getProviderById(String id) async {
    final chatProviders = await getProvidersByType('chat');
    try {
      return chatProviders.firstWhere((p) => p['id'] == id);
    } catch (e) {
      return null;
    }
  }

  // ============ 统一聊天链路 provider 读取 ============
  // API设置页把模型提供商存在 'provider_list'（字段: name/url/key/model），
  // 而聊天/ai.dart 需要 {id,type,name,base_url,api_key,model} 结构。
  // 这里做转换适配，保证「API设置里配的模型」能被聊天真正用上。
  Future<List<Map<String, dynamic>>> queryChatProviders() async {
    final data = await getKV('provider_list');
    if (data == null || data.isEmpty) return [];
    List<Map<String, dynamic>> result = [];
    try {
      final decoded = jsonDecode(data) as List;
      for (var e in decoded) {
        final m = e as Map<String, dynamic>;
        result.add({
          'id': m['id']?.toString().isNotEmpty == true
              ? m['id'].toString()
              : 'legacy_p_${m['name']}_${m['url']}_${m['model']}',
          'type': 'chat',
          'name': m['name'] ?? '',
          'base_url': m['url'] ?? '',
          'api_key': m['key'] ?? '',
          'model': m['model'] ?? '',
          'thinking_mode': m['thinking_mode'] == true,
          'reasoning_effort': m['reasoning_effort'] ?? 'medium',
        });
      }
    } catch (_) {}
    return result;
  }

  Future<Map<String, dynamic>?> getChatProviderById(String id) async {
    final list = await queryChatProviders();
    try {
      return list.firstWhere((p) => p['id'] == id);
    } catch (e) {
      return null;
    }
  }

  // STT is deliberately independent from chat providers. A chat endpoint is
  // often OpenAI-compatible for completions but has no transcription route.
  Future<List<Map<String, dynamic>>> querySttProviders() async {
    final data = await getKV('stt_provider_list');
    if (data == null || data.isEmpty) return [];
    try {
      final decoded = jsonDecode(data) as List;
      return decoded.whereType<Map>().map((raw) {
        final m = Map<String, dynamic>.from(raw);
        return {
          'id': m['id']?.toString().isNotEmpty == true
              ? m['id'].toString()
              : 'stt_${m['name'] ?? m['url']}',
          'type': 'stt',
          'name': m['name'] ?? '',
          'base_url': m['url'] ?? m['base_url'] ?? '',
          'api_key': m['key'] ?? m['api_key'] ?? '',
          'model': m['model'] ?? '',
          'protocol': m['protocol'] ?? 'openai',
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> getSttProviderById(String id) async {
    final list = await querySttProviders();
    try {
      return list.firstWhere((p) => p['id'] == id);
    } catch (_) {
      return null;
    }
  }

  // ============ 统一 TTS 链路 provider 读取 ============
  // API 设置页把 TTS 提供商也存在 'tts_provider_list'（字段: name/url/key/model/voice）
  Future<List<Map<String, dynamic>>> queryTtsProviders() async {
    final data = await getKV('tts_provider_list');
    if (data == null || data.isEmpty) return [];
    List<Map<String, dynamic>> result = [];
    try {
      final decoded = jsonDecode(data) as List;
      for (var e in decoded) {
        final m = e as Map<String, dynamic>;
        result.add({
          'id': m['id']?.toString().isNotEmpty == true
              ? m['id'].toString()
              : 'ts_${m['name']}',
          'type': 'tts',
          'name': m['name'] ?? '',
          'base_url': m['url'] ?? '',
          'api_key': m['key'] ?? '',
          'model': m['model'] ?? '',
          'voice': m['voice'] ?? '',
          'mimo_clone': m['mimo_clone'],
          'protocol': m['protocol'] ?? 'openai',
          'supports_instructions': m['supports_instructions'] == true,
        });
      }
    } catch (_) {}
    return result;
  }

  // ================= Posts 查询（广场分页） =================
  Future<List<Map<String, dynamic>>> queryPosts({
    int offset = 0,
    int limit = 10,
    String? authorId,
  }) async {
    final db = await database;
    try {
      return await db.query(
        'posts',
        where: authorId == null ? null : 'author_id = ?',
        whereArgs: authorId == null ? null : [authorId],
        orderBy: 'timestamp DESC',
        limit: limit,
        offset: offset,
      );
    } catch (error) {
      print('[db] queryPosts failed: $error');
      return const [];
    }
  }

  /// New posts use the stable bot ID. Older releases stored the bot name, so
  /// callers can keep showing legacy posts while bots are renamed over time.
  Future<List<Map<String, dynamic>>> queryPostsForBot({
    required String botId,
    required String botName,
    int limit = 10,
  }) async {
    final db = await database;
    try {
      return await db.query(
        'posts',
        where: 'author_id = ? OR author_id = ?',
        whereArgs: [botId, botName],
        orderBy: 'timestamp DESC',
        limit: limit,
      );
    } catch (error) {
      print('[db] queryPostsForBot failed: $error');
      try {
        return await db.query(
          'posts',
          where: 'author_id = ? OR author_id = ?',
          whereArgs: [botId, botName],
          limit: limit,
        );
      } catch (fallbackError) {
        print('[db] queryPostsForBot fallback failed: $fallbackError');
        return const [];
      }
    }
  }

  Future<Map<String, dynamic>?> getPostById(String postId) async {
    final id = postId.trim();
    if (id.isEmpty) return null;
    final db = await database;
    try {
      final rows = await db.query(
        'posts',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
    } catch (error) {
      print('[db] getPostById failed: $error');
      return null;
    }
  }

  Future<void> insertPost(Map<String, dynamic> post) async {
    final db = await database;
    await db.insert(
      'posts',
      post,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updatePostLikes(String postId, int likes) async {
    final db = await database;
    await db.update(
      'posts',
      {'likes': likes},
      where: 'id = ?',
      whereArgs: [postId],
    );
  }

  Future<void> updatePostComments(String postId, int comments) async {
    final db = await database;
    await db.update(
      'posts',
      {'comments': comments},
      where: 'id = ?',
      whereArgs: [postId],
    );
  }

  Future<void> updatePostUserState(
    String postId, {
    required bool liked,
    required bool collected,
  }) async {
    final db = await database;
    await db.update(
      'posts',
      {'user_liked': liked ? 1 : 0, 'user_collected': collected ? 1 : 0},
      where: 'id = ?',
      whereArgs: [postId],
    );
  }

  Future<List<Map<String, dynamic>>> queryPostComments(String postId) async {
    final db = await database;
    return db.query(
      'post_comments',
      where: 'post_id = ?',
      whereArgs: [postId],
      orderBy: 'timestamp ASC',
    );
  }

  Future<void> insertPostComment(Map<String, dynamic> comment) async {
    final db = await database;
    await db.insert('post_comments', comment);
  }

  Future<void> deletePostComment(String commentId) async {
    final db = await database;
    await db.delete('post_comments', where: 'id = ?', whereArgs: [commentId]);
  }

  Future<void> deletePost(String postId) async {
    final db = await database;
    await db.delete('posts', where: 'id = ?', whereArgs: [postId]);
  }

  /// Records a feed action only once for the same actor and post.
  Future<bool> recordFeedEvent({
    required String postId,
    required String actorId,
    required String eventType,
  }) async {
    final db = await database;
    try {
      await db.insert('feed_events', {
        'id': 'fe_${postId}_${actorId}_$eventType',
        'post_id': postId,
        'actor_id': actorId,
        'event_type': eventType,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      return true;
    } on DatabaseException {
      return false;
    }
  }

  Future<bool> hasFeedEvent({
    required String postId,
    required String actorId,
    required String eventType,
  }) async {
    final db = await database;
    final rows = await db.query(
      'feed_events',
      where: 'post_id = ? AND actor_id = ? AND event_type = ?',
      whereArgs: [postId, actorId, eventType],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 删除一条互动事件（用于取消点赞 / 取消收藏）。
  Future<void> deleteFeedEvent({
    required String postId,
    required String actorId,
    required String eventType,
  }) async {
    final db = await database;
    await db.delete(
      'feed_events',
      where: 'post_id = ? AND actor_id = ? AND event_type = ?',
      whereArgs: [postId, actorId, eventType],
    );
  }

  /// 用户的点赞 / 收藏是切换行为：已存在则取消（删除事件），不存在则新增。
  /// 返回切换后是否处于“已点赞 / 已收藏”状态。
  Future<bool> toggleFeedEvent({
    required String postId,
    required String actorId,
    required String eventType,
  }) async {
    final existed = await hasFeedEvent(
      postId: postId,
      actorId: actorId,
      eventType: eventType,
    );
    if (existed) {
      await deleteFeedEvent(
        postId: postId,
        actorId: actorId,
        eventType: eventType,
      );
      return false;
    }
    await recordFeedEvent(
      postId: postId,
      actorId: actorId,
      eventType: eventType,
    );
    return true;
  }

  /// 统计某条动态的真实点赞数（来自 feed_events 中的 like / collect 互动的去重计数）。
  Future<int> countPostLikes(String postId) async {
    final db = await database;
    final likeRows = await db.query(
      'feed_events',
      where: 'post_id = ? AND event_type = ?',
      whereArgs: [postId, 'like'],
    );
    return likeRows.length;
  }

  /// 统计某条动态的真实评论数（来自 post_comments）。
  Future<int> countPostComments(String postId) async {
    final db = await database;
    final rows = await db.query(
      'post_comments',
      where: 'post_id = ?',
      whereArgs: [postId],
    );
    return rows.length;
  }

  /// 记录一条真实评论（由机器人生成），并去重插入 feed_events 的 comment 事件。
  Future<void> insertRealPostComment({
    required String postId,
    required String authorId,
    required String content,
    String? parentId,
    int? timestamp,
  }) async {
    final db = await database;
    final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final id = 'rc_${postId}_${authorId}_$now';
    await db.insert('post_comments', {
      'id': id,
      'post_id': postId,
      'author_id': authorId,
      'content': content,
      'parent_id': parentId,
      'timestamp': now,
    });
    try {
      await db.insert('feed_events', {
        'id': 'fe_${postId}_${authorId}_comment',
        'post_id': postId,
        'actor_id': authorId,
        'event_type': 'comment',
        'timestamp': now,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
    } on DatabaseException {
      // 同一机器人对同一条动态只计一次互动事件。
    }
  }

  Future<void> recordAiUsage({
    required String botId,
    required String eventType,
    required int promptTokens,
    required int completionTokens,
    required int totalTokens,
    int replyCount = 1,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('ai_usage_events', {
      'id': 'usage_${now}_${botId}_$eventType',
      'bot_id': botId,
      'event_type': eventType,
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'total_tokens': totalTokens,
      'reply_count': replyCount,
      'timestamp': now,
    });
  }

  // 更新 bots.last_msg_time
  Future<void> updateBotLastMsgTime(String botId, int time) async {
    final db = await database;
    await db.update(
      'bots',
      {'last_msg_time': time},
      where: 'id = ?',
      whereArgs: [botId],
    );
  }

  // 置顶/取消置顶
  Future<void> toggleBotPin(String botId, int isPinned) async {
    final db = await database;
    await db.update(
      'bots',
      {'is_pinned': isPinned},
      where: 'id = ?',
      whereArgs: [botId],
    );
  }

  // ========== 语音通话记录 ==========

  /// 插入语音通话记录
  Future<void> insertVoiceCallRecord({
    required String callId,
    required String botId,
    required String initiator,
    required String status,
    required String transcript,
    required String summary,
    required DateTime startTime,
    required DateTime endTime,
    Map<String, dynamic>? chatMessage,
  }) async {
    final db = await database;
    await _ensureVoiceCallStorage(db);
    await db.transaction((txn) async {
      if (status == 'ringing') {
        final cutoff = DateTime.now()
            .subtract(const Duration(minutes: 2))
            .millisecondsSinceEpoch;
        await txn.rawUpdate(
          "UPDATE chat_history SET call_status = 'timeout', content = '[语音通话，超时未接通]' WHERE call_id IN (SELECT id FROM voice_call_records WHERE status = 'ringing' AND start_time <= ?)",
          [cutoff],
        );
        await txn.rawUpdate(
          "UPDATE voice_call_records SET status = 'timeout', end_time = ? WHERE status = 'ringing' AND start_time <= ?",
          [DateTime.now().millisecondsSinceEpoch, cutoff],
        );
        final existing = await txn.query(
          'voice_call_records',
          columns: ['id'],
          where: "status IN ('ringing', 'active')",
          limit: 1,
        );
        if (existing.isNotEmpty) throw StateError('已有等待接听或进行中的通话');
      }
      await txn.insert('voice_call_records', {
        'id': callId,
        'bot_id': botId,
        'initiator': initiator,
        'status': status,
        'transcript': transcript,
        'summary': summary,
        'start_time': startTime.millisecondsSinceEpoch,
        'end_time': endTime.millisecondsSinceEpoch,
        'timestamp': endTime.millisecondsSinceEpoch,
        'duration': endTime.difference(startTime).inSeconds,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (chatMessage != null) {
        await txn.insert(
          'chat_history',
          chatMessage,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (!ChatEventBus.instance.foregroundOwner) {
          await txn.insert(
            'foreground_message_events',
            {'message_id': chatMessage['id']},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await txn.update(
          'bots',
          {'last_msg_time': chatMessage['timestamp']},
          where: 'id = ?',
          whereArgs: [botId],
        );
      }
    });
    // A visible card always has a committed detail record, even if the app exits
    // before summary generation finishes.
    if (chatMessage != null) {
      await _publishMessageEvent(
        chatMessage['id'].toString(),
        ChatEventType.inserted,
      );
    }
  }

  /// 更新语音通话记录
  Future<void> updateVoiceCallRecord(
    String callId, {
    String? status,
    String? transcript,
    String? summary,
    DateTime? endTime,
  }) async {
    final db = await database;
    await _ensureVoiceCallStorage(db);
    final updates = <String, dynamic>{};
    if (status != null) updates['status'] = status;
    if (transcript != null) updates['transcript'] = transcript;
    if (summary != null) updates['summary'] = summary;
    if (endTime != null) updates['end_time'] = endTime.millisecondsSinceEpoch;

    if (updates.isNotEmpty) {
      await db.update(
        'voice_call_records',
        updates,
        where: 'id = ?',
        whereArgs: [callId],
      );
    }
  }

  /// 更新聊天消息
  Future<void> updateChatMessage(
    String messageId, {
    String? content,
    String? callStatus,
  }) async {
    final db = await database;
    final updates = <String, dynamic>{};
    if (content != null) updates['content'] = content;
    if (callStatus != null) updates['call_status'] = callStatus;

    if (updates.isNotEmpty) {
      await db.update(
        'chat_history',
        updates,
        where: 'id = ?',
        whereArgs: [messageId],
      );
      await _publishMessageEvent(messageId, ChatEventType.updated);
    }
  }

  /// 获取机器人数据（用于工具调用）
  Future<Map<String, dynamic>?> getBotData(String botId) async {
    final db = await database;
    final results = await db.query(
      'bots',
      where: 'id = ?',
      whereArgs: [botId],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }
}
