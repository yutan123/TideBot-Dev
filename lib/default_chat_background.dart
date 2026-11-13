import 'package:flutter/material.dart';

import 'theme.dart';

/// Muted tide colors keep the conversation canvas distinct from its controls.
class DefaultChatBackground extends StatelessWidget {
  const DefaultChatBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _TideCanvas(
            isDark: theme.isDark,
            primary: theme.primary,
            accent: theme.primaryLight,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _TideCanvas extends CustomPainter {
  const _TideCanvas({
    required this.isDark,
    required this.primary,
    required this.accent,
  });

  final bool isDark;
  final Color primary;
  final Color accent;

  Color _tone(Color color, double lightness) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation(isDark ? .22 : .24)
        .withLightness(lightness)
        .toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0, .5, 1],
          colors: isDark
              ? [_tone(primary, .135), _tone(accent, .16), _tone(primary, .19)]
              : [_tone(primary, .86), _tone(accent, .90), _tone(primary, .80)],
        ).createShader(rect),
    );
    // Broad translucent contours suggest water without competing with text.
    for (var i = 0; i < 4; i++) {
      final y = size.height * (.53 + i * .115);
      final path = Path()
        ..moveTo(-size.width * .1, y)
        ..cubicTo(
          size.width * .22,
          y - size.height * .14,
          size.width * .60,
          y + size.height * .16,
          size.width * 1.1,
          y - size.height * .06,
        )
        ..lineTo(size.width * 1.1, size.height)
        ..lineTo(-size.width * .1, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = (isDark ? _tone(primary, .65) : _tone(accent, .96))
              .withValues(alpha: isDark ? .025 : .085),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TideCanvas oldDelegate) =>
      oldDelegate.isDark != isDark ||
      oldDelegate.primary != primary ||
      oldDelegate.accent != accent;
}
