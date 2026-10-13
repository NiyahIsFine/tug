import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:tug_core/tug_core.dart';

import 'support.dart';

void main() {
  final configuration = ReceiverConfig(
    'http://localhost:16640',
    'private-receive-token',
  );

  test('hello gates connected state, native heartbeat configured, duplicate notified once', () {
    fakeAsync((clock) {
      final transport = FakeTransport();
      final receiver = TugReceiver(
        connector: transport.connect,
        random: () => 0.5,
      );
      final events = <ReceiverEvent>[];
      receiver.events.listen(events.add);
      unawaited(receiver.updateConfiguration(configuration));
      clock.flushMicrotasks();
      expect(receiver.snapshot.status, ReceiverStatus.connecting);
      final connection = transport.accept();
      clock.flushMicrotasks();
      connection.controller.add(hello());
      connection.controller.add(message(1));
      connection.controller.add(message(1));
      clock.flushMicrotasks();
      expect(receiver.snapshot.status, ReceiverStatus.connected);
      expect(connection.heartbeat, const Duration(seconds: 120));
      expect(receiver.snapshot.messages, hasLength(1));
      expect(events.whereType<MessageEvent>(), hasLength(1));
      expect(
        jsonEncode(receiver.snapshot.toData()),
        isNot(contains(configuration.receiveToken)),
      );
      for (final event in events) {
        expect(
          jsonEncode(event.toData()),
          isNot(contains(configuration.receiveToken)),
        );
      }
      unawaited(receiver.dispose());
      clock.flushMicrotasks();
      expect(connection.closed, isTrue);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('bounded 20 messages and 256 IDs with insertion-order eviction', () {
    fakeAsync((clock) {
      final transport = FakeTransport();
      final receiver = TugReceiver(connector: transport.connect);
      var notifications = 0;
      receiver.events.listen((event) {
        if (event is MessageEvent) notifications++;
      });
      unawaited(receiver.updateConfiguration(configuration));
      clock.flushMicrotasks();
      final connection = transport.accept();
      clock.flushMicrotasks();
      connection.controller.add(hello());
      for (var index = 0; index < 257; index++) {
        connection.controller.add(message(index));
      }
      clock.flushMicrotasks();
      expect(receiver.snapshot.messages, hasLength(20));
      expect(notifications, 257);
      connection.controller.add(message(256));
      connection.controller.add(message(0));
      clock.flushMicrotasks();
      expect(notifications, 258);
      expect(receiver.snapshot.messages, hasLength(20));
      unawaited(receiver.dispose());
      clock.flushMicrotasks();
    });
  });

  test('128 KiB bound independently evicts large Unicode messages', () {
    fakeAsync((clock) {
      final transport = FakeTransport();
      final receiver = TugReceiver(connector: transport.connect);
      unawaited(receiver.updateConfiguration(configuration));
      clock.flushMicrotasks();
      final connection = transport.accept();
      clock.flushMicrotasks();
      connection.controller.add(hello());
      for (var index = 0; index < 20; index++) {
        connection.controller.add(message(index, body: '😀' * 4096));
      }
      clock.flushMicrotasks();
      expect(receiver.snapshot.messages.length, lessThan(20));
      expect(
        receiver.snapshot.messages.fold<int>(
          0,
          (total, item) => total + item.byteSize,
        ),
        lessThanOrEqualTo(128 * 1024),
      );
      unawaited(receiver.dispose());
      clock.flushMicrotasks();
    });
  });

  test(
    'full deterministic backoff is capped, stop cancels timers and recovery',
    () {
      fakeAsync((clock) {
        final transport = FakeTransport();
        final receiver = TugReceiver(
          connector: transport.connect,
          random: () => 0.5,
          now: () => DateTime.utc(2026).add(clock.elapsed),
        );
        unawaited(receiver.updateConfiguration(configuration));
        clock.flushMicrotasks();
        for (final seconds in [...TugReceiver.retrySeconds, 300]) {
          transport.reject(FailureKind.transient);
          clock.flushMicrotasks();
          expect(
            receiver.snapshot.retryAt!.difference(
              DateTime.utc(2026).add(clock.elapsed),
            ),
            Duration(seconds: seconds),
          );
          final count = transport.attempts.length;
          clock.elapse(Duration(seconds: seconds));
          clock.flushMicrotasks();
          expect(transport.attempts.length, count + 1);
        }
        unawaited(receiver.stop());
        clock.flushMicrotasks();
        unawaited(receiver.recoveryHint());
        unawaited(receiver.networkChanged(true));
        clock.elapse(const Duration(hours: 1));
        clock.flushMicrotasks();
        expect(receiver.snapshot.status, ReceiverStatus.stopped);
        expect(clock.pendingTimers, isEmpty);
        unawaited(receiver.dispose());
        clock.flushMicrotasks();
      });
    },
  );

  test('authentication/version failures never retry automatically', () {
    for (final failure in [
      FailureKind.authentication,
      FailureKind.configuration,
    ]) {
      fakeAsync((clock) {
        final transport = FakeTransport();
        final receiver = TugReceiver(connector: transport.connect);
        unawaited(receiver.updateConfiguration(configuration));
        clock.flushMicrotasks();
        transport.reject(failure);
        clock.flushMicrotasks();
        unawaited(receiver.recoveryHint());
        clock.elapse(const Duration(hours: 1));
        expect(transport.attempts, hasLength(1));
        expect(clock.pendingTimers, isEmpty);
        unawaited(receiver.dispose());
        clock.flushMicrotasks();
      });
    }
  });

  test(
    'old completion after configuration change is closed and never subscribed',
    () {
      fakeAsync((clock) {
        final transport = FakeTransport();
        final receiver = TugReceiver(connector: transport.connect);
        unawaited(receiver.updateConfiguration(configuration));
        clock.flushMicrotasks();
        final stale = transport.attempts.single;
        unawaited(
          receiver.updateConfiguration(
            ReceiverConfig('http://localhost:8081', 'ab'),
          ),
        );
        clock.flushMicrotasks();
        expect(stale.cancelled, isTrue);
        final oldConnection = FakeConnection();
        stale.completer.complete(oldConnection);
        clock.flushMicrotasks();
        expect(oldConnection.closed, isTrue);
        expect(transport.attempts, hasLength(2));
        unawaited(receiver.dispose());
        clock.flushMicrotasks();
        final finalConnection = FakeConnection();
        transport.attempts.last.completer.complete(finalConnection);
        clock.flushMicrotasks();
        expect(finalConnection.closed, isTrue);
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );

  test('connection without hello closes at the deadline and retries', () {
    fakeAsync((clock) {
      final transport = FakeTransport();
      final receiver = TugReceiver(
        connector: transport.connect,
        random: () => 0.5,
        now: () => DateTime.utc(2026).add(clock.elapsed),
      );
      unawaited(receiver.updateConfiguration(configuration));
      clock.flushMicrotasks();
      final connection = transport.accept();
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 9));
      expect(connection.closed, isFalse);
      expect(receiver.snapshot.status, ReceiverStatus.connecting);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(connection.closed, isTrue);
      expect(receiver.snapshot.status, ReceiverStatus.reconnecting);
      expect(transport.attempts, hasLength(1));
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(transport.attempts, hasLength(2));
      unawaited(receiver.dispose());
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test(
    'recovery burst replaces a pending retry with one connection attempt',
    () {
      fakeAsync((clock) {
        final transport = FakeTransport();
        final receiver = TugReceiver(
          connector: transport.connect,
          random: () => 0.5,
          now: () => DateTime.utc(2026).add(clock.elapsed),
        );
        unawaited(receiver.updateConfiguration(configuration));
        clock.flushMicrotasks();
        transport.reject(FailureKind.transient);
        clock.flushMicrotasks();
        expect(receiver.snapshot.status, ReceiverStatus.reconnecting);
        for (var count = 0; count < 20; count++) {
          unawaited(receiver.recoveryHint());
        }
        clock.flushMicrotasks();
        expect(transport.attempts, hasLength(2));
        clock.elapse(const Duration(seconds: 1));
        expect(transport.attempts, hasLength(2));
        expect(transport.attempts.last.cancelled, isFalse);
        unawaited(receiver.dispose());
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );

  test('stable sixty seconds resets backoff, network loss pauses attempts', () {
    fakeAsync((clock) {
      final transport = FakeTransport();
      final receiver = TugReceiver(
        connector: transport.connect,
        random: () => 0.5,
        now: () => DateTime.utc(2026).add(clock.elapsed),
      );
      unawaited(receiver.updateConfiguration(configuration));
      clock.flushMicrotasks();
      transport.reject(FailureKind.transient);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      final connection = transport.accept();
      clock.flushMicrotasks();
      connection.controller.add(hello());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 60));
      unawaited(connection.controller.close());
      clock.flushMicrotasks();
      expect(
        receiver.snapshot.retryAt!.difference(
          DateTime.utc(2026).add(clock.elapsed),
        ),
        const Duration(seconds: 1),
      );
      unawaited(receiver.networkChanged(false));
      clock.flushMicrotasks();
      final count = transport.attempts.length;
      clock.elapse(const Duration(hours: 1));
      expect(transport.attempts.length, count);
      unawaited(receiver.networkChanged(true));
      clock.flushMicrotasks();
      expect(transport.attempts.length, count + 1);
      unawaited(receiver.dispose());
      clock.flushMicrotasks();
    });
  });

  test('persisted stopped intent does not connect on first configuration', () {
    fakeAsync((clock) {
      final transport = FakeTransport();
      final receiver = TugReceiver(
        connector: transport.connect,
        receiving: false,
      );
      unawaited(receiver.updateConfiguration(configuration));
      clock.flushMicrotasks();
      expect(transport.attempts, isEmpty);
      expect(receiver.snapshot.status, ReceiverStatus.stopped);
      unawaited(receiver.start());
      clock.flushMicrotasks();
      expect(transport.attempts, hasLength(1));
      unawaited(receiver.dispose());
      clock.flushMicrotasks();
    });
  });
}
