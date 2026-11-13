import 'package:flutter/foundation.dart';

/// Invalidates profile snapshots after a persisted name or avatar change.
class UserProfileChanges {
  static final revision = ValueNotifier<int>(0);
  static void notify() => revision.value++;
}
