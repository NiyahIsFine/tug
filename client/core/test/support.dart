import 'dart:async';
import 'dart:convert';

import 'package:tug_core/tug_core.dart';

String hello({int version = 1, int heartbeat = 120}) => jsonEncode({
  'type': 'hello',
  'version': version,
  'heartbeat_interval_seconds': heartbeat,
  'server_time': '2026-10-10T12:00:00Z',
});

String message(
  int sequence, {
  String body = 'Message\nSecond line 😀',
  int version = 1,
}) => jsonEncode({
  'type': 'message',
  'version': version,
  'message': {
    'id':
        '550e8400-e29b-41d4-a716-${sequence.toRadixString(16).padLeft(12, '0')}',
    'title': 'Alert 😀',
    'body': body,
    'timestamp': '2026-10-10T12:00:00+08:00',
    'received_at': '2026-10-10T04:00:01Z',
  },
});

final class FakeConnection implements ReceiveConnection {
  final controller = StreamController<Object?>(onCancel: () async {});
  Duration? heartbeat;
  bool closed = false;
  @override
  Stream<Object?> get frames => controller.stream;
  @override
  set pingInterval(Duration interval) => heartbeat = interval;
  @override
  Future<void> close() async {
    closed = true;
    unawaited(controller.close());
  }
}

final class FakeAttempt implements ConnectionAttempt {
  final completer = Completer<ReceiveConnection>();
  bool cancelled = false;
  @override
  Future<ReceiveConnection> get connected => completer.future;
  @override
  void cancel() => cancelled = true;
}

final class FakeTransport {
  final attempts = <FakeAttempt>[];
  ConnectionAttempt connect(ReceiverConfig configuration) {
    final attempt = FakeAttempt();
    attempts.add(attempt);
    return attempt;
  }

  FakeConnection accept() {
    final connection = FakeConnection();
    attempts.last.completer.complete(connection);
    return connection;
  }

  void reject(FailureKind kind) => attempts.last.completer.completeError(
    ReceiverFailure(kind, 'Test connection failure'),
  );
}
