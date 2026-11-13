import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_navigation.dart';
import 'db.dart';
import 'global_notice.dart';
import 'ota_release.dart';
import 'theme.dart';
import 'ui_components.dart';

class _DownloadCancelled implements Exception {}

class OtaUpdate {
  static const _channel = MethodChannel('tidebot.native.channel');
  static const _releaseApi =
      'https://api.github.com/repos/yutan123/TideBot/releases';
  static const _releaseApiFallbacks = <String>[
    'https://ghproxy.net/https://api.github.com/repos/yutan123/TideBot/releases',
    'https://mirror.ghproxy.com/https://api.github.com/repos/yutan123/TideBot/releases',
    'https://gh-proxy.com/https://api.github.com/repos/yutan123/TideBot/releases',
  ];

  static Future<void> checkOncePerDay() async {
    final db = DBManager();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (await db.getKV('ota_checked_date') == today) return;
    await db.setKV('ota_checked_date', today);
    await _check(showWhenCurrent: false);
  }

  static Future<void> checkNow(BuildContext context) =>
      _check(showWhenCurrent: true, context: context);

  static Future<void> _check({
    required bool showWhenCurrent,
    BuildContext? context,
  }) async {
    try {
      final release = await _latestRelease();
      final version = OtaReleasePicker.versionOf(release);
      final installed = (await PackageInfo.fromPlatform()).version;
      if (version.isEmpty ||
          OtaReleasePicker.compareVersions(version, installed) <= 0) {
        if (showWhenCurrent && context != null && context.mounted) {
          GlobalNotice.show('当前已是最新版本');
        }
        return;
      }
      if (await DBManager().getKV('ota_ignored_version') == version &&
          !showWhenCurrent) {
        return;
      }
      final target = context ?? appNavigatorKey.currentContext;
      if (target == null || !target.mounted) return;
      await _showUpdate(target, release, version);
    } catch (error) {
      debugPrint('[ota] check failed: $error');
      if (showWhenCurrent && context != null && context.mounted) {
        GlobalNotice.show(_errorMessage(error), color: const Color(0xFFE74C3C));
      }
    }
  }

  static String _errorMessage(Object error) {
    if (error is SocketException) return '网络连接失败，请检查网络后重试';
    if (error is TimeoutException) return '检查更新超时，请稍后重试';
    if (error is HttpException) {
      if (error.message.contains('404')) return '更新源尚未发布可用版本';
      if (error.message.contains('403')) return '更新源访问受限，请稍后重试';
    }
    if (error is FormatException) return '更新信息格式无效';
    return '检查更新失败，请稍后重试';
  }

  static Future<Map<String, dynamic>> _latestRelease() async {
    final errors = <String>[];
    for (final endpoint in <String>[_releaseApi, ..._releaseApiFallbacks]) {
      final client = http.Client();
      try {
        final response = await client.get(
          Uri.parse(endpoint),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'TideBot',
          },
        ).timeout(const Duration(seconds: 12));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          errors.add('$endpoint HTTP ${response.statusCode}');
          continue;
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! List) {
          errors.add('$endpoint 响应不是 Release 列表');
          continue;
        }
        final picked = OtaReleasePicker.pickLatest(decoded);
        if (picked != null) return picked;
        errors.add('$endpoint 未找到可用 Release');
      } on TimeoutException {
        errors.add('$endpoint 超时');
      } on SocketException {
        errors.add('$endpoint 网络不可达');
      } on FormatException {
        errors.add('$endpoint 返回非 JSON 数据');
      } catch (error) {
        errors.add('$endpoint $error');
      } finally {
        client.close();
      }
    }
    throw HttpException('所有更新源均不可用：${errors.join('；')}');
  }

  static Future<void> _showUpdate(
    BuildContext context,
    Map<String, dynamic> release,
    String version,
  ) async {
    final urls = OtaReleasePicker.apkUrls(release);
    if (urls.isEmpty) {
      GlobalNotice.show('该版本没有 TideBot.apk 安装包',
          color: const Color(0xFFE74C3C));
      return;
    }
    final notes = (release['body']?.toString().trim().isNotEmpty == true)
        ? release['body'].toString().trim()
        : '有新的 TideBot 版本可用。';
    final action = await TideDialogs.show<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final theme = TideTheme.of(ctx);
        return Center(
          child: Material(
            type: MaterialType.transparency,
            child: TideDialogs.glassContent(context: ctx, children: [
              Row(
                children: [
                  Expanded(
                    child: Text('发现新版本 $version',
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'TideFont')),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(notes,
                  style:
                      TextStyle(color: theme.textWeak, fontFamily: 'TideFont')),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(
                  child: TideDialogs.glassButton(
                    '忽略此版本',
                    color: theme.buttonSecondary,
                    textColor: theme.textStrong,
                    onTap: () => Navigator.pop(ctx, 'ignore'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TideDialogs.glassButton(
                    '立即更新',
                    onTap: () => Navigator.pop(ctx, 'update'),
                  ),
                ),
              ]),
            ]),
          ),
        );
      },
    );
    if (action == 'ignore') {
      await DBManager().setKV('ota_ignored_version', version);
      return;
    }
    if (action != 'update') return;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/TideBot.apk');
      final selectedUrls = await _rankUrls(urls);
      await _showDownloadProgress(context, selectedUrls, file);
      await _channel.invokeMethod('installApk', {'path': file.path});
    } on _DownloadCancelled {
      return;
    } catch (error) {
      if (context.mounted) {
        GlobalNotice.show('更新失败，正在打开浏览器下载：${_errorMessage(error)}',
            color: const Color(0xFFE74C3C));
      }
      try {
        await _openBrowserFallback(urls.first);
      } catch (_) {}
    }
  }

  static Future<void> _openBrowserFallback(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const HttpException('无法打开浏览器下载页面');
    }
  }

  static Future<void> _showDownloadProgress(
    BuildContext context,
    List<String> urls,
    File destination,
  ) async {
    var cancelled = false;
    http.Client? activeClient;
    Route<void>? downloadRoute;
    var received = 0;
    var total = 0;
    void Function(void Function())? refresh;

    void closeDialog() {
      final route = downloadRoute;
      downloadRoute = null;
      refresh = null;
      if (route != null && route.isActive) route.navigator?.removeRoute(route);
    }

    final dialog = TideDialogs.show<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          downloadRoute = ModalRoute.of<void>(ctx);
          refresh = setState;
          final progress = total > 0 ? received / total : null;
          return PopScope(
            canPop: false,
            child: Center(
              child: Material(
                type: MaterialType.transparency,
                child: TideDialogs.glassContent(
                  context: ctx,
                  children: [
                    const Text('正在下载更新',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'TideFont')),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 8),
                    Text(
                      total > 0
                          ? '${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB'
                          : '${(received / 1024 / 1024).toStringAsFixed(1)} MB',
                      style: const TextStyle(fontFamily: 'TideFont'),
                    ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          cancelled = true;
                          activeClient?.close();
                          closeDialog();
                        },
                        child: const Text('取消'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    // Let the builder capture the exact route before starting network work.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await _download(
        urls,
        destination,
        isCancelled: () => cancelled,
        onClientCreated: (client) => activeClient = client,
        onProgress: (next, size) {
          received = next;
          total = size;
          if (!cancelled) refresh?.call(() {});
        },
      );
      if (cancelled) throw _DownloadCancelled();
      closeDialog();
    } catch (_) {
      closeDialog();
      rethrow;
    } finally {
      await dialog;
    }
  }

  static List<String> _candidateUrls(String url) {
    return {
      url,
      'https://ghproxy.net/$url',
      'https://mirror.ghproxy.com/$url',
      'https://gh-proxy.com/$url',
    }.toList();
  }

  static bool _isValidApkProbe(http.StreamedResponse response) {
    if (response.statusCode != 200 && response.statusCode != 206) return false;
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final contentRange = response.headers['content-range'];
    final contentLength =
        int.tryParse(response.headers['content-length'] ?? '');
    // Proxies frequently return an HTML challenge page with HTTP 200. A ranged
    // APK response must either identify an Android archive or carry range data.
    return !contentType.contains('text/html') &&
        (contentType.contains('application/vnd.android.package-archive') ||
            contentType.contains('application/octet-stream') ||
            contentRange != null ||
            (contentLength != null && contentLength >= 4));
  }

  static Future<List<String>> _rankUrls(List<String> urls) async {
    final probes = await Future.wait(
      urls.expand(_candidateUrls).map((url) async {
        final started = DateTime.now();
        final client = http.Client();
        try {
          final response = await client
              .send(http.Request('GET', Uri.parse(url))
                ..headers.addAll({
                  'User-Agent': 'TideBot',
                  'Range': 'bytes=0-3',
                }))
              .timeout(const Duration(seconds: 8));
          final valid = _isValidApkProbe(response);
          // A proxy may ignore Range: consume at most one chunk, then cancel.
          final iterator = StreamIterator<List<int>>(response.stream);
          try {
            await iterator.moveNext().timeout(const Duration(seconds: 8));
          } finally {
            await iterator.cancel();
          }
          return (
            url: url,
            valid: valid,
            elapsed: DateTime.now().difference(started)
          );
        } catch (_) {
          return (url: url, valid: false, elapsed: const Duration(days: 1));
        } finally {
          client.close();
        }
      }),
    );
    final valid = probes.where((probe) => probe.valid).toList()
      ..sort((a, b) => a.elapsed.compareTo(b.elapsed));
    return [...valid.map((probe) => probe.url), ...urls];
  }

  static Future<void> _download(
    List<String> urls,
    File destination, {
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
    void Function(http.Client client)? onClientCreated,
  }) async {
    final errors = <String>[];
    for (final url in urls) {
      if (isCancelled?.call() == true) {
        throw _DownloadCancelled();
      }
      final client = http.Client();
      onClientCreated?.call(client);
      IOSink? sink;
      try {
        if (await destination.exists()) await destination.delete();
        final request = http.Request('GET', Uri.parse(url))
          ..headers['User-Agent'] = 'TideBot';
        final response =
            await client.send(request).timeout(const Duration(seconds: 30));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          errors.add('$url HTTP ${response.statusCode}');
          continue;
        }
        sink = destination.openWrite(mode: FileMode.writeOnly);
        var received = 0;
        final total =
            int.tryParse(response.headers['content-length'] ?? '') ?? 0;
        final deadline = DateTime.now().add(const Duration(minutes: 15));
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 30))) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('下载超过时限');
          }
          if (isCancelled?.call() == true) {
            client.close();
            throw _DownloadCancelled();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        final handle = await destination.open();
        late final List<int> bytes;
        try {
          bytes = await handle.read(4);
        } finally {
          await handle.close();
        }
        if (total > 0 && received != total) {
          throw const HttpException('下载文件不完整');
        }
        if (bytes.length >= 4 &&
            bytes[0] == 0x50 &&
            bytes[1] == 0x4b &&
            bytes[2] == 0x03 &&
            bytes[3] == 0x04) {
          return;
        }
        errors.add('$url 不是有效 APK 文件');
      } catch (error) {
        if (isCancelled?.call() == true) {
          if (await destination.exists()) await destination.delete();
          rethrow;
        }
        errors.add('$url $error');
      } finally {
        await sink?.close();
        client.close();
        if (await destination.exists() && await destination.length() == 0) {
          await destination.delete();
        }
      }
    }
    throw HttpException('安装包下载失败：${errors.join('；')}');
  }
}
