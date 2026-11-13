import 'dart:async';

/// Shared deadlines for asynchronous plugin work. CPU execution limits are
/// deliberately independent of these network and lifecycle budgets.
class PluginTimeouts {
  static const startup = Duration(minutes: 6);
  static const call = Duration(minutes: 6);
  static const host = Duration(minutes: 6, seconds: 10);
  static const network = Duration(minutes: 5, seconds: 30);
  static const media = Duration(minutes: 5, seconds: 30);
  static const operation = Duration(minutes: 10);
}

class PluginOperationCancelled implements Exception {
  const PluginOperationCancelled();
  @override
  String toString() => '操作已取消';
}

/// Cancellation is cooperative during file preparation and immediate for an
/// active runtime. Once package publication begins, finish its atomic commit.
class PluginOperation {
  bool _cancelled = false;
  bool _committing = false;
  bool _disposed = false;
  bool _timedOut = false;
  final _callbacks = <void Function()>{};
  void Function()? onChanged;
  Timer? _timer;
  bool get canCancel => !_cancelled && !_committing && !_disposed;
  bool get cancelled => _cancelled;

  void startDeadline() {
    _timer = Timer(PluginTimeouts.operation, () {
      if (canCancel) {
        _timedOut = true;
        cancel();
      }
    });
  }

  bool cancel() {
    if (!canCancel) return false;
    _cancelled = true;
    for (final callback in _callbacks.toList()) {
      callback();
    }
    onChanged?.call();
    return true;
  }

  void check() {
    if (_timedOut) throw TimeoutException('插件操作超过 10 分钟');
    if (_cancelled) throw const PluginOperationCancelled();
  }

  void Function() listen(void Function() callback) {
    check();
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }

  void beginCommit() {
    check();
    _committing = true;
    onChanged?.call();
  }

  void endCommit() {
    _committing = false;
    onChanged?.call();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _callbacks.clear();
    onChanged = null;
  }
}
