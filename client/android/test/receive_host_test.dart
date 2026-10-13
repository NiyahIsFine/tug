import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tug_android/settings.dart';
import 'package:tug_core/tug_core.dart';

import 'support.dart';

void main() {
  test('hidden UI stops event snapshots but receiver cache and notifications continue', () async {
    final fixture = HostFixture();
    addTearDown(fixture.host.dispose);
    final connection = await fixture.connect();
    await fixture.command(
      'snapshot',
      arguments: {'subscribe': true, 'view_revision': 1},
    );
    await fixture.command('unsubscribe', arguments: {'view_revision': 2});
    fixture.sent.clear();
    connection.framesController.add(message(1));
    await pump();
    expect(fixture.sent, isEmpty);
    expect(fixture.notifications.shown, hasLength(1));
    expect(fixture.host.snapshot['messages'] as List, hasLength(1));
    expect(fixture.transport.attempts, hasLength(1));
    await fixture.command(
      'snapshot',
      arguments: {'subscribe': true, 'view_revision': 3},
    );
    expect(fixture.sent.last['kind'], 'response');
    expect((fixture.sent.last['snapshot'] as Map)['messages'], hasLength(1));
    fixture.sent.clear();
    connection.framesController.add(message(2));
    await pump();
    expect(fixture.sent.where((data) => data['kind'] == 'event'), isNotEmpty);
    expect(fixture.serviceStops, 0);
  });

  test('unsubscribe bypasses queued configuration and stale snapshot cannot reenable events', () async {
    final fixture = HostFixture();
    addTearDown(fixture.host.dispose);
    final connection = await fixture.connect();
    await fixture.command('snapshot', arguments: {'view_revision': 1});
    final barrier = fixture.store.saveBarrier = Completer<void>();
    final configure = fixture.command(
      'configure',
      arguments: {'server': 'https://updated.example.com', 'token': ''},
    );
    await pump();
    final staleSnapshot = fixture.command(
      'snapshot',
      arguments: {'subscribe': true, 'view_revision': 1},
    );
    await fixture.command('unsubscribe', arguments: {'view_revision': 2});
    fixture.sent.clear();
    connection.framesController.add(message(1));
    await pump();
    expect(fixture.sent, isEmpty);
    barrier.complete();
    await configure;
    await staleSnapshot;
    final nextConnection = fixture.transport.accept();
    await pump();
    nextConnection.framesController.add(hello());
    nextConnection.framesController.add(message(2));
    await pump();
    expect(fixture.sent.where((data) => data['kind'] == 'event'), isEmpty);
  });

  test(
    'old page, session and view revisions cannot unsubscribe the visible page',
    () async {
      final fixture = HostFixture();
      addTearDown(fixture.host.dispose);
      final connection = await fixture.connect();
      await fixture.command('snapshot', arguments: {'view_revision': 4});
      await fixture.command(
        'unsubscribe',
        client: 'old-page',
        arguments: {'view_revision': 9},
      );
      await fixture.command(
        'unsubscribe',
        session: 'old-service',
        arguments: {'view_revision': 9},
      );
      await fixture.command('unsubscribe', arguments: {'view_revision': 3});
      fixture.sent.clear();
      connection.framesController.add(message(1));
      await pump();
      expect(fixture.sent.where((data) => data['kind'] == 'event'), isNotEmpty);
    },
  );
  late HostFixture fixture;
  setUp(() {
    fixture = HostFixture();
  });
  tearDown(() => fixture.host.dispose());

  test('service owns one receiver across duplicate initialization and page rebuilds', () async {
    final connection = await fixture.connect();
    await fixture.host.initialize();
    await fixture.command('snapshot');
    connection.framesController.add(message(1));
    await pump();
    await fixture.command('snapshot', client: 'new-page');
    expect(fixture.transport.attempts, hasLength(1));
    expect(fixture.host.snapshot['messages'] as List, hasLength(1));
    expect(fixture.notifications.shown, hasLength(1));
    expect(connection.heartbeat, const Duration(seconds: 120));
    expect(jsonEncode(fixture.sent), isNot(contains('test-receive-token')));
  });

  test(
    'old pages and service sessions cannot configure the active receiver',
    () async {
      await fixture.connect();
      await fixture.command('snapshot');
      await fixture.command('snapshot', client: 'new-page');
      await fixture.command(
        'configure',
        arguments: {'server': 'http://other.example', 'token': 'ab'},
      );
      expect(fixture.sent.last['ok'], false);
      await fixture.command(
        'configure',
        client: 'new-page',
        session: 'old-service',
        arguments: {'server': 'http://other.example', 'token': 'ab'},
      );
      expect(fixture.sent.last['ok'], false);
      expect(fixture.transport.attempts, hasLength(1));
    },
  );

  test('configuration replacement closes the previous connection and does not expose token', () async {
    final connection = await fixture.connect();
    await fixture.command('snapshot');
    await fixture.command(
      'configure',
      arguments: {
        'server': 'https://other.example',
        'token': 'new-secret-token',
      },
    );
    expect(connection.closed, true);
    expect(fixture.transport.attempts, hasLength(2));
    expect(fixture.store.configuration!.receiveToken, 'new-secret-token');
    expect(jsonEncode(fixture.sent), isNot(contains('new-secret-token')));
  });

  test(
    'invalid configuration and storage failure keep existing connection',
    () async {
      final connection = await fixture.connect();
      await fixture.command('snapshot');
      await fixture.command(
        'configure',
        arguments: {'server': 'https://example.com/path', 'token': 'ab'},
      );
      expect(fixture.sent.last['ok'], false);
      fixture.store.failSave = true;
      await fixture.command(
        'configure',
        arguments: {
          'server': 'https://other.example',
          'token': 'new-secret-token',
        },
      );
      expect(fixture.sent.last['ok'], false);
      expect(connection.closed, false);
      expect(
        jsonEncode(fixture.sent),
        isNot(contains('secret storage failure')),
      );
    },
  );

  test(
    'stop during secure initialization invalidates late reads and cannot start',
    () async {
      fixture.store.readBarrier = Completer<void>();
      final initialization = fixture.host.initialize();
      await pump();
      await fixture.host.stop();
      fixture.store.readBarrier!.complete();
      await initialization;
      expect(fixture.transport.attempts, isEmpty);
      expect(fixture.store.intent.enabled, false);
      expect(fixture.serviceStops, 1);
    },
  );

  test(
    'stop preempts an in-flight save and late completion cannot reconnect',
    () async {
      final connection = await fixture.connect();
      await fixture.command('snapshot');
      fixture.store.saveBarrier = Completer<void>();
      final saving = fixture.command(
        'configure',
        arguments: {'server': 'https://other.example', 'token': 'ab'},
      );
      await pump();
      await fixture.host.stop();
      fixture.store.saveBarrier!.complete();
      await saving;
      await fixture.command('reconnect');
      expect(connection.closed, true);
      expect(fixture.transport.attempts, hasLength(1));
      expect(fixture.host.snapshot['receiving'], false);
    },
  );

  test(
    'stop releases network subscription and late recovery cannot start',
    () async {
      final network = StreamController<List<String>>();
      addTearDown(network.close);
      await fixture.host.initialize(network: network.stream);
      await fixture.host.stop();
      network.add(['wifi']);
      await pump();
      expect(network.hasListener, false);
      expect(fixture.transport.attempts, hasLength(1));
      expect(fixture.transport.attempts.single.cancelled, true);
    },
  );

  test('stop storage failure closes connection and is reported without hiding failure', () async {
    final connection = await fixture.connect();
    fixture.store.failStop = true;
    await expectLater(fixture.host.stop(), throwsStateError);
    expect(connection.closed, true);
    expect(fixture.serviceStops, 0);
    expect(fixture.host.snapshot['platform_error'], contains('not saved'));
    fixture.store.failStop = false;
    await fixture.host.stop();
    expect(fixture.store.intent.enabled, false);
    expect(fixture.serviceStops, 1);
  });

  test('stopped or unconfigured startup never connects', () async {
    fixture.store.intent = const ReceiveIntent(enabled: false, revision: 2);
    await fixture.host.initialize();
    expect(fixture.transport.attempts, isEmpty);
    expect(fixture.serviceStops, 1);
  });

  test('secure startup failure records generic recovery diagnostic before service shutdown', () async {
    fixture.store.failRead = true;
    await fixture.host.initialize();
    expect(fixture.startupFailures, hasLength(1));
    expect(
      fixture.startupFailures.single,
      contains('Unlock your device and select Start'),
    );
    expect(fixture.startupFailures.single, isNot(contains('secret')));
    expect(fixture.serviceStops, 1);
    expect(fixture.transport.attempts, isEmpty);
  });

  test('recovery diagnostic storage failure still releases the service without reconnecting', () async {
    fixture.store.failRead = true;
    fixture.failStartupReport = true;
    await fixture.host.initialize();
    expect(fixture.serviceStops, 1);
    expect(fixture.transport.attempts, isEmpty);
  });

  test(
    'secure configuration read failures fail closed without leaking exception',
    () async {
      fixture.store.failRead = true;
      await fixture.host.initialize();
      expect(fixture.transport.attempts, isEmpty);
      expect(fixture.serviceStops, 1);
      expect(
        fixture.host.snapshot['platform_error'],
        isNot(contains('secret')),
      );
    },
  );

  test('denied permission keeps receiving and preserves messages', () async {
    fixture.notifications.permission = false;
    final connection = await fixture.connect();
    connection.framesController.add(message(1));
    await pump();
    expect(fixture.host.snapshot['status'], 'connected');
    expect(fixture.host.snapshot['notifications_enabled'], false);
    expect(fixture.host.snapshot['messages'] as List, hasLength(1));
    expect(fixture.notifications.shown, isEmpty);
  });

  test(
    'notification failures preserve cached messages and deduplicate',
    () async {
      fixture.notifications.fail = true;
      final connection = await fixture.connect();
      connection.framesController.add(message(1));
      connection.framesController.add(message(1));
      await pump();
      expect(fixture.notifications.attempts, 1);
      expect(fixture.host.snapshot['messages'] as List, hasLength(1));
      expect(
        fixture.host.snapshot['platform_error'],
        contains('Notification failed'),
      );
    },
  );

  test('notification and message resources are bounded under bursts', () async {
    fixture.notifications.barrier = Completer<void>();
    final connection = await fixture.connect();
    for (var sequence = 0; sequence < 80; sequence++) {
      connection.framesController.add(message(sequence));
    }
    await pump();
    expect(
      fixture.host.snapshot['messages'] as List,
      hasLength(TugReceiver.maxMessages),
    );
    fixture.notifications.barrier!.complete();
    await pump();
    expect(fixture.notifications.shown.length, lessThanOrEqualTo(21));
    expect(fixture.notifications.slots.toSet().length, lessThanOrEqualTo(20));
  });

  test('permission revocation is reflected by a fresh snapshot independently of connection', () async {
    await fixture.connect();
    fixture.notifications.permission = false;
    await fixture.command('snapshot');
    expect(
      (fixture.sent.last['snapshot'] as Map)['notifications_enabled'],
      false,
    );
    expect((fixture.sent.last['snapshot'] as Map)['status'], 'connected');
  });
}
