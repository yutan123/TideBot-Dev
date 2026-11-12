import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tide_bot/plugin_install_journal.dart';

int checks = 0;
void check(bool value) {
  if (!value) throw StateError('Recovery check ${checks + 1} failed');
  checks++;
}

Future<void> main() async {
  final base = await Directory.systemTemp.createTemp('tide-journal-');
  try {
    for (var phase = 0; phase < 5; phase++) {
      final root = await Directory(p.join(base.path, 'update-$phase')).create();
      final rows = <Map<String, dynamic>>[
        {'id': 'test.plugin', 'updated_at': 1, 'manifest_json': 'old'},
      ];
      final recovery = PluginInstallJournal(
        queryRows: () async => rows,
        deleteRow: (_) async => rows.clear(),
        deleteData: (_) async {},
        invalidate: (_) async {},
      );
      final target = Directory(p.join(root.path, 'test.plugin'));
      final staging = Directory(
        p.join(root.path, 'test.plugin.installing-test'),
      );
      final backup = Directory(
        p.join(root.path, 'test.plugin.installing-test.backup'),
      );
      await target.create();
      await File(p.join(target.path, 'version')).writeAsString('old');
      await staging.create();
      await File(p.join(staging.path, 'version')).writeAsString('new');
      await recovery.write(root, {
        'op': 'install',
        'id': 'test.plugin',
        'staging': p.basename(staging.path),
        'backup': p.basename(backup.path),
        'existed': true,
        'marker': 2,
        'manifest': 'new',
      });
      if (phase >= 1) await target.rename(backup.path);
      if (phase >= 2) await staging.rename(target.path);
      if (phase >= 3)
        rows[0] = {
          'id': 'test.plugin',
          'updated_at': 2,
          'manifest_json': 'new',
        };
      if (phase >= 4) await backup.delete(recursive: true);
      await recovery.recover(root);
      check(
        await File(p.join(target.path, 'version')).readAsString() ==
            (phase >= 3 ? 'new' : 'old'),
      );
      check(!await staging.exists() && !await backup.exists());
      check(!await File(p.join(root.path, '.transaction.json')).exists());
      await recovery.recover(root);
      check(await target.exists());
    }
    final root = await Directory(p.join(base.path, 'fresh')).create();
    final target = await Directory(p.join(root.path, 'test.plugin')).create();
    var failData = true;
    var dataDeleted = false;
    var rowDeleted = false;
    var invalidated = false;
    final recovery = PluginInstallJournal(
      queryRows: () async => [],
      deleteRow: (_) async {
        rowDeleted = true;
      },
      deleteData: (_) async {
        if (failData) throw StateError('storage temporarily unavailable');
        dataDeleted = true;
      },
      invalidate: (_) async {
        invalidated = true;
      },
    );
    await recovery.write(root, {
      'op': 'install',
      'id': 'test.plugin',
      'staging': 'test.plugin.installing-test',
      'backup': 'test.plugin.installing-test.backup',
      'existed': false,
      'marker': 2,
      'manifest': 'new',
    });
    await recovery.recover(root);
    check(!await target.exists());
    await target.create();
    await recovery.write(root, {'op': 'delete', 'id': 'test.plugin'});
    try {
      await recovery.recover(root);
    } catch (_) {}
    check(await File(p.join(root.path, '.transaction.json')).exists());
    check(await target.exists() && !rowDeleted);
    failData = false;
    await recovery.recover(root);
    check(invalidated && dataDeleted && rowDeleted && !await target.exists());
    check(!await File(p.join(root.path, '.transaction.json')).exists());
    final pending = File(p.join(root.path, '.transaction.pending'));
    await pending.writeAsString('{interrupted');
    await recovery.recover(root);
    check(!await pending.exists());
    await recovery.write(root, {
      'op': 'install',
      'id': 'test.plugin',
      'staging': '../outside',
      'backup': 'test.plugin.backup',
      'existed': false,
    });
    var overwriteRejected = false;
    try {
      await recovery.write(root, {'op': 'delete', 'id': 'test.plugin'});
    } on StateError {
      overwriteRejected = true;
    }
    check(overwriteRejected);
    var rejected = false;
    try {
      await recovery.recover(root);
    } on FormatException {
      rejected = true;
    }
    check(
      rejected && await File(p.join(root.path, '.transaction.json')).exists(),
    );
    print('Plugin install journal: $checks checks passed');
  } finally {
    await base.delete(recursive: true);
  }
}
