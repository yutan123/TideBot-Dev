import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'theme.dart';

/// TideBot compact popovers: solid surface, 24px corners, subtle outline,
/// no dimming, 8px anchor gap, automatic safe-area/keyboard avoidance.
/// Menus default to 164px wide and 50px rows. Use the trigger's own context.
Future<T?> showTidePopover<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double width = 164,
  bool preferAbove = false,
  Color? backgroundColor,
  double radius = 24,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final trigger = context.findRenderObject()! as RenderBox;
  final anchor =
      trigger.localToGlobal(Offset.zero, ancestor: overlay) & trigger.size;
  final theme = TideTheme.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    requestFocus: false,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 360),
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
    pageBuilder: (context, animation, secondaryAnimation) {
      final media = MediaQuery.of(context);
      final insets = EdgeInsets.fromLTRB(
        math.max(16, media.padding.left),
        math.max(12, media.padding.top),
        math.max(16, media.padding.right),
        math.max(12, math.max(media.padding.bottom, media.viewInsets.bottom)),
      );
      return AnimatedBuilder(
        animation: animation,
        child: Builder(builder: builder),
        builder: (context, child) {
          // One restrained overshoot; reverse closes directly into the trigger.
          final opening = animation.status != AnimationStatus.reverse;
          final t = opening
              ? const Cubic(0.2, 0.9, 0.3, 1.12).transform(animation.value)
              : Curves.easeOutCubic.transform(animation.value);
          return CustomSingleChildLayout(
            delegate: TidePopoverLayout(
              anchor: anchor,
              insets: insets,
              width: width,
              preferAbove: preferAbove,
              progress: t,
            ),
            child: Opacity(
              opacity: (animation.value / 0.18).clamp(0, 1),
              child: Transform.scale(
                scale: 0.08 + 0.92 * t,
                child: Material(
                  color: backgroundColor ?? theme.surface,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(radius),
                    side: BorderSide(
                      color: theme.textStrong.withValues(alpha: 0.08),
                    ),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: child,
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Geometry is public to allow regression checks without a native view.
class TidePopoverLayout extends SingleChildLayoutDelegate {
  const TidePopoverLayout({
    required this.anchor,
    required this.insets,
    required this.width,
    required this.preferAbove,
    this.progress = 1,
  });
  final Rect anchor;
  final EdgeInsets insets;
  final double width;
  final bool preferAbove;
  final double progress;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final available = math.max(0.0, constraints.maxWidth - insets.horizontal);
    final w = math.min(width, available);
    final above = anchor.top - 8 - insets.top;
    final below = constraints.maxHeight - insets.bottom - anchor.bottom - 8;
    return BoxConstraints(
      minWidth: w,
      maxWidth: w,
      maxHeight: math.max(0, math.max(above, below)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = anchor.left.clamp(
      insets.left,
      math.max(insets.left, size.width - insets.right - childSize.width),
    );
    final above = anchor.top - 8 - childSize.height;
    final below = anchor.bottom + 8;
    final fitsAbove = above >= insets.top;
    final fitsBelow = below + childSize.height <= size.height - insets.bottom;
    final useAbove = preferAbove
        ? fitsAbove || !fitsBelow
        : !fitsBelow && fitsAbove;
    final top = (useAbove ? above : below).clamp(
      insets.top,
      math.max(insets.top, size.height - insets.bottom - childSize.height),
    );
    final end = Offset(left.toDouble(), top.toDouble());
    final origin = anchor.center - childSize.center(Offset.zero);
    return Offset.lerp(origin, end, progress)!;
  }

  @override
  bool shouldRelayout(TidePopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      insets != oldDelegate.insets ||
      width != oldDelegate.width ||
      preferAbove != oldDelegate.preferAbove ||
      progress != oldDelegate.progress;
}

class TidePopoverItem<T> extends StatelessWidget {
  const TidePopoverItem({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final T value;

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    return InkWell(
      onTap: () => Navigator.of(context).pop(value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 50),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 22, color: theme.textStrong),
              const SizedBox(width: 18),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'TideFont',
                    fontSize: 16,
                    color: theme.textStrong,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
