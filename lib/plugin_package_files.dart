import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// All package reads use the same containment and size checks.
class PluginPackageFiles {
  PluginPackageFiles(this.root);
  final Directory root;
  static String normalize(String path) {
    if (path.isEmpty ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        p.posix.isAbsolute(path)) {
      throw const FormatException('包内路径无效');
    }
    final normalized = p.posix.normalize(path);
    if (normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw const FormatException('包内路径越界');
    }
    return normalized;
  }

  Future<File> file(String path) async {
    final relative = normalize(path);
    final base = await root.resolveSymbolicLinks();
    final file = File(p.join(base, relative));
    final resolved = await file.resolveSymbolicLinks();
    if (!p.isWithin(base, resolved)) throw const FormatException('包内路径越界');
    return File(resolved);
  }

  Future<List<int>> read(String path, {int maxBytes = 1024 * 1024}) async {
    final target = await file(path);
    if (await target.length() > maxBytes)
      throw const FormatException('包内文件超过大小限制');
    final bytes = await target.readAsBytes();
    if (bytes.length > maxBytes) throw const FormatException('包内文件超过大小限制');
    return bytes;
  }

  Future<String> text(String path, {int maxBytes = 1024 * 1024}) async =>
      utf8.decode(await read(path, maxBytes: maxBytes));

  /// Build CommonJS factories without changing the isolate/IPC protocol.
  Future<String> program(
    String entry, {
    String format = 'script',
    List modules = const [],
  }) async {
    final sources = <String, String>{};
    var total = 0;
    for (final name in <String>{entry, ...modules.cast<String>()}) {
      final bytes = await read(name, maxBytes: 2 * 1024 * 1024);
      total += bytes.length;
      if (total > 3 * 1024 * 1024 || sources.length >= 256)
        throw const FormatException('模块累计超过 3 MiB 或 256 个文件');
      sources[name] = utf8.decode(bytes);
    }
    if (!sources.containsKey(entry)) throw const FormatException('入口文件不存在');
    final out = StringBuffer(
      '(function(){const factories=Object.create(null),cache=Object.create(null);\n',
    );
    for (final item in sources.entries) {
      if (format == 'script' && item.key == entry) continue;
      if (item.key.endsWith('.json')) {
        final value = jsonDecode(item.value);
        out.writeln(
          'factories[${jsonEncode(item.key)}]=function(require,module,exports){module.exports=${jsonEncode(value)};};',
        );
      } else {
        out.writeln(
          'factories[${jsonEncode(item.key)}]=function(require,module,exports){\n${item.value}\n};',
        );
      }
    }
    out.write(r'''
function resolve(request,parent){
 if(typeof request!=='string'||!/^\.\.?\//.test(request)||request.includes('\\')||request.includes('\0'))throw Error('Only relative package modules are supported');
 const parts=parent.split('/');parts.pop();
 for(const part of request.split('/')){if(part==='.'||part==='')continue;if(part==='..'){if(!parts.length)throw Error('Module path escapes package');parts.pop();}else parts.push(part);}
 const base=parts.join('/');
 for(const key of [base,base+'.js',base+'.json',base+'/index.js'])if(Object.prototype.hasOwnProperty.call(factories,key))return key;
 throw Error('Module not found: '+request+' from '+parent);
}
function load(key){
 if(cache[key])return cache[key].exports;
 const module={exports:{}};cache[key]=module;
 try{factories[key](request=>load(resolve(request,key)),module,module.exports);return module.exports;}
 catch(error){delete cache[key];throw error;}
}
''');
    if (format == 'commonjs') {
      out.writeln('load(${jsonEncode(entry)});');
    } else {
      // Legacy entry keeps global declarations and gains a package-scoped require.
      out.writeln(
        'globalThis.require=request=>load(resolve(request,${jsonEncode(entry)}));',
      );
    }
    out.writeln('})();');
    if (format == 'script') out.writeln(sources[entry]);
    final program = out.toString();
    if (program.length > 4 * 1024 * 1024)
      throw const FormatException('模块程序超过 4 Mi 字符');
    return program;
  }
}
