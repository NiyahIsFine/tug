import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tug_core/tug_core.dart';

import 'bridge.dart';
import 'settings.dart';

abstract interface class PageNotifications {
  Future<void> initialize();
  Future<bool> enabled();
  Future<void> requestPermission();
  Future<void> test();
}

abstract interface class ReceiverService {
  Future<bool> isRunning();
  Future<void> start();
  Future<void> stop();
  void send(Map<String, Object?> command);
  void addCallback(void Function(Object) callback);
  void removeCallback(void Function(Object) callback);
}

final class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.service,
    required this.notifications,
  }) {
    bridge = ServiceBridge(send: service.send);
    bridge.setEventsEnabled(false);
    service.addCallback(bridge.receive);
    _subscription = bridge.updates.listen((data) {
      if (_visible && !_disposed && !_stopping) {
        _apply(data);
        notifyListeners();
      }
    });
  }

  final AndroidStore store;
  final ReceiverService service;
  final PageNotifications notifications;
  late final ServiceBridge bridge;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Map<String, Object?>? _snapshot;
  List<Map<String, Object?>> _messages = [];
  String? _historyError;
  AppPreferences preferences = const AppPreferences();
  String server = '';
  String? error;
  String? notice;
  bool hasToken = false;
  bool serviceRunning = false;
  bool notificationsEnabled = false;
  bool? backgroundRestricted;
  bool ready = false;
  bool _visible = false;
  bool _disposed = false;
  bool _stopping = false;
  bool _refreshPending = false;
  bool _resumeSuppressed = false;
  bool _starting = false;
  int _operations = 0;
  int _generation = 0;
  int _visibilityGeneration = 0;

  bool get busy => _operations > 0;
  bool get canStop => serviceRunning || _starting;
  String get status =>
      _snapshot?['status'] as String? ??
      (hasToken ? 'stopped' : 'unconfigured');
  String? get diagnostic => _snapshot?['diagnostic'] as String?;
  String? get platformError => _snapshot?['platform_error'] as String?;
  String? get historyError => _historyError;
  DateTime? get retryAt =>
      DateTime.tryParse(_snapshot?['retry_at'] as String? ?? '');
  List<Map<String, Object?>> get messages => List.unmodifiable(_messages);

  void _apply(Map<String, Object?> data) {
    _snapshot = data;
    if (data['messages'] is List) {
      _messages = (data['messages'] as List)
          .whereType<Map>()
          .map((message) => Map<String, Object?>.from(message))
          .take(TugReceiver.maxMessages)
          .toList();
    }
    _historyError = data['history_error'] as String?;
    server = data['server'] as String? ?? server;
    hasToken = data['has_token'] == true;
    notificationsEnabled = data['notifications_enabled'] == true;
    if (data['receiving'] == false) serviceRunning = false;
  }

  Future<void> setVisible(bool visible) async {
    if (_disposed || _visible == visible) return;
    _visible = visible;
    ++_visibilityGeneration;
    bridge.setEventsEnabled(visible);
    if (visible) {
      if (busy) {
        _refreshPending = true;
      } else {
        await refresh();
      }
    }
  }

  Future<void> _perform(
    Future<void> Function() action, {
    bool preempt = false,
  }) async {
    if (_disposed || (busy && !preempt)) return;
    ++_operations;
    error = null;
    notice = null;
    notifyListeners();
    try {
      await action();
    } on ConfigurationException catch (failure) {
      if (!_disposed) error = failure.reason;
    } on IntentConflict {
      if (!_disposed) {
        error = 'Receive state changed. Check the current status.';
      }
    } catch (_) {
      if (!_disposed) {
        error =
            'Operation failed. Check permissions and storage, then try again.';
      }
    } finally {
      --_operations;
      if (!_disposed) {
        notifyListeners();
        if (!busy && _visible && _refreshPending) {
          _refreshPending = false;
          unawaited(refresh());
        }
      }
    }
  }

  Future<void> refresh() => _perform(() => _refresh(allowResume: true));

  Future<void> _refresh({required bool allowResume}) async {
    final generation = _generation;
    final visibility = _visibilityGeneration;
    await notifications.initialize();
    var permission = await notifications.enabled();
    if (_disposed || generation != _generation) return;
    if (_visible && visibility == _visibilityGeneration) {
      final firstOpen = await store.claimNotificationPrompt();
      if (_disposed || generation != _generation) return;
      if (firstOpen &&
          !permission &&
          _visible &&
          visibility == _visibilityGeneration) {
        await notifications.requestPermission();
        if (_disposed || generation != _generation) return;
        permission = await notifications.enabled();
      }
    }
    try {
      backgroundRestricted = await store.readBackgroundRestricted();
    } catch (_) {
      backgroundRestricted = null;
    }
    final savedPreferences = await store.readPreferences();
    final running = await service.isRunning();
    if (_disposed || generation != _generation) return;
    preferences = savedPreferences;
    notificationsEnabled = permission;
    serviceRunning = running;
    if (running) {
      final response = await bridge.request('snapshot');
      if (_disposed || generation != _generation) return;
      _apply(Map<String, Object?>.from(response['snapshot'] as Map));
      notificationsEnabled = permission;
    } else {
      bridge.detach();
      _snapshot = null;
      final configuration = await store.readConfiguration();
      final intent = await store.readIntent();
      if (_disposed || generation != _generation) return;
      try {
        final saved = await store.readHistory();
        if (_disposed || generation != _generation) return;
        _messages = saved.map((message) => message.toData()).toList();
        _historyError = null;
      } catch (_) {
        _historyError = 'Cannot load history. Saved data is unchanged. Unlock your device and try again.';
      }
      if (_disposed || generation != _generation) return;
      server = configuration?.address ?? '';
      hasToken = configuration != null;
      if (allowResume &&
          !_resumeSuppressed &&
          !_stopping &&
          intent.enabled &&
          configuration != null &&
          _visible &&
          visibility == _visibilityGeneration) {
        await _startService(intent, generation, visibility: visibility);
      }
    }
    if (!_disposed && generation == _generation) ready = true;
  }

  Future<void> saveConfiguration(String address, String token) =>
      _perform(() async {
        final generation = _generation;
        if (await service.isRunning()) {
          if (bridge.latest == null) await bridge.request('snapshot');
          if (_disposed || generation != _generation) return;
          final response = await bridge.request('configure', {
            'server': address,
            'token': token,
          });
          if (_disposed || generation != _generation) return;
          _apply(Map<String, Object?>.from(response['snapshot'] as Map));
        } else {
          final previous = await store.readConfiguration();
          if (_disposed || generation != _generation) return;
          final configuration = ReceiverConfig(
            address,
            token.isEmpty ? previous?.receiveToken ?? '' : token,
          );
          await store.saveConfiguration(configuration);
          if (_disposed || generation != _generation) return;
          server = configuration.address;
          hasToken = true;
        }
        notice = 'Settings saved.';
      });

  Future<void> start() async {
    if (_disposed || busy) return;
    _starting = true;
    try {
      await _perform(_start);
    } finally {
      _starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _resumeSuppressed = false;
    if (await service.isRunning()) {
      await _refresh(allowResume: false);
      return;
    }
    final intent = await store.readIntent();
    final configuration = await store.readConfiguration();
    if (configuration == null) {
      throw const ConfigurationException(AppText.configurationRequired);
    }
    if (_disposed || generation != _generation) return;
    final enabled = await store.setReceiving(
      true,
      expectedRevision: intent.revision,
    );
    if (_disposed || generation != _generation) {
      await _cancelStart(enabled);
      return;
    }
    await _startService(enabled, generation);
  }

  Future<void> _cancelStart(ReceiveIntent intent) async {
    try {
      await store.setReceiving(false, expectedRevision: intent.revision);
    } on IntentConflict {
      return;
    }
  }

  Future<void> _startService(
    ReceiveIntent intent,
    int generation, {
    int? visibility,
  }) async {
    _starting = true;
    if (!_disposed) notifyListeners();
    try {
      await _launchService(intent, generation, visibility: visibility);
    } finally {
      _starting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _launchService(
    ReceiveIntent intent,
    int generation, {
    int? visibility,
  }) async {
    if (visibility != null) {
      if (_disposed ||
          generation != _generation ||
          !_visible ||
          visibility != _visibilityGeneration) {
        return;
      }
      await store.allowForegroundResume(expectedRevision: intent.revision);
    }
    final current = await store.readIntent();
    if (_disposed ||
        generation != _generation ||
        !current.enabled ||
        current.revision != intent.revision ||
        (visibility != null &&
            (!_visible || visibility != _visibilityGeneration))) {
      return;
    }
    bridge.detach();
    try {
      await service.start();
    } catch (_) {
      if (visibility == null) await _cancelStart(intent);
      rethrow;
    }
    final latest = await store.readIntent();
    if (_disposed ||
        generation != _generation ||
        !latest.enabled ||
        latest.revision != intent.revision) {
      if (!latest.enabled) await service.stop();
      return;
    }
    serviceRunning = true;
    final response = await bridge.request('snapshot');
    if (!_disposed && generation == _generation) {
      _apply(Map<String, Object?>.from(response['snapshot'] as Map));
      if (visibility != null) {
        preferences = const AppPreferences();
      }
      ready = true;
    }
  }

  Future<void> stop() async {
    if (_disposed || _stopping) return;
    _stopping = true;
    _resumeSuppressed = true;
    ++_generation;
    await _perform(() async {
      Object? failure;
      try {
        await store.setReceiving(false);
      } catch (error) {
        failure = error;
      }
      if (await service.isRunning()) {
        try {
          final response = await bridge.request('stop');
          if (!_disposed) {
            _apply(Map<String, Object?>.from(response['snapshot'] as Map));
          }
        } catch (_) {
          if (await service.isRunning()) await service.stop();
          failure ??= StateError('Service stop required fallback.');
        }
      }
      if (_disposed) return;
      serviceRunning = false;
      _snapshot = null;
      bridge.detach();
      if (failure != null) {
        throw const ConfigurationException(
          'Could not confirm Stop. Try again to prevent receiving on next launch.',
        );
      }
      notice = 'Receiving stopped. It stays off until you select Start.';
    }, preempt: true);
    _stopping = false;
  }

  Future<void> reconnect() => _perform(() async {
    final generation = _generation;
    final response = await bridge.request('reconnect');
    if (!_disposed && generation == _generation) {
      _apply(Map<String, Object?>.from(response['snapshot'] as Map));
    }
  });

  Future<void> testNotification() => _perform(() async {
    final generation = _generation;
    notificationsEnabled = await notifications.enabled();
    if (_disposed || generation != _generation) return;
    if (!notificationsEnabled) {
      await notifications.requestPermission();
      if (_disposed || generation != _generation) return;
      notificationsEnabled = await notifications.enabled();
      if (!notificationsEnabled) {
        notice = 'Notifications are off. Test not sent.';
        return;
      }
    }
    await notifications.test();
    notice = 'Test notification sent.';
  });

  @override
  void dispose() {
    if (_disposed) return;
    bridge.setEventsEnabled(false);
    _disposed = true;
    ++_generation;
    service.removeCallback(bridge.receive);
    unawaited(_subscription?.cancel());
    unawaited(bridge.dispose());
    super.dispose();
  }
}
