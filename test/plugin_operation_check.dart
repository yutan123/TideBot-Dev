import 'package:tide_bot/plugin_operation.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  final operation = PluginOperation();
  var stopped = 0;
  var detached = 0;
  operation.listen(() => stopped++);
  final remove = operation.listen(() => detached++);
  remove();
  require(operation.cancel(), 'First cancellation must be accepted');
  require(!operation.cancel(), 'Cancellation must be idempotent');
  require(stopped == 1 && detached == 0, 'Only active cleanup runs once');
  try {
    operation.check();
    throw StateError('Cancelled work must not resume');
  } on PluginOperationCancelled {
    // Expected: queued work checks this before acquiring resources.
  }
  operation.dispose();

  final committing = PluginOperation();
  committing.beginCommit();
  require(!committing.canCancel, 'Atomic publication cannot be interrupted');
  require(!committing.cancel(), 'Cancel must not interrupt an atomic commit');
  committing.endCommit();
  require(committing.cancel(), 'Cancellation resumes after publication');
  committing.dispose();

  final finished = PluginOperation();
  finished.startDeadline();
  finished.dispose();
  require(!finished.cancel(), 'Finished operations cannot cancel a later run');
  require(
    PluginTimeouts.network < PluginTimeouts.call,
    'Inner network deadline must leave time for the tool result',
  );
  require(
    PluginTimeouts.call < PluginTimeouts.host,
    'Host IPC must allow the full runtime deadline',
  );
  print('Plugin operation checks passed');
}
