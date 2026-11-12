import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:tide_bot/plugin_archive.dart';

// Builds real ZIP records to preserve duplicate names and inconsistent headers.
class Entry {
  final String name;
  final List<int> bytes;
  final int mode, method;
  final int? crc, declaredSize;
  final String? localName;
  Entry(
    this.name,
    this.bytes, {
    this.mode = 0x81a4,
    this.method = 0,
    this.crc,
    this.declaredSize,
    this.localName,
  });
}

List<int> zip(List<Entry> entries) {
  final body = OutputMemoryStream(), directory = OutputMemoryStream();
  for (final entry in entries) {
    final offset = body.length;
    final name = utf8.encode(entry.name);
    final local = utf8.encode(entry.localName ?? entry.name);
    final content = entry.method == 8
        ? ZLibCodec(raw: true).encode(entry.bytes)
        : entry.bytes;
    final crc = entry.crc ?? getCrc32(entry.bytes);
    final size = entry.declaredSize ?? entry.bytes.length;
    body.writeUint32(0x04034b50);
    for (final value in [20, 0, entry.method, 0, 0]) {
      body.writeUint16(value);
    }
    for (final value in [crc, content.length, size]) {
      body.writeUint32(value);
    }
    body.writeUint16(local.length);
    body.writeUint16(0);
    body.writeBytes(local);
    body.writeBytes(content);
    directory.writeUint32(0x02014b50);
    for (final value in [0x0314, 20, 0, entry.method, 0, 0]) {
      directory.writeUint16(value);
    }
    for (final value in [crc, content.length, size]) {
      directory.writeUint32(value);
    }
    for (final value in [name.length, 0, 0, 0, 0]) {
      directory.writeUint16(value);
    }
    directory.writeUint32(entry.mode << 16);
    directory.writeUint32(offset);
    directory.writeBytes(name);
  }
  final offset = body.length;
  body.writeBytes(directory.getBytes());
  body.writeUint32(0x06054b50);
  for (final value in [0, 0, entries.length, entries.length]) {
    body.writeUint16(value);
  }
  body.writeUint32(directory.length);
  body.writeUint32(offset);
  body.writeUint16(0);
  return body.getBytes();
}

Future<void> main() async {
  var checks = 0;
  final manifest = <String, dynamic>{
    'id': 'test.contract',
    'name': 'Package contract fixture',
    'version': '1.0.0',
    'entry': 'main.js',
  };
  List<Entry> base([Map<String, dynamic>? changes]) => [
    Entry('manifest.json', utf8.encode(jsonEncode({...manifest, ...?changes}))),
    Entry('main.js', utf8.encode('// infrastructure test fixture')),
  ];
  void accepts(List<Entry> entries) {
    final result = PluginArchive.decode(zip(entries));
    if (result.manifest['id'] != manifest['id'])
      throw StateError('Manifest lost');
    checks++;
  }

  void rejects(List<Entry> entries) {
    try {
      PluginArchive.decode(zip(entries));
    } on FormatException {
      checks++;
      return;
    }
    throw StateError('Accepted invalid ZIP: ${entries.map((e) => e.name)}');
  }

  accepts(base());
  accepts([
    for (final entry in base()) Entry(entry.name, entry.bytes, method: 8),
  ]);
  accepts([
    ...base(),
    Entry('assets/', [], mode: 0x41ed),
    Entry('assets/icon.txt', [1]),
  ]);
  for (final path in [
    '../escape',
    '/absolute',
    'C:/drive',
    r'..\escape',
    'a\u0000b',
  ]) {
    rejects([
      ...base(),
      Entry(path, [1]),
    ]);
  }
  rejects([
    ...base(),
    Entry('main.js', [1]),
  ]);
  rejects([
    ...base(),
    Entry('nested/../main.js', [1]),
  ]);
  rejects([...base(), Entry('main.js/', [], mode: 0x41ed)]);
  rejects([
    ...base(),
    Entry('main.js/child', [1]),
  ]);
  rejects([...base(), Entry('link', utf8.encode('../outside'), mode: 0xa1ff)]);
  rejects([...base(), Entry('pipe', [], mode: 0x11a4)]);
  rejects([
    ...base(),
    Entry('crc', [1, 2, 3], crc: 0),
  ]);
  rejects([
    ...base(),
    Entry('bad', [1], localName: 'other'),
  ]);
  rejects([
    ...base(),
    Entry('big', [1], declaredSize: 101 * 1024 * 1024),
  ]);
  rejects([
    ...base(),
    Entry('lie', List.filled(4096, 65), method: 8, declaredSize: 8),
  ]);
  rejects([...base(), for (var i = 0; i < 2000; i++) Entry('file$i', [])]);
  rejects(base({'entry': 'missing.js'}));
  rejects(base({'apiVersion': 2}));
  rejects(
    base({
      'networkOrigins': ['https://example.com/path'],
    }),
  );
  rejects(
    base({
      'permissions': ['shell'],
    }),
  );
  rejects([
    ...base({
      'ui': {'entry': 'ui.json'},
    }),
    Entry('ui.json', utf8.encode('{"type":"webview"}')),
  ]);
  accepts([
    ...base(),
    Entry(
      'config.schema.json',
      utf8.encode('{"type":"object","properties":{}}'),
    ),
  ]);
  try {
    PluginArchive.decode(Uint8List(10));
    throw StateError('Accepted non-ZIP');
  } on FormatException {
    checks++;
  }
  final truncated = zip(base());
  try {
    PluginArchive.decode(truncated.sublist(0, truncated.length - 12));
    throw StateError('Accepted truncated ZIP');
  } on FormatException {
    checks++;
  }
  final bytes = zip(base());
  final isolated = await Isolate.run(() => PluginArchive.decode(bytes));
  if (isolated.manifest['id'] != manifest['id'] || isolated.files.length != 2) {
    throw StateError('Isolate package transfer failed');
  }
  checks++;
  print('Plugin archive: $checks checks passed');
}
