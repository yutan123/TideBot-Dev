import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';
import 'tide_liquid_glass.dart';

// ========== 全局弹性点击包装器 ==========
class TideHaptics {
  TideHaptics._();
  static bool _enabled = true;
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _enabled =
        (await SharedPreferences.getInstance()).getBool(
          'tide_haptics_enabled',
        ) ??
        true;
    _loaded = true;
  }

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    _loaded = true;
    await (await SharedPreferences.getInstance()).setBool(
      'tide_haptics_enabled',
      value,
    );
  }

  static const MethodChannel _channel = MethodChannel('tidebot.native.channel');

  static void _impact(int duration, int amplitude, Future<void> fallback) {
    if (!_enabled) return;
    _channel
        .invokeMethod<bool>('vibrate', {
          'duration': duration,
          'amplitude': amplitude,
        })
        .catchError((_) => false);
    fallback.catchError((_) => HapticFeedback.vibrate());
  }

  static void tap() => _impact(18, 105, HapticFeedback.selectionClick());
  static void selection() => _impact(16, 90, HapticFeedback.selectionClick());
  static void confirm() => _impact(30, 145, HapticFeedback.lightImpact());
  static void warning() => _impact(44, 175, HapticFeedback.mediumImpact());
  static void error() => _impact(70, 220, HapticFeedback.heavyImpact());
  static void longPress() => _impact(38, 155, HapticFeedback.mediumImpact());
}

class BouncyTap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scaleAmount;
  const BouncyTap({
    super.key,
    required this.child,
    this.onTap,
    this.scaleAmount = 0.05,
  });
  @override
  State<BouncyTap> createState() => _BouncyTapState();
}

class _BouncyTapState extends State<BouncyTap>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _scale;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 1.0 - widget.scaleAmount,
    ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _c.reverse();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        _c.forward();
        TideHaptics.tap();
      },
      onTapUp: (_) {
        _c.reverse();
        widget.onTap?.call();
      },
      onTapCancel: () => _c.reverse(),
      child: AnimatedBuilder(
        animation: _scale,
        builder: (c, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}

// ========== 机器人默认头像 ==========
class TideBotAvatar extends StatelessWidget {
  final String name;
  final String? path;
  final double size;
  final double? radius;

  const TideBotAvatar({
    super.key,
    required this.name,
    this.path,
    this.size = 52,
    this.radius,
  });

  Color _colorForName() {
    const colors = [
      Color(0xFF5578D8),
      Color(0xFFB05E91),
      Color(0xFF2D9A88),
      Color(0xFFB7773E),
      Color(0xFF7B6AC8),
      Color(0xFF3C91B2),
      Color(0xFFC05B67),
      Color(0xFF5B8E63),
    ];
    var hash = 0;
    for (final code in name.trim().codeUnits) {
      hash = ((hash * 31) + code) & 0x7fffffff;
    }
    return colors[hash % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final file = path == null || path!.isEmpty ? null : File(path!);
    final exists = file != null && file.existsSync();

    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius ?? size / 2),
        child: exists
            ? Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallback(),
              )
            : _fallback(),
      ),
    );
  }

  Widget _fallback() {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? 'T'
        : String.fromCharCode(trimmed.runes.first);
    return ColoredBox(
      color: _colorForName(),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.42,
            height: 1,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            fontFamily: 'TideFont',
          ),
        ),
      ),
    );
  }
}

// ========== 自定义弹窗系统 ==========
Future<T?> showTideDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return TideDialogs.show<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
  );
}

/// A consistent, app-owned dialog shell. It provides the inset and handles
/// safe-area behavior while callers supply their own content.
class TideDialogSurface extends StatelessWidget {
  final Widget? child;
  final Widget? content;
  final Widget? title;
  final List<Widget>? actions;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry? contentPadding;
  final Color? backgroundColor;
  final AlignmentGeometry alignment;

  const TideDialogSurface({
    super.key,
    this.child,
    this.content,
    this.title,
    this.actions,
    this.margin = const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
    this.contentPadding,
    this.backgroundColor,
    this.alignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final body =
        child ??
        Container(
          decoration: BoxDecoration(
            color: backgroundColor ?? TideTheme.of(context).surface,
            borderRadius: BorderRadius.circular(22),
          ),
          padding: contentPadding ?? const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null) title!,
              if (title != null && content != null) const SizedBox(height: 14),
              if (content != null) Flexible(child: content!),
              if (actions != null && actions!.isNotEmpty) ...[
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions!,
                ),
              ],
            ],
          ),
        );
    return SafeArea(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: margin,
          child: Material(type: MaterialType.transparency, child: body),
        ),
      ),
    );
  }
}

/// Provides a consistent left-edge drag-back gesture for custom routes and
/// dialogs without changing Android's normal system back behavior.
class TideEdgeBackGesture extends StatefulWidget {
  final Widget child;
  const TideEdgeBackGesture({super.key, required this.child});

  @override
  State<TideEdgeBackGesture> createState() => _TideEdgeBackGestureState();
}

class _TideEdgeBackGestureState extends State<TideEdgeBackGesture> {
  double? _startX;

  void _onStart(DragStartDetails details) {
    if (details.globalPosition.dx <= 28) _startX = details.globalPosition.dx;
  }

  void _onEnd(DragEndDetails details) {
    final start = _startX;
    _startX = null;
    if (start == null) return;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 280 && Navigator.of(context).canPop()) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onStart,
      onHorizontalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

class TideDialogs {
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: '',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) => builder(context),
      transitionBuilder: (context, anim, secAnim, child) => ScaleTransition(
        scale: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  static Widget glassContent({
    required BuildContext context,
    required List<Widget> children,
    double maxWidth = 0.92,
  }) {
    final theme = TideTheme.of(context);
    final content = Container(
      width: MediaQuery.of(context).size.width * maxWidth,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: theme.surface.withValues(
          alpha: theme.useLiquidGlass ? 0.96 : 0.94,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.border, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.useLiquidGlass ? 0.30 : 0.16,
            ),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
    return content;
  }

  static Widget glassButton(
    String label, {
    required VoidCallback onTap,
    Color? color,
    Color textColor = Colors.white,
  }) {
    return BouncyTap(
      onTap: onTap,
      child: Builder(
        builder: (ctx) {
          final c = color ?? TideTheme.of(ctx).primary;
          return Container(
            height: 44,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'TideFont',
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ========== 底部弹窗（半屏） ==========
Future<T?> showTideSheet<T>({
  required BuildContext context,
  required Widget child,
  double? height,
}) {
  final screenH = MediaQuery.of(context).size.height;
  final sheetH = height ?? screenH * 0.55;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) {
      final keyboardInset = MediaQuery.viewInsetsOf(ctx).bottom;
      final availableHeight = screenH - keyboardInset;
      final effectiveHeight = height == null
          ? screenH * 0.55
          : sheetH.clamp(0.0, availableHeight);
      return GestureDetector(
        onTap: () => Navigator.pop(ctx),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          height: availableHeight,
          color: Colors.transparent,
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: Builder(
              builder: (sheetContext) {
                final theme = TideTheme.of(sheetContext);
                final sheet = Container(
                  height: effectiveHeight,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.surface.withValues(
                      alpha: theme.useLiquidGlass ? 0.97 : 0.96,
                    ),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    border: Border.all(color: theme.border, width: 0.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 28,
                        offset: const Offset(0, -6),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.useLiquidGlass
                              ? Colors.white.withValues(alpha: 0.55)
                              : Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(child: child),
                    ],
                  ),
                );
                return sheet;
              },
            ),
          ),
        ),
      );
    },
  );
}

// ========== 粒子系统 ==========
class Particle {
  double x, y, vx, vy, size;
  Color color;
  double life = 1.0;
  Particle(this.x, this.y, this.vx, this.vy, this.size, this.color);
  void update() {
    x += vx;
    y += vy;
    vy += 0.3;
    life -= 0.025;
    size *= 0.94;
  }
}

class ExplosionPainter extends CustomPainter {
  final List<Particle> ps;
  ExplosionPainter(this.ps);
  @override
  void paint(Canvas c, Size s) {
    final pt = Paint()..style = PaintingStyle.fill;
    for (var p in ps) {
      if (p.life > 0) {
        pt.color = p.color.withValues(alpha: p.life.clamp(0.0, 1.0));
        c.drawCircle(Offset(p.x, p.y), p.size, pt);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ExplosionPainter o) => true;
}

class ParticleOverlay extends StatefulWidget {
  final Widget child;
  final List<Offset> origins;
  final VoidCallback? onDone;
  const ParticleOverlay({
    super.key,
    required this.child,
    required this.origins,
    this.onDone,
  });
  @override
  State<ParticleOverlay> createState() => _ParticleOverlayState();
}

class _ParticleOverlayState extends State<ParticleOverlay>
    with SingleTickerProviderStateMixin {
  final List<Particle> _ps = [];
  late AnimationController _c;
  final _r = Random();
  bool _initialized = false;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _c.addListener(
      () => setState(() {
        for (var p in _ps) p.update();
      }),
    );
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone?.call();
    });
    _c.forward();
  }

  void _initParticles() {
    if (_initialized) return;
    _initialized = true;
    final theme = TideTheme.of(context);
    final colors = [
      theme.primary,
      theme.primaryLight,
      theme.primary.withValues(alpha: 0.7),
      theme.primaryLight.withValues(alpha: 0.5),
    ];
    for (var o in widget.origins) {
      for (int i = 0; i < 30; i++) {
        // 保持30个粒子
        final angle = _r.nextDouble() * 6.2832;
        final spd = 1.0 + _r.nextDouble() * 6;
        final sx = 1.5 + _r.nextDouble() * 5;
        final ox = (_r.nextDouble() - 0.5) * 80;
        final oy = (_r.nextDouble() - 0.5) * 50;
        _ps.add(
          Particle(
            o.dx + ox,
            o.dy + oy,
            cos(angle) * spd,
            sin(angle) * spd - 3,
            sx,
            colors[_r.nextInt(colors.length)],
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _initParticles());
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: ExplosionPainter(_ps)),
          ),
        ),
      ],
    );
  }
}

// ========== 毛玻璃卡片 ==========
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool liquid;
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.onTap,
    this.onLongPress,
    this.liquid = false,
  });
  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final content = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: theme.isWechat
              ? theme.surface
              : theme.glass.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(theme.isWechat ? 5 : radius),
          border: Border.all(color: TideTheme.of(context).border, width: 0.5),
          boxShadow: theme.isWechat
              ? []
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: child,
      ),
    );
    if (!liquid || !TideTheme.of(context).useLiquidGlass) return content;
    return TideLiquidGlass(
      radius: radius,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class FrostCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool liquid;
  final bool transparent;
  final bool premiumGlass;
  const FrostCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.radius = 20,
    this.onTap,
    this.onLongPress,
    this.liquid = false,
    this.transparent = false,
    this.premiumGlass = true,
  });
  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final card = Padding(
      padding: margin,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: theme.isWechat
                ? theme.surface
                : transparent
                ? Colors.transparent
                : theme.useLiquidGlass
                ? theme.glass.withValues(alpha: theme.isDark ? 0.36 : 0.48)
                : theme.glass.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(theme.isWechat ? 5 : radius),
            border: Border.all(color: TideTheme.of(context).border, width: 0.5),
            boxShadow: theme.isWechat
                ? []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: child,
        ),
      ),
    );
    if (!liquid || !TideTheme.of(context).useLiquidGlass) return card;
    return Padding(
      padding: margin,
      child: TideLiquidGlass(
        radius: radius,
        premium: premiumGlass,
        child: GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

// ========== 时间格式化 ==========
String fmtTime(dynamic ts) {
  if (ts == null) return '';
  if (ts is String) {
    final dt = DateTime.tryParse(ts);
    if (dt != null)
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return ts;
  }
  if (ts is int) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
  return ts.toString();
}

String formatTime(dynamic ts) {
  if (ts == null) return '';
  DateTime dt;
  if (ts is String) {
    dt = DateTime.tryParse(ts) ?? DateTime.now();
  } else if (ts is int) {
    dt = DateTime.fromMillisecondsSinceEpoch(ts);
  } else {
    return ts.toString();
  }
  return '${dt.month}月${dt.day}日 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

String fmtDate(dynamic ts) {
  if (ts == null) return '';
  if (ts is String) {
    final dt = DateTime.tryParse(ts);
    if (dt != null) return '${dt.year}.${dt.month}.${dt.day}';
    return ts;
  }
  if (ts is int) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${dt.year}.${dt.month}.${dt.day}';
  }
  return ts.toString();
}
