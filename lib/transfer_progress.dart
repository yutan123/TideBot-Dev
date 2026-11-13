import 'package:flutter/material.dart';
import 'data_transfer.dart';
import 'plugin_operation.dart';
import 'theme.dart';
import 'ui_components.dart';

/// Locks the complete selection flow and shows an app-styled busy dialog while
/// preparing, picking, saving or restoring data.
class TransferProgress {
  static bool _starting = false;
  static bool get isBusy => _starting || DataTransfer.isBusy;

  static Future<void> guard(Future<void> Function() action) async {
    if (_starting || DataTransfer.isBusy) return;
    _starting = true;
    try {
      await action();
    } finally {
      _starting = false;
    }
  }

  static Future<T> run<T>(
    BuildContext context,
    String label,
    Future<T> Function() action, {
    PluginOperation? operation,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    Route<dynamic>? route;
    final shown = TideDialogs.show<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        route = ModalRoute.of(dialogContext);
        final theme = TideTheme.of(dialogContext);
        return StatefulBuilder(
          builder: (context, refresh) {
            operation?.onChanged = () {
              if (dialogContext.mounted) refresh(() {});
            };
            return PopScope(
              canPop: false,
              child: TideDialogSurface(
                alignment: Alignment.bottomCenter,
                content: Row(
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: theme.primary,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Text(
                        operation?.cancelled == true ? '正在取消…' : label,
                        style: TextStyle(
                          color: theme.textStrong,
                          fontFamily: 'TideFont',
                        ),
                      ),
                    ),
                    if (operation != null) ...[
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: operation.canCancel
                            ? () {
                                operation.cancel();
                              }
                            : null,
                        style: TextButton.styleFrom(
                          foregroundColor: theme.primary,
                        ),
                        child: const Text('取消'),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    try {
      // Render the spinner before filesystem/database preparation starts.
      await WidgetsBinding.instance.endOfFrame;
      return await action();
    } finally {
      operation?.onChanged = null;
      final current = route;
      if (navigator.mounted && current != null && current.isActive) {
        navigator.removeRoute(current);
      }
      await shown;
    }
  }
}
