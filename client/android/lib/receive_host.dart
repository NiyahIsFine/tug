import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:tug_core/tug_core.dart';

import 'settings.dart';

abstract interface class MessageNotifications {
  Future<void> initialize();
  Future<bool> enabled();
  Future<void> show(ReceivedMessage message, int slot);
  Future<void> test();
}

final class AndroidReceiveHost {
  AndroidReceiveHost({
    required this.store,
    required this.notifications,
    required this.send,
    required this.stopService,
    required this.updateStatus,
    this.recordStartupFailure,
    TugReceiver? receiver,
  }) : receiver = receiver ?? TugReceiver(receiving: false);

  final AndroidStore store;
  final MessageNotifications notifications;
  final void Function(Map<String, Object?>) send;
  final Future<void> Function() stopService;
  final Future<void> Function(String) updateStatus;
  final Future<void> Function(String)? recordStartupFailure;
  final TugReceiver receiver;
  final session =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
  final _notificationQueue = ListQueue<ReceivedMessage>();
  StreamSubscription<ReceiverEvent>? _events;
  StreamSubscription<List<String>>? _network;
  Future<void> _commands = Future.value();
  Future<void>? _delivery;
  Future<void>? _historyWrite;
  List<ReceivedMessage>? _pendingHistory;
  RecentHistory _history = RecentHistory();
  final _historySeen = <String>{};
  bool _historyLoaded = false;
  String? _historyError;
  ReceiverConfig? _configuration;
  String? _clientId;
  bool _subscribed = false;
  int _viewRevision = -1;
  String? _platformError;
  String? _lastStatus;
  bool _notificationsEnabled = false;
  bool _closing = false;
  bool _disposed = false;
  bool _initialized = false;
  int _generation = 0;
  int _sequence = 0;
  int _notificationSlot = 0;
  int _notificationBytes = 0;

  Map<String, Object?> get snapshot => {
    ...receiver.snapshot.toData(),
    'messages': _history.messages.map((message) => message.toData()).toList(),
    'history_error': _historyError,
    'server': _configuration?.address,
    'has_token': _configuration != null,
    'notifications_enabled': _notificationsEnabled,
    'platform_error': _platformError,
  };

  Future<void> initialize({Stream<List<String>>? network}) =>
      _enqueue(() async {
        if (_initialized || _closing || _disposed) return;
        _initialized = true;
        final generation = _generation;
        _events = receiver.events.listen(_onEvent);
        try {
          final saved = await store.readHistory();
          if (!_current(generation)) return;
          _history = RecentHistory(saved);
          _historySeen.addAll(saved.map((message) => message.id));
          _historyLoaded = true;
        } catch (_) {
          _historyError = AppText.historyReadFailed;
        }
        if (!_current(generation)) return;
        try {
          await notifications.initialize();
          _notificationsEnabled = await notifications.enabled();
        } catch (_) {
          _platformError = AppText.notificationUnavailable;
        }
        try {
          final intent = await store.readIntent();
          _configuration = await store.readConfiguration();
          if (!_current(generation)) return;
          if (!intent.enabled || _configuration == null) {
            _closing = true;
            await receiver.stop();
            _publish();
            await stopService();
            return;
          }
          if (network != null) {
            _network = network.listen(
              (interfaces) {
                unawaited(
                  _enqueue(() async {
                    if (!_closing && !_disposed) {
                      await receiver.networkChanged(interfaces.isNotEmpty);
                    }
                  }),
                );
              },
              onError: (Object _) {
                _platformError = 'Network monitoring is unavailable. Automatic reconnect still works.';
                _publish();
              },
            );
          }
          await receiver.updateConfiguration(_configuration!);
          final latest = await store.readIntent();
          if (!_current(generation)) return;
          if (!latest.enabled || latest.revision != intent.revision) {
            _closing = true;
            await receiver.stop();
            await stopService();
            return;
          }
          await receiver.start();
          _publish();
        } catch (_) {
          if (_disposed) return;
          _platformError =
              'Cannot load settings. Unlock your device and select Start.';
          _closing = true;
          await receiver.stop();
          _publish();
          try {
            await recordStartupFailure?.call(_platformError!);
          } catch (_) {}
          await stopService();
        }
      });

  bool _current(int generation) =>
      !_closing && !_disposed && generation == _generation;

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _commands.then((_) => operation());
    _commands = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> handle(Map<String, Object?> command) async {
    final requestId = command['request_id'];
    final clientId = command['client_id'];
    if (requestId is! String ||
        requestId.isEmpty ||
        requestId.length > 128 ||
        clientId is! String ||
        clientId.isEmpty ||
        clientId.length > 128) {
      return;
    }
    if (command['type'] == 'stop') {
      try {
        await stop(beforeShutdown: () => _reply(clientId, requestId));
      } catch (_) {
        _reply(
          clientId,
          requestId,
          error: 'Could not stop or save settings. Try Stop again.',
        );
      }
      return;
    }
    if (command['type'] == 'unsubscribe') {
      final revision = command['view_revision'];
      if (clientId == _clientId &&
          command['session'] == session &&
          revision is int &&
          revision >= _viewRevision) {
        _viewRevision = revision;
        _subscribed = false;
      }
      return;
    }
    await _enqueue(() async {
      if (_closing || _disposed) {
        _reply(
          clientId,
          requestId,
          error: 'Service is stopping. Select Start to resume.',
        );
        return;
      }
      if (command['type'] != 'snapshot' &&
          (clientId != _clientId || command['session'] != session)) {
        _reply(
          clientId,
          requestId,
          error: 'Session expired. Refresh to reconnect.',
        );
        return;
      }
      try {
        switch (command['type']) {
          case 'snapshot':
            final revision = command['view_revision'];
            if (clientId != _clientId) _viewRevision = -1;
            _clientId = clientId;
            if (revision is int
                ? revision >= _viewRevision
                : _viewRevision < 0) {
              _viewRevision = revision is int ? revision : 0;
              _subscribed = command['subscribe'] != false;
            }
            _notificationsEnabled = await notifications.enabled();
          case 'configure':
            final generation = _generation;
            final server = command['server'];
            final token = command['token'];
            if (server is! String || token is! String) {
              throw const FormatException();
            }
            final configuration = ReceiverConfig(
              server,
              token.isEmpty ? _configuration?.receiveToken ?? '' : token,
            );
            await store.saveConfiguration(configuration);
            if (!_current(generation)) return;
            _configuration = configuration;
            final intent = await store.readIntent();
            if (!_current(generation) || !intent.enabled) return;
            await receiver.updateConfiguration(configuration);
          case 'reconnect':
            final intent = await store.readIntent();
            if (!_closing && intent.enabled) await receiver.reconnect();
          case 'test_notification':
            _notificationsEnabled = await notifications.enabled();
            if (!_notificationsEnabled) throw StateError('permission');
            await notifications.test();
          default:
            throw const FormatException();
        }
        _reply(clientId, requestId);
      } on ConfigurationException catch (error) {
        _reply(clientId, requestId, error: error.reason);
      } catch (_) {
        _reply(
          clientId,
          requestId,
          error: 'Operation failed. Check permissions and storage.',
        );
      }
    });
  }

  void _reply(String clientId, String requestId, {String? error}) => send({
    'kind': 'response',
    'session': session,
    'sequence': _sequence,
    'client_id': clientId,
    'request_id': requestId,
    'ok': error == null,
    'error': ?error,
    'snapshot': snapshot,
  });

  void _publish() {
    ++_sequence;
    if (_clientId == null || !_subscribed || _disposed) return;
    send({
      'kind': 'event',
      'session': session,
      'sequence': _sequence,
      'client_id': _clientId,
      'snapshot': snapshot,
    });
  }

  void _onEvent(ReceiverEvent event) {
    if (_closing || _disposed) return;
    if (event is SnapshotEvent) {
      _publish();
      final status = event.snapshot.status.name;
      if (status != _lastStatus) {
        _lastStatus = status;
        unawaited(
          updateStatus(status).catchError((Object _) {
            _platformError = 'Could not update the service notification.';
            _publish();
          }),
        );
      }
    } else if (event is MessageEvent) {
      if (!_rememberMessage(event.message)) return;
      _saveHistory();
      _publish();
      _notificationQueue.add(event.message);
      _notificationBytes += event.message.byteSize;
      while (_notificationQueue.length > TugReceiver.maxMessages ||
          _notificationBytes > TugReceiver.maxMessageBytes) {
        _notificationBytes -= _notificationQueue.removeFirst().byteSize;
      }
      _delivery ??= _deliver().whenComplete(() {
        _delivery = null;
      });
    }
  }

  Future<void> _deliver() async {
    while (_notificationQueue.isNotEmpty && !_closing) {
      final message = _notificationQueue.removeFirst();
      _notificationBytes -= message.byteSize;
      final slot = _notificationSlot++ % TugReceiver.maxMessages;
      try {
        _notificationsEnabled = await notifications.enabled();
        if (!_closing && _notificationsEnabled) {
          await notifications.show(message, slot);
        }
        if (!_notificationsEnabled) _publish();
      } catch (_) {
        _platformError = AppText.notificationFailed;
        _publish();
      }
    }
  }

  void _saveHistory() {
    if (!_historyLoaded) return;
    _pendingHistory = _history.messages;
    _historyWrite ??= _writeHistory();
  }

  Future<void> _writeHistory() async {
    try {
      while (_pendingHistory != null) {
        final messages = _pendingHistory!;
        _pendingHistory = null;
        try {
          await store.saveHistory(messages);
          _historyError = null;
        } catch (_) {
          _historyError = AppText.historySaveFailed;
        }
      }
    } finally {
      _historyWrite = null;
      _publish();
    }
  }

  void _captureRecentMessages() {
    bool changed = false;
    for (final message in receiver.snapshot.messages.reversed) {
      changed = _rememberMessage(message) || changed;
    }
    if (changed) _saveHistory();
  }

  bool _rememberMessage(ReceivedMessage message) {
    if (!_historySeen.add(message.id)) return false;
    if (_historySeen.length > TugReceiver.maxSeenIds) {
      _historySeen.remove(_historySeen.first);
    }
    return _history.add(message);
  }

  Future<void> stop({void Function()? beforeShutdown}) async {
    if (_disposed) return;
    _captureRecentMessages();
    _closing = true;
    ++_generation;
    _notificationQueue.clear();
    _notificationBytes = 0;
    final shutdown = receiver.stop();
    Object? failure;
    try {
      await store.setReceiving(false);
    } catch (error) {
      failure = error;
      _platformError =
          'Receiving stopped, but the setting was not saved. Try Stop again.';
    }
    await shutdown;
    await _historyWrite;
    await _network?.cancel();
    _network = null;
    _publish();
    if (failure != null) throw StateError('Failed to persist stop intent.');
    beforeShutdown?.call();
    await stopService();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _captureRecentMessages();
    _closing = true;
    _disposed = true;
    ++_generation;
    _notificationQueue.clear();
    _notificationBytes = 0;
    final shutdown = receiver.dispose();
    await _network?.cancel();
    await _events?.cancel();
    await _historyWrite;
    await shutdown;
  }
}
