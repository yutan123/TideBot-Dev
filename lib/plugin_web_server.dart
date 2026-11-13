import 'plugin_operation.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'plugin_package_files.dart';

/// A page-scoped, loopback-only static server. It never executes plugin code.
class PluginWebServer {
  PluginWebServer(this.files, this.entry, this.check);
  final PluginPackageFiles files;
  final String entry;
  final Future<void> Function() check;
  HttpServer? _server;
  final _token = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  static const types = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
  };
  Uri get origin => Uri.parse('http://127.0.0.1:${_server!.port}');
  Uri get url => origin.resolve('/$_token/${p.posix.basename(entry)}');
  bool allows(Uri uri) =>
      _server != null &&
      uri.origin == origin.origin &&
      uri.path.startsWith('/$_token/');
  Future<void> start() async {
    await check();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      try {
        if (request.method != 'GET' ||
            !allows(request.requestedUri) ||
            request.headers.value('host') != origin.authority) {
          request.response.statusCode = 403;
          return;
        }
        await check();
        final raw = request.uri.path.substring('/$_token/'.length);
        final relative = PluginPackageFiles.normalize(raw);
        final path = p.posix.join(p.posix.dirname(entry), relative);
        final type = types[p.posix.extension(path).toLowerCase()];
        if (type == null) {
          request.response.statusCode = 415;
          return;
        }
        var bytes = await files.read(path, maxBytes: 4 * 1024 * 1024);
        await check();
        request.response.headers
          ..set('Content-Type', type)
          ..set('X-Content-Type-Options', 'nosniff')
          ..set('Cache-Control', 'no-store')
          ..set('Referrer-Policy', 'no-referrer')
          ..set(
            'Content-Security-Policy',
            "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
          );
        if (path.endsWith('.html')) {
          final html = utf8.decode(bytes);
          final head = RegExp(
            r'<head(?:\s[^>]*)?>',
            caseSensitive: false,
          ).firstMatch(html);
          final insertion =
              head?.end ??
              RegExp(
                r'<!doctype[^>]*>',
                caseSensitive: false,
              ).firstMatch(html)?.end ??
              0;
          bytes = utf8.encode(
            '${html.substring(0, insertion)}<script>$bridge</script>${html.substring(insertion)}',
          );
        }
        request.response.add(bytes);
      } catch (_) {
        request.response.statusCode = 404;
      } finally {
        await request.response.close();
      }
    });
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  static final bridge =
      r'''
(()=>{
 const pending=new Map();let seq=0;
 Object.defineProperty(window,'tideUI',{value:Object.freeze({
  call(action,values={}){
   if(pending.size>=8)return Promise.reject(Error('Too many UI requests'));
   const id=++seq;
   return new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{pending.delete(id);reject(Error('UI action timed out'));},__TIDE_UI_TIMEOUT__);
    pending.set(id,{resolve,reject,timer});
    try{TidePluginUI.postMessage(JSON.stringify({id,action,values}));}
    catch(e){clearTimeout(timer);pending.delete(id);reject(e);}
   });
  }
 }),writable:false});
 window.__tideUIResolve=(id,value,error)=>{const p=pending.get(id);if(!p)return;pending.delete(id);clearTimeout(p.timer);error?p.reject(Error(error)):p.resolve(value);};
})();
'''
          .replaceAll(
            '__TIDE_UI_TIMEOUT__',
            '${PluginTimeouts.host.inMilliseconds}',
          );
}
