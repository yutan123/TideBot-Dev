import 'dart:convert';
import 'dart:io';
import 'package:tide_bot/plugin_package_files.dart';
import 'package:tide_bot/plugin_web_server.dart';
import 'package:tide_bot/plugin_archive.dart';

int checks = 0;
void check(bool value, String label) {
  if (!value) throw StateError(label);
  checks++;
}

Future<void> rejects(Future<dynamic> Function() work) async {
  try {
    await work();
  } catch (_) {
    checks++;
    return;
  }
  throw StateError('Expected rejection');
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('tide-modules-');
  PluginWebServer? server;
  final client = HttpClient();
  Future<void> write(String path, String source) async {
    final f = File('${root.path}/$path');
    await f.parent.create(recursive: true);
    await f.writeAsString(source);
  }

  try {
    await write(
      'main.js',
      "const a=require('./lib/a');globalThis.result={value:a.value,cached:a===require('./lib/a'),json:require('./data.json').ok,cycle:require('./lib/cycle').ready};try{require('../escape')}catch(e){result.escape=true}try{require('fs')}catch(e){result.bare=true}",
    );
    await write('lib/a.js', "exports.value=require('../data.json').value;");
    await write('data.json', '{"value":42,"ok":true}');
    await write('lib/cycle.js', "exports.ready=true;require('./other');");
    await write('lib/other.js', "exports.value=require('./cycle').ready;");
    final files = PluginPackageFiles(root);
    final program = await files.program(
      'main.js',
      format: 'commonjs',
      modules: ['lib/a.js', 'data.json', 'lib/cycle.js', 'lib/other.js'],
    );
    final node = await Process.start('node', [
      '-e',
      "const vm=require('node:vm');let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{const c=vm.createContext({});vm.runInContext(s,c);console.log(JSON.stringify(c.result));})",
    ]);
    node.stdin.write(program);
    await node.stdin.close();
    final output = await utf8.decoder.bind(node.stdout).join();
    final errors = await utf8.decoder.bind(node.stderr).join();
    check(await node.exitCode == 0, 'module execution: $errors');
    final result = jsonDecode(output);
    check(
      result['value'] == 42 && result['json'] == true,
      'relative JS and JSON',
    );
    check(
      result['cached'] == true && result['cycle'] == true,
      'cache and cycles',
    );
    check(
      result['escape'] == true && result['bare'] == true,
      'scope restrictions',
    );
    await rejects(() => files.text('../escape'));
    await rejects(() => files.text('/etc/passwd'));
    await rejects(() => files.text('data.json', maxBytes: 2));
    await Link('${root.path}/escape').create('/etc/hosts');
    await rejects(() => files.text('escape'));
    await write('legacy.js', 'globalThis.legacy=7;');
    check(
      (await files.program('legacy.js')).contains('globalThis.legacy=7;'),
      'legacy script entry',
    );
    await write(
      'web/index.html',
      '<!doctype html><html><head></head><body>hello</body></html>',
    );
    await write('web/app.js', 'window.loaded=true;');
    bool valid = true;
    server = PluginWebServer(files, 'web/index.html', () async {
      if (!valid) throw StateError('stale');
    });
    await server.start();
    Future<HttpClientResponse> request(Uri uri) async =>
        (await client.getUrl(uri)).close();
    var response = await request(server.url);
    final html = await utf8.decoder.bind(response).join();
    check(
      response.statusCode == 200 && html.contains('tideUI'),
      'HTML and bridge',
    );
    check(
      response.headers
          .value('content-security-policy')!
          .contains("connect-src 'none'"),
      'web network policy',
    );
    response = await request(server.url.resolve('app.js'));
    await response.drain<void>();
    check(response.statusCode == 200, 'relative static files');
    response = await request(server.origin.resolve('/wrong/index.html'));
    await response.drain<void>();
    check(response.statusCode == 403, 'server token');
    response = await request(server.url.resolve('missing.js'));
    await response.drain<void>();
    check(response.statusCode == 404, 'missing asset');
    valid = false;
    response = await request(server.url);
    await response.drain<void>();
    check(response.statusCode == 404, 'epoch invalidation');
    final manifest = <String, dynamic>{
      'id': 'author.test',
      'name': 'test',
      'version': '1.0.0',
      'entry': 'main.js',
      'entryFormat': 'commonjs',
      'modules': ['lib/a.js'],
      'resources': ['data.json'],
      'ui': {'type': 'web', 'entry': 'web/index.html'},
    };
    final data = <String, List<int>>{
      'main.js': utf8.encode(''),
      'lib/a.js': utf8.encode(''),
      'data.json': utf8.encode('{}'),
      'web/index.html': utf8.encode('<html></html>'),
    };
    PluginArchive.validateManifest(manifest, data);
    checks++;
    await rejects(
      () async => PluginArchive.validateManifest({
        ...manifest,
        'modules': ['../evil.js'],
      }, data),
    );
    await rejects(
      () async => PluginArchive.validateManifest({
        ...manifest,
        'entryFormat': 'unknown',
      }, data),
    );
    await rejects(
      () async => PluginArchive.validateManifest({
        ...manifest,
        'ui': {'type': 'other', 'entry': 'web/index.html'},
      }, data),
    );
    print('Plugin modules/resources/web: $checks checks passed');
  } finally {
    client.close(force: true);
    await server?.close();
    await root.delete(recursive: true);
  }
}
