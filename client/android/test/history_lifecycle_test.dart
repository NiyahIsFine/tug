import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tug_android/app_controller.dart';
import 'package:tug_android/settings.dart';
import 'package:tug_core/tug_core.dart';

import 'app_support.dart';
import 'support.dart';

void main() {
  ReceivedMessage received(
    int sequence, {
    String body = 'Saved message body',
  }) =>
      (parseServerFrame(message(sequence, body: body)) as MessageFrame).message;

  test(
    'stop releases foreground service even when history save fails',
    () async {
      final fixture = HostFixture();
      addTearDown(fixture.host.dispose);
      final connection = await fixture.connect();
      fixture.store.failHistorySave = true;
      connection.framesController.add(message(1));
      await pump();
      await fixture.host.stop();
      expect(connection.closed, true);
      expect(fixture.store.intent.enabled, false);
      expect(fixture.serviceStops, 1);
      expect(fixture.host.snapshot['messages'], hasLength(1));
      expect(fixture.host.snapshot['history_error'], isNotNull);
    },
  );

  test('stopped page loads encrypted history and UI stop, refresh and reopen retain it', () async {
    final store = MemoryStore()
      ..history = [received(1)]
      ..intent = const ReceiveIntent(enabled: false, revision: 1);
    final service = ServiceFake();
    final controller = AppController(
      store: store,
      service: service,
      notifications: PageNotificationFake(),
    );
    await controller.setVisible(true);
    expect(controller.messages.single['id'], received(1).id);
    service.running = true;
    service.snapshot = {
      ...service.snapshot,
      'messages': store.history.map((entry) => entry.toData()).toList(),
    };
    await controller.refresh();
    await controller.stop();
    expect(controller.messages.single['id'], received(1).id);
    expect(controller.status, 'stopped');
    await controller.refresh();
    expect(controller.messages.single['id'], received(1).id);
    controller.dispose();
    final reopened = AppController(
      store: store,
      service: service,
      notifications: PageNotificationFake(),
    );
    addTearDown(reopened.dispose);
    await reopened.setVisible(true);
    expect(reopened.messages.single['body'], 'Saved message body');
    expect(service.starts, 0);
    expect(store.historyWrites, 0);
  });

  test('service stop and recreated service preserve history and append without duplicate notifications', () async {
    final store = MemoryStore();
    final first = HostFixture(store: store);
    final connection = await first.connect();
    connection.framesController.add(message(1));
    await pump();
    await first.host.stop();
    expect(connection.closed, true);
    expect(store.history.single.id, received(1).id);
    expect(first.host.snapshot['messages'], hasLength(1));
    await first.host.dispose();
    await store.setReceiving(true, expectedRevision: store.intent.revision);
    final second = HostFixture(store: store);
    addTearDown(second.host.dispose);
    final next = await second.connect();
    expect(second.host.snapshot['messages'], hasLength(1));
    expect(second.notifications.shown, isEmpty);
    next.framesController.add(message(1));
    next.framesController.add(message(2));
    await pump();
    expect(second.notifications.shown, [received(2).id]);
    expect(store.history.map((entry) => entry.id), [
      received(2).id,
      received(1).id,
    ]);
  });

  test('slow persistence coalesces bursts, releases connection on stop and flushes newest bound', () async {
    final fixture = HostFixture();
    addTearDown(fixture.host.dispose);
    final connection = await fixture.connect();
    final barrier = fixture.store.historySaveBarrier = Completer<void>();
    for (var sequence = 0; sequence < 100; sequence++) {
      connection.framesController.add(message(sequence));
    }
    await pump();
    expect(fixture.store.historyWrites, 1);
    expect(fixture.host.snapshot['messages'], hasLength(20));
    final stopping = fixture.host.stop();
    await pump();
    expect(connection.closed, true);
    expect(fixture.store.intent.enabled, false);
    barrier.complete();
    await stopping;
    expect(fixture.store.historyWrites, 2);
    expect(fixture.store.history.first.id, received(99).id);
    expect(fixture.store.history.last.id, received(80).id);
    expect(fixture.serviceStops, 1);
  });

  test('history read failure does not overwrite old data or prevent receive and stop', () async {
    final store = MemoryStore()
      ..history = [received(1)]
      ..failHistoryRead = true;
    final fixture = HostFixture(store: store);
    addTearDown(fixture.host.dispose);
    final connection = await fixture.connect();
    connection.framesController.add(message(2));
    await pump();
    expect(fixture.host.snapshot['history_error'], isNotNull);
    expect(fixture.notifications.shown, [received(2).id]);
    await fixture.host.stop();
    expect(store.historyWrites, 0);
    expect(store.history.single.id, received(1).id);
    expect(connection.closed, true);
    expect(fixture.serviceStops, 1);
  });

  test('write failure keeps in-memory history and stops; next message retries without polling', () async {
    final fixture = HostFixture();
    addTearDown(fixture.host.dispose);
    final connection = await fixture.connect();
    fixture.store.failHistorySave = true;
    connection.framesController.add(message(1));
    await pump();
    expect(fixture.host.snapshot['history_error'], isNotNull);
    expect(fixture.host.snapshot['messages'], hasLength(1));
    final writes = fixture.store.historyWrites;
    await pump();
    expect(fixture.store.historyWrites, writes);
    fixture.store.failHistorySave = false;
    connection.framesController.add(message(2));
    await pump();
    expect(fixture.host.snapshot['history_error'], isNull);
    expect(fixture.store.history, hasLength(2));
    await fixture.host.stop();
    expect(fixture.serviceStops, 1);
  });

  test('history byte eviction is not undone when core still contains an evicted item at stop', () async {
    final fixture = HostFixture();
    addTearDown(fixture.host.dispose);
    final connection = await fixture.connect();
    for (var sequence = 0; sequence < 30; sequence++) {
      connection.framesController.add(message(sequence, body: '😀' * 4096));
    }
    await pump();
    final before = (fixture.host.snapshot['messages'] as List)
        .map((entry) => (entry as Map)['id'])
        .toList();
    await fixture.host.stop();
    expect(fixture.store.history.map((entry) => entry.id), before);
    expect(fixture.store.history.first.id, received(29).id);
  });

  test('stopping during history initialization leaves stored history intact and never connects', () async {
    final store = MemoryStore()..history = [received(1)];
    final barrier = store.historyReadBarrier = Completer<void>();
    final fixture = HostFixture(store: store);
    addTearDown(fixture.host.dispose);
    final starting = fixture.host.initialize();
    await pump();
    await fixture.host.stop();
    barrier.complete();
    await starting;
    expect(fixture.transport.attempts, isEmpty);
    expect(store.historyWrites, 0);
    expect(store.history.single.id, received(1).id);
  });

  test(
    'stopped page read failure preserves visible history and never writes it',
    () async {
      final store = MemoryStore()
        ..history = [received(1)]
        ..intent = const ReceiveIntent(enabled: false, revision: 2);
      final controller = AppController(
        store: store,
        service: ServiceFake(),
        notifications: PageNotificationFake(),
      );
      addTearDown(controller.dispose);
      await controller.setVisible(true);
      store.failHistoryRead = true;
      await controller.refresh();
      expect(controller.messages.single['id'], received(1).id);
      expect(controller.historyError, isNotNull);
      expect(store.historyWrites, 0);
    },
  );
}
