import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'db.dart';

// Keep route transitions transparent so the app-wide background remains
// visible while pages fade or move. Material's default surface scrim would
// otherwise briefly cover it on both push and pop.
const tidePageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: PredictiveBackPageTransitionsBuilder(
      fallbackColor: Colors.transparent,
    ),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: ZoomPageTransitionsBuilder(
      backgroundColor: Colors.transparent,
    ),
    TargetPlatform.linux: ZoomPageTransitionsBuilder(
      backgroundColor: Colors.transparent,
    ),
    TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(
      backgroundColor: Colors.transparent,
    ),
  },
);

// ================= 全局主题系统 =================
// 每个主题含日/夜两套主色，夜间更沉静、更护眼。
class TideBackground extends StatefulWidget {
  const TideBackground({
    super.key,
    required this.child,
    this.backgroundPath,
    this.opacity,
    this.excludeGlobalBackground = false,
  });

  final Widget child;
  final String? backgroundPath;
  final double? opacity;
  final bool excludeGlobalBackground;

  @override
  State<TideBackground> createState() => _TideBackgroundState();
}

class _TideBackgroundState extends State<TideBackground> {
  static final Map<String, ImageProvider> _imageCache = {};
  static String _lastGlobalPath = '';
  static ImageProvider? _lastGlobalImage;

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final useGlobalBackground =
        theme.hasGlobalBackground && !widget.excludeGlobalBackground;
    final path =
        widget.backgroundPath ??
        (useGlobalBackground ? theme.globalBackground : '');

    ImageProvider? image;
    if (widget.backgroundPath != null) {
      // 聊天背景优先，使用缓存
      final cachePath = widget.backgroundPath!;
      if (_imageCache.containsKey(cachePath)) {
        image = _imageCache[cachePath];
      } else {
        image = FileImage(File(cachePath));
        _imageCache[cachePath] = image;
      }
    } else if (useGlobalBackground) {
      // 全局背景使用主题提供的 ImageProvider，避免重复创建
      if (theme.globalBackground == _lastGlobalPath &&
          _lastGlobalImage != null) {
        image = _lastGlobalImage;
      } else {
        image = theme.globalBackgroundImage;
        _lastGlobalPath = theme.globalBackground;
        _lastGlobalImage = image;
      }
    }

    final hasImage =
        image != null &&
        theme.isGlobalBackgroundReady &&
        (path.isEmpty || File(path).existsSync());

    // 无背景图时直接用纯色底，避免 Stack 切换时的闪烁
    if (!hasImage) {
      return ColoredBox(color: theme.pageBackground, child: widget.child);
    }

    final scrimOpacity = widget.opacity ?? theme.effectiveBackgroundOpacity;
    final scrim = theme.isWechat
        ? theme.pageBackground.withValues(
            alpha: (.65 + scrimOpacity * .45).clamp(.70, .97),
          )
        : Colors.black.withValues(alpha: scrimOpacity);

    // Use a single RepaintBoundary for the background stack to ensure
    // BackdropFilter in child widgets can reference it correctly during animations
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    ColoredBox(color: theme.pageBackground),
              ),
              IgnorePointer(child: ColoredBox(color: scrim)),
            ],
          ),
        ),
        widget.child,
      ],
    );
  }
}

class TideTheme extends ChangeNotifier {
  static const int _maxBackgroundBytes = 12 * 1024 * 1024;
  static const int _maxBackgroundPixels = 12 * 1000 * 1000;
  // 薄荷绿是产品默认主题；其他颜色仅在用户主动选择后使用。
  String _name = 'mint';
  String _interfaceTheme = 'default';
  String get interfaceTheme => _interfaceTheme;
  bool get isWechat => _interfaceTheme == 'wechat';
  Color get wechatBar =>
      isDark ? const Color(0xFF191919) : const Color(0xFFEDEDED);
  Color get wechatOutgoing =>
      isDark ? const Color(0xFF3EB575) : const Color(0xFF95EC69);

  Future<void> setInterfaceTheme(String value) async {
    if (value != 'default' && value != 'wechat') return;
    await DBManager().insertKV('interface_theme', value);
    _interfaceTheme = value;
    notifyListeners();
  }

  ThemeMode _mode = ThemeMode.system; // 跟随系统，用户可手动切日/夜
  bool _manualMode = false;
  Color _primary = const Color(0xFF5FAF8A);
  Color _primaryLight = const Color(0xFF9CD4BC);
  String _globalBackground = '';
  FileImage? _globalBackgroundImage;
  String _configuredBackgroundPath = '';
  double _configuredDevicePixelRatio = 0;
  Size _configuredSize = Size.zero;
  bool _globalBackgroundReady = false;
  // Backgrounds saved before this marker predate the guarded image pipeline.
  // They are discarded at the next launch so an old malformed file cannot crash
  // the renderer before the user can remove it.
  static const _globalBackgroundSafetyKey = 'global_background_safe_v3';
  double _globalBackgroundOpacity = 0.38;
  bool _enableLiquidGlass = true;
  Future<bool>? _backgroundPreparation;
  String _backgroundPreparationPath = '';
  Size _backgroundPreparationSize = Size.zero;
  double _backgroundPreparationDpr = 0;
  final Map<_BackgroundRegion, bool> _backgroundLightness = {};

  Color get primary => isWechat ? const Color(0xFF07C160) : _primary;
  Color get primaryLight => isWechat ? const Color(0xFF38CD7F) : _primaryLight;
  String get name => _name;
  ThemeMode get mode => _mode;
  bool get hasManualMode => _manualMode;
  String get globalBackground => _globalBackground;
  ImageProvider<Object>? get globalBackgroundImage => _globalBackgroundImage;
  bool get isGlobalBackgroundReady => _globalBackgroundReady;
  double get globalBackgroundOpacity => _globalBackgroundOpacity;
  bool get hasGlobalBackground => _globalBackground.isNotEmpty;
  bool get enableLiquidGlass => _enableLiquidGlass;
  bool get useLiquidGlass =>
      hasGlobalBackground && enableLiquidGlass && !isWechat;

  /// The dock always retains its original flowing glass. Wallpaper glass
  /// controls page surfaces and the selected capsule independently.
  bool get useDockLiquidGlass => !isWechat;

  void _setGlobalBackgroundImage(String path) {
    _configuredBackgroundPath = '';
    _configuredDevicePixelRatio = 0;
    _configuredSize = Size.zero;
    _backgroundPreparation = null;
    _backgroundPreparationPath = '';
    _backgroundPreparationSize = Size.zero;
    _backgroundPreparationDpr = 0;
    _backgroundLightness.clear();
    if (path.isEmpty) {
      _globalBackgroundImage = null;
      _globalBackgroundReady = true;
      return;
    }
    _globalBackgroundImage = FileImage(File(path));
    // The renderer can show a validated FileImage immediately. Preparation only
    // warms the cache and samples contrast; it must never gate the background.
    _globalBackgroundReady = true;
  }

  /// Updates an isolated preview without writing preferences or the live theme.
  void configureBackgroundPreview(
    TideTheme source, {
    required String path,
    required double opacity,
    required bool enableLiquidGlass,
    bool notify = true,
  }) {
    _interfaceTheme = source._interfaceTheme;
    _name = source._name;
    _mode = source._mode;
    _manualMode = source._manualMode;
    _primary = source._primary;
    _primaryLight = source._primaryLight;
    if (_globalBackground != path) {
      _globalBackground = path;
      _setGlobalBackgroundImage(path);
      if (path == source.globalBackground) {
        _backgroundLightness.addAll(source._backgroundLightness);
      }
    }
    _globalBackgroundOpacity = opacity.clamp(.18, .70);
    _enableLiquidGlass = enableLiquidGlass;
    if (notify) notifyListeners();
  }

  ImageConfiguration _imageConfiguration(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    return createLocalImageConfiguration(context, size: media?.size);
  }

  Future<bool> _isSafeBackgroundFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final byteLength = await file.length();
      if (byteLength <= 0 || byteLength > _maxBackgroundBytes) return false;

      final codec = await ui.instantiateImageCodec(
        await file.readAsBytes(),
        targetWidth: 2048,
        targetHeight: 2048,
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          return frame.image.width * frame.image.height <= _maxBackgroundPixels;
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearPersistedBackground(DBManager db) async {
    _globalBackground = '';
    _setGlobalBackgroundImage('');
    _backgroundLightness.clear();
    await db.insertKV('global_background_image', '');
    await db.insertKV(_globalBackgroundSafetyKey, '');
  }

  Future<bool> precacheGlobalBackground(BuildContext context) {
    final path = _globalBackground;
    final image = _globalBackgroundImage;
    if (path.isEmpty || image == null) return Future.value(false);

    final media = MediaQuery.maybeOf(context);
    final size = media?.size ?? Size.zero;
    final dpr = media?.devicePixelRatio ?? View.of(context).devicePixelRatio;
    if (_configuredBackgroundPath == path &&
        _configuredDevicePixelRatio == dpr &&
        _configuredSize == size) {
      return Future.value(true);
    }
    if (_backgroundPreparation != null &&
        _backgroundPreparationPath == path &&
        _backgroundPreparationSize == size &&
        _backgroundPreparationDpr == dpr) {
      return _backgroundPreparation!;
    }

    _backgroundPreparationPath = path;
    _backgroundPreparationSize = size;
    _backgroundPreparationDpr = dpr;
    late final Future<bool> preparation;
    preparation = _prepareGlobalBackground(
      path: path,
      image: image,
      context: context,
      size: size,
      dpr: dpr,
    );
    _backgroundPreparation = preparation;
    unawaited(
      preparation.whenComplete(() {
        if (identical(_backgroundPreparation, preparation)) {
          _backgroundPreparation = null;
        }
      }),
    );
    return preparation;
  }

  Future<bool> _prepareGlobalBackground({
    required String path,
    required ImageProvider<Object> image,
    required BuildContext context,
    required Size size,
    required double dpr,
  }) async {
    try {
      await precacheImage(image, context, size: size);
      final stream = image.resolve(_imageConfiguration(context));
      final ready = Completer<ui.Image>();
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          stream.removeListener(listener);
          if (!ready.isCompleted) ready.complete(info.image);
        },
        onError: (_, __) {
          stream.removeListener(listener);
          if (!ready.isCompleted) {
            ready.completeError(StateError('背景图片解码失败'));
          }
        },
      );
      stream.addListener(listener);
      await _sampleBackgroundLightness(await ready.future);
      if (path != _globalBackground) return false;
      _configuredBackgroundPath = path;
      _configuredDevicePixelRatio = dpr;
      _configuredSize = size;
      notifyListeners();
      return true;
    } catch (_) {
      // This is a cache warm-up failure, not a reason to mutate persistence.
      // A new selection is already decoded before it becomes active.
      return false;
    }
  }

  Future<void> _sampleBackgroundLightness(ui.Image image) async {
    // Read a small rendered thumbnail rather than allocating a full RGBA copy of
    // a potentially multi-megapixel camera image on the UI image pipeline.
    const sampleSize = 48;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..filterQuality = FilterQuality.low;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      const Rect.fromLTWH(0, 0, 48, 48),
      paint,
    );
    final thumbnail = await recorder.endRecording().toImage(
      sampleSize,
      sampleSize,
    );
    try {
      final bytes = await thumbnail.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (bytes == null) return;
      final samples = <_BackgroundRegion, Rect>{
        _BackgroundRegion.header: const Rect.fromLTWH(.15, 0, .7, .18),
        _BackgroundRegion.content: const Rect.fromLTWH(.1, .25, .8, .5),
        _BackgroundRegion.footer: const Rect.fromLTWH(.15, .78, .7, .2),
      };
      for (final entry in samples.entries) {
        var total = 0.0;
        var count = 0;
        for (var y = 0; y < 3; y++) {
          for (var x = 0; x < 3; x++) {
            final px =
                ((entry.value.left + entry.value.width * (x / 2)) *
                        (sampleSize - 1))
                    .round()
                    .clamp(0, sampleSize - 1)
                    .toInt();
            final py =
                ((entry.value.top + entry.value.height * (y / 2)) *
                        (sampleSize - 1))
                    .round()
                    .clamp(0, sampleSize - 1)
                    .toInt();
            final offset = (py * sampleSize + px) * 4;
            final r = bytes.getUint8(offset) / 255;
            final g = bytes.getUint8(offset + 1) / 255;
            final b = bytes.getUint8(offset + 2) / 255;
            total += .2126 * r + .7152 * g + .0722 * b;
            count++;
          }
        }
        _backgroundLightness[entry.key] = total / count > .55;
      }
    } finally {
      thumbnail.dispose();
    }
  }

  bool _isBackgroundLight(_BackgroundRegion region) =>
      _backgroundLightness[region] ?? !isDark;

  Color _onBackgroundFor(_BackgroundRegion region, {bool weak = false}) {
    if (!useLiquidGlass) {
      return weak
          ? (isDark ? const Color(0xFF8A8F98) : const Color(0xFF636366))
          : (isDark ? const Color(0xFFECEDF0) : const Color(0xFF1C1C1E));
    }
    final onLightImage = _isBackgroundLight(region);
    if (weak) {
      return onLightImage ? const Color(0xDD14171C) : const Color(0xFFF3F5F7);
    }
    return onLightImage ? const Color(0xFF101216) : Colors.white;
  }

  Color get onBackgroundStrong => _onBackgroundFor(_BackgroundRegion.content);
  Color get onBackgroundWeak =>
      _onBackgroundFor(_BackgroundRegion.content, weak: true);
  Color get onBackgroundIcon => onBackgroundStrong;
  Color get backgroundScrim =>
      Colors.black.withValues(alpha: effectiveBackgroundOpacity);

  bool get isDark {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (_mode == ThemeMode.system) return brightness == Brightness.dark;
    return _mode == ThemeMode.dark;
  }

  LinearGradient get primaryGradient =>
      LinearGradient(colors: [primary, primaryLight]);
  Color get pageBackground => isWechat
      ? (isDark ? const Color(0xFF111111) : const Color(0xFFEDEDED))
      : (isDark ? const Color(0xFF151820) : const Color(0xFFF3F5FA));
  Color get bgColor =>
      hasGlobalBackground ? Colors.transparent : pageBackground;
  Color get backgroundOverlayColor =>
      isDark ? const Color(0xFF06080C) : const Color(0xFF101216);
  double get effectiveBackgroundOpacity {
    if (!hasGlobalBackground) return 0;
    final readabilityFloor = isDark ? 0.24 : 0.18;
    return _globalBackgroundOpacity < readabilityFloor
        ? readabilityFloor
        : _globalBackgroundOpacity;
  }

  double get backgroundScrimOpacity => effectiveBackgroundOpacity;

  Color get surface => isWechat
      ? (isDark ? const Color(0xFF1F1F1F) : Colors.white)
      : (isDark ? const Color(0xFF20242C) : const Color(0xFFFFFFFF));
  Color get surfaceVariant => isWechat
      ? (isDark ? const Color(0xFF292929) : const Color(0xFFF7F7F7))
      : (isDark ? const Color(0xFF2B303A) : const Color(0xFFE9EDF5));
  Color get glass => isDark ? const Color(0xE01D222B) : const Color(0xC9FFFFFF);

  // Night surfaces stay neutral graphite so theme accents and image content remain distinct.

  // 文字主色
  Color get textStrong =>
      isDark ? const Color(0xFFECEDF0) : const Color(0xFF1C1C1E);
  Color get textWeak =>
      isDark ? const Color(0xFF8A8F98) : const Color(0xFF636366);
  // 更弱的文字/图标色
  Color get textFaint =>
      isDark ? const Color(0xFF5A5F68) : const Color(0xFFC7C7CC);
  // 分割线
  Color get divider =>
      isDark ? const Color(0x22FFFFFF) : const Color(0x14000000);
  // 边框
  Color get border =>
      isDark ? const Color(0x33FFFFFF) : const Color(0x1A000000);
  // 图标弱色
  Color get iconMuted =>
      isDark ? const Color(0xFF9AA1A9) : const Color(0xFF8E8E93);
  // AI/次要气泡底色（日间浅白、夜间深灰）
  Color get bubbleAi =>
      isDark ? const Color(0xFF292E38) : const Color(0xFFFFFFFF);

  // 次要按钮底色（取消、次级操作）
  Color get buttonSecondary =>
      isDark ? const Color(0xFF33363E) : const Color(0xFFE8E8F0);

  // 主题配色：主色 + 亮色 + 中文名 + 深色底主色（护眼） + 深色亮色
  static const _themes = {
    'rose': {
      'name': '玫瑰粉',
      'light': [Color(0xFFD98C94), Color(0xFFE8B8BE)],
      'dark': [Color(0xFFD98A92), Color(0xFFB0707A)],
    },
    'aurora': {
      'name': '极光蓝',
      'light': [Color(0xFF6C8CD5), Color(0xFFA7BEE8)],
      'dark': [Color(0xFF7D9BE0), Color(0xFF5A7499)],
    },
    'lavender': {
      'name': '薰衣草',
      'light': [Color(0xFF9B8AC4), Color(0xFFC5B8E0)],
      'dark': [Color(0xFFA79ACD), Color(0xFF7C6FA3)],
    },
    'sky': {
      'name': '雾霾蓝',
      'light': [Color(0xFF5D9BC5), Color(0xFF9CC5E3)],
      'dark': [Color(0xFF6FA9D2), Color(0xFF4A7DA0)],
    },
    'mint': {
      'name': '薄荷绿',
      'light': [Color(0xFF5FAF8A), Color(0xFF9CD4BC)],
      'dark': [Color(0xFF6BB996), Color(0xFF4A8F72)],
    },
    'peach': {
      'name': '蜜桃橙',
      'light': [Color(0xFFE39A6B), Color(0xFFF0C4A0)],
      'dark': [Color(0xFFE8A678), Color(0xFFB97D50)],
    },
    'plum': {
      'name': '梅子紫',
      'light': [Color(0xFF8E74B4), Color(0xFFB7A6D6)],
      'dark': [Color(0xFF9A80C0), Color(0xFF6E5895)],
    },
    'teal': {
      'name': '青瓷绿',
      'light': [Color(0xFF4FA79C), Color(0xFF92CFC8)],
      'dark': [Color(0xFF59B3A8), Color(0xFF3E857C)],
    },
    'sunset': {
      'name': '落日橙',
      'light': [Color(0xFFE06A5A), Color(0xFFF2A79A)],
      'dark': [Color(0xFFE87668), Color(0xFFB4554A)],
    },
    'ocean': {
      'name': '深海蓝',
      'light': [Color(0xFF3E7CB1), Color(0xFF7FAFDB)],
      'dark': [Color(0xFF4C8EC4), Color(0xFF33658A)],
    },
    'pinkg': {
      'name': '樱花粉',
      'light': [Color(0xFFE07A9A), Color(0xFFF0B3C6)],
      'dark': [Color(0xFFE886A4), Color(0xFFB55A78)],
    },
    'night': {
      'name': '午夜紫',
      'light': [Color(0xFF6B5FAE), Color(0xFF9D92D0)],
      'dark': [Color(0xFF786BC0), Color(0xFF524A86)],
    },
  };

  static List<Map<String, String>> get themeOptions => _themes.entries
      .map((e) => {'id': e.key, 'name': (e.value['name']!) as String})
      .toList();

  Future<void> loadFromDB() async {
    try {
      final db = DBManager();
      final style = await db
          .getKV('interface_theme')
          .timeout(const Duration(seconds: 5));
      _interfaceTheme = style == 'wechat' ? 'wechat' : 'default';
      final name = await db
          .getKV('theme_color')
          .timeout(const Duration(seconds: 5));
      if (name != null && _themes.containsKey(name)) {
        _name = name;
        _applyColors();
      }
      // 读取日夜模式
      final modeStr = await db
          .getKV('theme_mode')
          .timeout(const Duration(seconds: 5));
      if (modeStr != null) {
        if (modeStr == 'system') {
          _mode = ThemeMode.system;
          _manualMode = false;
        } else if (modeStr == 'light') {
          _mode = ThemeMode.light;
          _manualMode = true;
        } else if (modeStr == 'dark') {
          _mode = ThemeMode.dark;
          _manualMode = true;
        }
      }
      // A background becomes eligible only after the guarded save pipeline marks
      // it safe. This also recovers installs that saved a bad image before that
      // pipeline existed, without rendering it during startup.
      final globalBackground = await db
          .getKV('global_background_image')
          .timeout(const Duration(seconds: 5));
      final backgroundIsSafe = await db
          .getKV(_globalBackgroundSafetyKey)
          .timeout(const Duration(seconds: 5));
      if (globalBackground != null && globalBackground.isNotEmpty) {
        final isSafe =
            backgroundIsSafe == 'true' &&
            await _isSafeBackgroundFile(globalBackground);
        if (isSafe) {
          _globalBackground = globalBackground;
          _setGlobalBackgroundImage(globalBackground);
        } else {
          await _clearPersistedBackground(db);
        }
      }
      _globalBackgroundOpacity =
          (double.tryParse(
                    await db
                            .getKV('global_background_opacity')
                            .timeout(const Duration(seconds: 5)) ??
                        '',
                  ) ??
                  _globalBackgroundOpacity)
              .clamp(0.18, 0.70);
      final enableLiquidGlass = await db
          .getKV('enable_liquid_glass')
          .timeout(const Duration(seconds: 5));
      _enableLiquidGlass = enableLiquidGlass != 'false';
    } catch (error) {
      debugPrint('[theme] using defaults after database load failure: $error');
    }
    notifyListeners();
  }

  void _applyColors() {
    final t = _themes[_name]!;
    final dark = isDark;
    final palette = ((dark ? t['dark'] : t['light'])! as List<Object>)
        .cast<Color>();
    _primary = palette[0];
    _primaryLight = palette[1];
  }

  Future<void> setTheme(String name) async {
    if (!_themes.containsKey(name)) return;
    _name = name;
    _applyColors();
    await DBManager().insertKV('theme_color', name);
    notifyListeners();
  }

  // 切换日夜：system->light->dark->system
  Future<String> cycleMode() async {
    if (_mode == ThemeMode.system) {
      _mode = ThemeMode.light;
      _manualMode = true;
    } else if (_mode == ThemeMode.light) {
      _mode = ThemeMode.dark;
      _manualMode = true;
    } else {
      _mode = ThemeMode.system;
      _manualMode = false;
    }
    _applyColors();
    await DBManager().insertKV(
      'theme_mode',
      _mode == ThemeMode.dark
          ? 'dark'
          : (_mode == ThemeMode.light ? 'light' : 'system'),
    );
    notifyListeners();
    return _mode == ThemeMode.dark
        ? 'dark'
        : (_mode == ThemeMode.light ? 'light' : 'system');
  }

  void applySystemBrightness() {
    _applyColors();
    notifyListeners();
  }

  Future<void> setGlobalBackground(
    String path, {
    required BuildContext context,
    double? opacity,
    bool? enableLiquidGlass,
  }) async {
    final nextOpacity = opacity == null
        ? _globalBackgroundOpacity
        : opacity.clamp(0.18, 0.70);
    final nextEnableLiquidGlass = enableLiquidGlass ?? _enableLiquidGlass;

    if (path.isEmpty) {
      await DBManager().insertKV('global_background_image', '');
      await DBManager().insertKV(_globalBackgroundSafetyKey, '');
      await DBManager().insertKV(
        'global_background_opacity',
        nextOpacity.toStringAsFixed(2),
      );
      await DBManager().insertKV(
        'enable_liquid_glass',
        nextEnableLiquidGlass.toString(),
      );
      _globalBackgroundOpacity = nextOpacity;
      _enableLiquidGlass = nextEnableLiquidGlass;
      _globalBackground = '';
      _setGlobalBackgroundImage('');
      notifyListeners();
      return;
    }
    if (!await _isSafeBackgroundFile(path)) {
      throw StateError('背景图片过大或无法安全解码');
    }

    final candidate = FileImage(File(path));
    try {
      // Decode before making the selection live. This keeps a bad image from
      // causing every rebuilt screen to retry its decoder.
      await precacheImage(
        candidate,
        context,
        size: MediaQuery.maybeOf(context)?.size,
      );
      final stream = candidate.resolve(_imageConfiguration(context));
      final ready = Completer<ui.Image>();
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, __) {
          stream.removeListener(listener);
          if (!ready.isCompleted) ready.complete(info.image);
        },
        onError: (_, __) {
          stream.removeListener(listener);
          if (!ready.isCompleted) {
            ready.completeError(StateError('背景图片解码失败'));
          }
        },
      );
      stream.addListener(listener);
      final image = await ready.future.timeout(const Duration(seconds: 12));
      await _sampleBackgroundLightness(image);

      await DBManager().insertKV('global_background_image', path);
      await DBManager().insertKV(_globalBackgroundSafetyKey, 'true');
      await DBManager().insertKV(
        'global_background_opacity',
        nextOpacity.toStringAsFixed(2),
      );
      await DBManager().insertKV(
        'enable_liquid_glass',
        nextEnableLiquidGlass.toString(),
      );
      _globalBackgroundOpacity = nextOpacity;
      _enableLiquidGlass = nextEnableLiquidGlass;
      _globalBackground = path;
      _setGlobalBackgroundImage(path);
      _globalBackgroundImage = candidate;
      notifyListeners();
      unawaited(precacheGlobalBackground(context));
    } catch (_) {
      // Nothing has been persisted or made active until a candidate decodes.
      rethrow;
    }
  }

  /// Restores the shipped mint palette and system appearance.
  Future<void> restoreDefaults() async {
    _name = 'mint';
    _mode = ThemeMode.system;
    _manualMode = false;
    _globalBackground = '';
    _setGlobalBackgroundImage('');
    _globalBackgroundOpacity = 0.38;
    _enableLiquidGlass = true;
    _applyColors();
    await DBManager().insertKV('theme_color', _name);
    await DBManager().insertKV('theme_mode', 'system');
    await DBManager().insertKV('global_background_image', '');
    await DBManager().insertKV(_globalBackgroundSafetyKey, '');
    await DBManager().insertKV('global_background_opacity', '0.38');
    await DBManager().insertKV('enable_liquid_glass', 'true');
    notifyListeners();
  }

  static TideTheme of(BuildContext context, {bool listen = true}) {
    return listen
        ? TideBotThemeProvider.of(context)
        : (context
                  .dependOnInheritedWidgetOfExactType<_TideThemeWidget>()
                  ?.theme ??
              TideTheme());
  }
}

enum _BackgroundRegion { header, content, footer }

class _TideThemeWidget extends InheritedNotifier<TideTheme> {
  const _TideThemeWidget({required this.theme, required super.child})
    : super(notifier: theme);
  final TideTheme theme;
}

class TideBotThemeProvider extends StatelessWidget {
  final TideTheme theme;
  final Widget child;
  const TideBotThemeProvider({
    super.key,
    required this.theme,
    required this.child,
  });
  static TideTheme of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<_TideThemeWidget>();
    return w?.theme ?? TideTheme();
  }

  @override
  Widget build(BuildContext context) =>
      _TideThemeWidget(theme: theme, child: child);
}
