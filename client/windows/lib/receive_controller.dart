import 'dart:async';
import 'dart:collection';

import 'package:tug_core/tug_core.dart';

import 'settings.dart';

abstract interface class NotificationSink {
  Future<void> show(ReceivedMessage message);
  Future<void> dispose();
}

enum AppPage { messages, settings }

class ReceiveController extends ControllerNotifier {
  ReceiveController({
    required this.store,
    required this.startup,
    required this.notifications,
    TugReceiver? receiver,
  }) : receiver = receiver ?? TugReceiver(receiving: false);

  final SettingsStore store;
  final StartupRegistration startup;
  final NotificationSink notifications;
  final TugReceiver receiver;
  AppSettings settings = const AppSettings();
  StartupState startupState = const StartupState(
    enabled: false,
    registered: false,
  );
  AppPage page = AppPage.messages;
  String? error;
  String? notificationDiagnostic;
  String? activationDiagnostic;
  String? historyDiagnostic;
  String? selectedMessageId;
  bool saving = false;
  bool ready = false;
  bool _closed = false;
  bool _storageReady = false;
  bool _draining = false;
  final _pendingNotifications = ListQueue<ReceivedMessage>();
  Future<void>? _notificationWork;
  Future<void>? _shutdownFuture;
  Future<void>? _initializationFuture;
  Future<void>? _historyWork;
  List<ReceivedMessage>? _pendingHistory;
  RecentHistory _history = RecentHistory();
  final _historySeen = <String>{};
  bool _historyLoaded = false;
  Completer<void>? _saveFinished;
  StreamSubscription<ReceiverEvent>? _subscription;

  ReceiverSnapshot get snapshot {
    final current = receiver.snapshot;
    return ReceiverSnapshot(
      status: current.status,
      receiving: current.receiving,
      diagnostic: current.diagnostic,
      retryAt: current.retryAt,
      messages: _history.messages,
    );
  }

  bool get canSave => _storageReady && !_closed && !saving;

  Future<void> initialize() => _initializationFuture ??= _initialize();

  Future<void> _initialize() async {
    if (_closed) return;
    try {
      final saved = await store.loadHistory();
      if (_closed) return;
      _history = RecentHistory(saved);
      _historySeen.addAll(saved.map((message) => message.id));
      _historyLoaded = true;
    } catch (_) {
      historyDiagnostic = AppText.historyReadFailed;
    }
    if (_closed) return;
    _subscription = receiver.events.listen((event) {
      if (_closed) return;
      if (event is MessageEvent) {
        if (!_rememberMessage(event.message)) return;
        _saveHistory();
        if (_pendingNotifications.length >= TugReceiver.maxMessages) {
          _pendingNotifications.removeFirst();
          notificationDiagnostic = 'Notification queue full. Older alerts skipped; messages are saved.';
        }
        _pendingNotifications.addLast(event.message);
        if (!_draining) _notificationWork = _drainNotifications();
      }
      notifyListeners();
    });
    try {
      final saved = await store.load();
      if (_closed) return;
      _storageReady = true;
      settings = saved ?? const AppSettings();
      if (saved == null) {
        await store.save(settings);
        if (_closed) return;
        try {
          await startup.setEnabled(true);
        } catch (_) {
          error = 'Could not enable startup. Check permissions and try again.';
        }
      }
      try {
        startupState = await startup.read();
      } catch (_) {
        startupState = const StartupState(
          enabled: false,
          registered: false,
          diagnostic: 'Cannot read startup status. Settings are unchanged.',
        );
      }
      if (_closed) return;
      final configuration = settings.configuration;
      if (configuration != null) {
        await receiver.updateConfiguration(configuration);
      }
      if (_closed) return;
      if (settings.receiving) await receiver.start();
    } catch (_) {
      _storageReady = false;
      error = 'Cannot access settings. Saved settings are unchanged; auto-connect is off.';
    }
    if (_closed) return;
    page = settings.configuration == null ? AppPage.settings : AppPage.messages;
    ready = true;
    notifyListeners();
  }

  Future<bool> saveTarget(String address, String token) async {
    if (!canSave) return false;
    ReceiverConfig configuration;
    try {
      configuration = ReceiverConfig(address, token);
    } on ConfigurationException catch (failure) {
      error = failure.reason;
      notifyListeners();
      return false;
    }
    return _save(
      settings.copyWith(configuration: configuration),
      () => receiver.updateConfiguration(configuration),
    );
  }

  Future<bool> setReceiving(bool receiving) => _save(
    settings.copyWith(receiving: receiving),
    () => receiving ? receiver.start() : receiver.stop(),
  );

  Future<bool> _save(AppSettings next, Future<void> Function() apply) async {
    if (!canSave) return false;
    saving = true;
    _saveFinished = Completer<void>();
    error = null;
    notifyListeners();
    try {
      await store.save(next);
      settings = next;
      if (!_closed) await apply();
      return true;
    } catch (_) {
      error = 'Could not save settings. Settings and connection are unchanged.';
      return false;
    } finally {
      saving = false;
      _saveFinished?.complete();
      _saveFinished = null;
      if (!_closed) notifyListeners();
    }
  }

  Future<bool> setAutoStart(bool enabled) async {
    if (!canSave) return false;
    saving = true;
    _saveFinished = Completer<void>();
    error = null;
    notifyListeners();
    final previous = settings;
    try {
      final next = settings.copyWith(autoStart: enabled);
      await store.save(next);
      try {
        await startup.setEnabled(enabled);
      } catch (_) {
        await store.save(previous);
        rethrow;
      }
      settings = next;
      startupState = await startup.read();
      return true;
    } catch (_) {
      error = 'Could not update startup settings. Check Windows settings and try again.';
      try {
        startupState = await startup.read();
      } catch (_) {
        startupState = const StartupState(
          enabled: false,
          registered: false,
          diagnostic: 'Cannot read startup status.',
        );
      }
      return false;
    } finally {
      saving = false;
      _saveFinished?.complete();
      _saveFinished = null;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> refreshStartup() async {
    if (_closed) return;
    try {
      startupState = await startup.read();
    } catch (_) {
      startupState = const StartupState(
        enabled: false,
        registered: false,
        diagnostic: 'Cannot read startup status.',
      );
    }
    notifyListeners();
  }

  void openPage(AppPage next, {String? messageId}) {
    if (_closed) return;
    page = next;
    selectedMessageId = messageId;
    activationDiagnostic =
        messageId != null &&
            !snapshot.messages.any((message) => message.id == messageId)
        ? AppText.messageUnavailable
        : null;
    notifyListeners();
  }

  Future<void> reconnect() => receiver.reconnect();

  Future<void> testNotification() async {
    if (_closed) return;
    final now = DateTime.now().toUtc();
    try {
      await notifications.show(
        ReceivedMessage(
          id: 'test',
          title: AppText.testNotificationTitle,
          body: AppText.testNotificationBody,
          timestamp: now,
          receivedAt: now,
        ),
      );
      notificationDiagnostic =
          'Test notification sent. Windows may hide the banner.';
    } catch (_) {
      notificationDiagnostic = AppText.notificationUnavailable;
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _drainNotifications() async {
    _draining = true;
    try {
      while (!_closed && _pendingNotifications.isNotEmpty) {
        final message = _pendingNotifications.removeFirst();
        try {
          await notifications.show(message);
        } catch (_) {
          notificationDiagnostic = AppText.notificationFailed;
          if (!_closed) notifyListeners();
        }
      }
    } finally {
      _draining = false;
    }
  }

  bool _rememberMessage(ReceivedMessage message) {
    if (!_historySeen.add(message.id)) return false;
    if (_historySeen.length > TugReceiver.maxSeenIds) {
      _historySeen.remove(_historySeen.first);
    }
    return _history.add(message);
  }

  void _saveHistory() {
    if (!_historyLoaded) return;
    _pendingHistory = _history.messages;
    _historyWork ??= _writeHistory();
  }

  Future<void> _writeHistory() async {
    try {
      while (_pendingHistory != null) {
        final messages = _pendingHistory!;
        _pendingHistory = null;
        try {
          await store.saveHistory(messages);
          historyDiagnostic = null;
        } catch (_) {
          historyDiagnostic = AppText.historySaveFailed;
        }
      }
    } finally {
      _historyWork = null;
      if (!_closed) notifyListeners();
    }
  }

  void _captureRecentMessages() {
    bool changed = false;
    for (final message in receiver.snapshot.messages.reversed) {
      changed = _rememberMessage(message) || changed;
    }
    if (changed) _saveHistory();
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    _captureRecentMessages();
    _closed = true;
    final cleanup = receiver.dispose();
    if (_saveFinished != null) await _saveFinished!.future;
    _pendingNotifications.clear();
    await _subscription?.cancel();
    await cleanup;
    await _historyWork;
    if (_notificationWork != null) await _notificationWork;
    await notifications.dispose();
    super.dispose();
  }
}

class ControllerNotifier {
  final _listeners = <void Function()>[];
  bool _notifierDisposed = false;

  void addListener(void Function() listener) {
    if (!_notifierDisposed) _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notifyListeners() {
    if (_notifierDisposed) return;
    for (final listener in List.of(_listeners)) {
      if (_listeners.contains(listener)) listener();
    }
  }

  void dispose() {
    _notifierDisposed = true;
    _listeners.clear();
  }
}
