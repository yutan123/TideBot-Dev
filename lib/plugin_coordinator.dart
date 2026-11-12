import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';

/// Native locks are shared by foreground/background Flutter engines. No lock is
/// held by plugin JS; only bounded host operations enter a storage critical section.
class _PluginLease {
  bool active = true;
}

class PluginCoordinator {
  static const _channel = MethodChannel('tidebot.plugin.coordination');
  static final _heldKey = Object();
  static final _localQueues = <String, Future<void>>{};
  static final _localEpochs = <String, int>{};
  static final _listeners = <void Function(String, int)>{};
  static bool _bound = false;
  static void listen(void Function(String, int) listener) {
    _listeners.add(listener);
    if (_bound || !Platform.isAndroid) return;
    _bound = true;
    // Avoid retaining the zone of a lifecycle transaction in future callbacks.
    Zone.root.run(
      () => _channel.setMethodCallHandler((call) async {
        if (call.method == 'invalidated') {
          for (final listener in _listeners.toList()) {
            final args = call.arguments as Map;
            listener(args['id'] as String, args['epoch'] as int);
          }
        }
      }),
    );
  }

  static Future<T> locked<T>(String key, Future<T> Function() work) async {
    final held =
        Zone.current[_heldKey] as Map<String, _PluginLease>? ??
        <String, _PluginLease>{};
    if (held[key]?.active == true) return work();
    final lease = _PluginLease();
    final ticket =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    final args = {'key': key, 'ticket': ticket};
    Completer<void>? local;
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('acquire', args);
    } else {
      final previous = _localQueues[key] ?? Future<void>.value();
      local = Completer<void>();
      _localQueues[key] = local.future;
      await previous;
    }
    try {
      return await runZoned(
        work,
        zoneValues: {
          _heldKey: {...held, key: lease},
        },
      );
    } finally {
      lease.active = false;
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('release', args);
      } else {
        local!.complete();
        if (identical(_localQueues[key], local.future))
          _localQueues.remove(key);
      }
    }
  }

  static Future<int> epoch(String id) async => Platform.isAndroid
      ? (await _channel.invokeMethod<int>('epoch', {'id': id}))!
      : _localEpochs[id] ?? 0;

  static Future<void> invalidate(String id) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('invalidate', {'id': id});
    } else {
      _localEpochs[id] = (_localEpochs[id] ?? 0) + 1;
    }
    // Also invalidate synchronously in the requesting isolate, before it starts
    // a replacement. The later native broadcast carries its epoch to avoid
    // invalidating that replacement.
    final generation = await epoch(id);
    for (final listener in _listeners.toList()) {
      listener(id, generation);
    }
  }
}
