import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'config.dart';
import 'model.dart';
import 'protocol.dart';
import 'transport.dart';

abstract interface class ScheduledTask {
  void cancel();
}

typedef Schedule = ScheduledTask Function(
  Duration delay,
  void Function() callback,
);

final class _TimerTask implements ScheduledTask {
  _TimerTask(Duration delay, void Function() callback)
    : timer = Timer(delay, callback);
  final Timer timer;
  @override
  void cancel() => timer.cancel();
}

final class TugReceiver {
  TugReceiver({
    Connector connector = connectWebSocket,
    DateTime Function()? now,
    double Function()? random,
    Schedule? schedule,
    bool receiving = true,
  }) : _connector = connector,
       _now = now ?? DateTime.now,
       _random = random ?? Random().nextDouble,
       _schedule = schedule ?? _TimerTask.new,
       _receiving = receiving;

  static const maxMessages = 20;
  static const maxMessageBytes = 128 * 1024;
  static const maxSeenIds = 256;
  static const retrySeconds = [1, 2, 4, 8, 16, 30, 60, 120, 240, 300];

  final Connector _connector;
  final DateTime Function() _now;
  final double Function() _random;
  final Schedule _schedule;
  final _events = StreamController<ReceiverEvent>.broadcast();
  final _messages = ListQueue<ReceivedMessage>();
  final _seen = <String>{};
  ReceiverConfig? _configuration;
  ReceiverStatus _status = ReceiverStatus.unconfigured;
  String? _diagnostic;
  DateTime? _retryAt;
  DateTime? _connectedAt;
  DateTime? _lastRecoveryHint;
  ConnectionAttempt? _attempt;
  ReceiveConnection? _connection;
  StreamSubscription<Object?>? _subscription;
  ScheduledTask? _retry;
  ScheduledTask? _deadline;
  bool _receiving;
  bool _disposed = false;
  bool _networkAvailable = true;
  int _generation = 0;
  int _retryIndex = 0;
  int _messageBytes = 0;
  Future<void> _cleanup = Future.value();
  Future<void>? _disposeFuture;

  Stream<ReceiverEvent> get events => _events.stream;
  ReceiverSnapshot get snapshot => ReceiverSnapshot(
    status: _status,
    receiving: _receiving,
    messages: _messages.toList().reversed,
    diagnostic: _diagnostic,
    retryAt: _retryAt,
  );

  Future<void> updateConfiguration(ReceiverConfig configuration) async {
    _ensureAlive();
    if (_configuration?.matches(configuration) ?? false) return;
    _configuration = configuration;
    _retryIndex = 0;
    _lastRecoveryHint = null;
    await _invalidate();
    if (_disposed) return;
    if (_receiving) {
      _launch();
    } else {
      _setStatus(ReceiverStatus.stopped);
    }
  }

  Future<void> start() async {
    _ensureAlive();
    if (_receiving &&
        (_attempt != null || _connection != null || _retry != null)) {
      return;
    }
    _receiving = true;
    _retryIndex = 0;
    await _invalidate();
    if (!_disposed && _receiving) _launch();
  }

  Future<void> stop() async {
    _ensureAlive();
    _receiving = false;
    final cleanup = _invalidate();
    _setStatus(
      _configuration == null
          ? ReceiverStatus.unconfigured
          : ReceiverStatus.stopped,
    );
    await cleanup;
  }

  Future<void> reconnect() async {
    _ensureAlive();
    if (!_receiving) return;
    await _invalidate();
    if (!_disposed && _receiving) _launch();
  }

  Future<void> networkChanged(bool available) async {
    if (_disposed) return;
    _networkAvailable = available;
    if (!available) {
      await _invalidate();
      if (!_disposed &&
          _receiving &&
          !_networkAvailable &&
          _configuration != null &&
          !_permanentFailure) {
        _setStatus(
          ReceiverStatus.reconnecting,
          'Network unavailable. Waiting for a connection.',
        );
      }
    } else {
      await recoveryHint();
    }
  }

  Future<void> recoveryHint() async {
    if (_disposed ||
        !_receiving ||
        !_networkAvailable ||
        _configuration == null ||
        _permanentFailure) {
      return;
    }
    final now = _now();
    if (_lastRecoveryHint != null &&
        now.difference(_lastRecoveryHint!) < const Duration(seconds: 2)) {
      return;
    }
    _lastRecoveryHint = now;
    if (_attempt != null) return;
    await _invalidate();
    if (!_disposed && _receiving) _launch();
  }

  bool get _permanentFailure =>
      _status == ReceiverStatus.authenticationFailed ||
      _status == ReceiverStatus.configurationError;

  void _launch() {
    if (_disposed || !_receiving || _attempt != null || _connection != null) {
      return;
    }
    final configuration = _configuration;
    if (configuration == null) {
      _setStatus(ReceiverStatus.unconfigured);
      return;
    }
    if (!_networkAvailable) {
      _setStatus(
        ReceiverStatus.reconnecting,
        'Network unavailable. Waiting for a connection.',
      );
      return;
    }
    final generation = ++_generation;
    _setStatus(
      _retryIndex == 0
          ? ReceiverStatus.connecting
          : ReceiverStatus.reconnecting,
    );
    _deadline = _schedule(const Duration(seconds: 15), () {
      if (generation == _generation) {
        unawaited(
          _failed(
            generation,
            const ReceiverFailure(
              FailureKind.transient,
              'Connection timed out.',
            ),
          ),
        );
      }
    });
    unawaited(_connect(configuration, generation));
  }

  Future<void> _connect(ReceiverConfig configuration, int generation) async {
    try {
      final attempt = _connector(configuration);
      _attempt = attempt;
      final connection = await attempt.connected;
      if (_disposed || !_receiving || generation != _generation) {
        await _close(connection);
        return;
      }
      _attempt = null;
      _connection = connection;
      _deadline?.cancel();
      _deadline = _schedule(const Duration(seconds: 10), () {
        unawaited(
          _failed(
            generation,
            const ReceiverFailure(
              FailureKind.transient,
              'Server did not send a hello frame.',
            ),
          ),
        );
      });
      _subscription = connection.frames.listen(
        (frame) => _onFrame(generation, frame),
        onError: (Object error) => unawaited(
          _failed(
            generation,
            const ReceiverFailure(
              FailureKind.transient,
              'Connection interrupted.',
            ),
          ),
        ),
        onDone: () => unawaited(
          _failed(
            generation,
            const ReceiverFailure(FailureKind.transient, 'Connection closed.'),
          ),
        ),
      );
    } catch (error) {
      await _failed(
        generation,
        error is ReceiverFailure
            ? error
            : const ReceiverFailure(
                FailureKind.transient,
                'Connection failed.',
              ),
      );
    }
  }

  void _onFrame(int generation, Object? input) {
    if (_disposed || generation != _generation) return;
    try {
      final frame = parseServerFrame(input);
      if (_connectedAt == null) {
        if (frame is! HelloFrame) {
          throw const ReceiverFailure(
            FailureKind.transient,
            'Expected a hello frame first.',
          );
        }
        _deadline?.cancel();
        _deadline = null;
        _connectedAt = _now();
        _connection!.pingInterval = frame.heartbeat;
        _setStatus(ReceiverStatus.connected);
      } else if (frame is HelloFrame) {
        throw const ReceiverFailure(
          FailureKind.transient,
          'Received a duplicate hello frame.',
        );
      } else if (frame is MessageFrame && _seen.add(frame.message.id)) {
        if (_seen.length > maxSeenIds) _seen.remove(_seen.first);
        _messages.addLast(frame.message);
        _messageBytes += frame.message.byteSize;
        while (_messages.length > maxMessages ||
            _messageBytes > maxMessageBytes) {
          _messageBytes -= _messages.removeFirst().byteSize;
        }
        _emit(SnapshotEvent(snapshot));
        _emit(MessageEvent(frame.message));
      }
    } on ReceiverFailure catch (error) {
      if (error.kind == FailureKind.configuration || _connectedAt == null) {
        unawaited(_failed(generation, error));
      } else {
        _diagnostic = error.reason;
        _emit(SnapshotEvent(snapshot));
      }
    } catch (_) {
      unawaited(
        _failed(
          generation,
          const ReceiverFailure(
            FailureKind.transient,
            'Failed to process a server frame.',
          ),
        ),
      );
    }
  }

  Future<void> _failed(int generation, ReceiverFailure failure) async {
    if (_disposed || generation != _generation || !_receiving) return;
    if (_connectedAt != null &&
        _now().difference(_connectedAt!) >= const Duration(seconds: 60)) {
      _retryIndex = 0;
    }
    final cleanup = _invalidate();
    final nextGeneration = _generation;
    if (failure.kind != FailureKind.transient) {
      _setStatus(
        failure.kind == FailureKind.authentication
            ? ReceiverStatus.authenticationFailed
            : ReceiverStatus.configurationError,
        failure.reason,
      );
      await cleanup;
      return;
    }
    _setStatus(ReceiverStatus.reconnecting, failure.reason);
    await cleanup;
    if (_disposed ||
        !_receiving ||
        nextGeneration != _generation ||
        !_networkAvailable) {
      return;
    }
    final index = min(_retryIndex, retrySeconds.length - 1);
    final seconds = retrySeconds[index];
    _retryIndex++;
    final delay = Duration(
      milliseconds: (seconds * 1000 * (0.8 + _random().clamp(0.0, 1.0) * 0.4))
          .round(),
    );
    _retryAt = _now().add(delay);
    _retry = _schedule(delay, () {
      _retry = null;
      _retryAt = null;
      if (nextGeneration == _generation) _launch();
    });
    _emit(SnapshotEvent(snapshot));
  }

  Future<void> _invalidate() {
    ++_generation;
    _deadline?.cancel();
    _deadline = null;
    _retry?.cancel();
    _retry = null;
    _retryAt = null;
    _connectedAt = null;
    _attempt?.cancel();
    _attempt = null;
    final subscription = _subscription;
    final connection = _connection;
    _subscription = null;
    _connection = null;
    _cleanup = _cleanup.then((_) async {
      if (subscription != null) await subscription.cancel();
      if (connection != null) await _close(connection);
    });
    return _cleanup;
  }

  Future<void> _close(ReceiveConnection connection) async {
    try {
      await connection.close();
    } catch (_) {
      return;
    }
  }

  void _setStatus(ReceiverStatus status, [String? diagnostic]) {
    _status = status;
    _diagnostic = diagnostic;
    _emit(SnapshotEvent(snapshot));
  }

  void _emit(ReceiverEvent event) {
    if (!_disposed) _events.add(event);
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('Receiver is disposed.');
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    await _invalidate();
    _messages.clear();
    _seen.clear();
    _messageBytes = 0;
    await _events.close();
  }
}
