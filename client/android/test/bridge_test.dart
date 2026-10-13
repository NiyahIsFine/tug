import 'package:flutter_test/flutter_test.dart';
import 'package:tug_android/bridge.dart';

void main() {
  late ServiceBridge bridge;
  late List<Map<String, Object?>> sent;
  setUp(() {
    sent = [];
    bridge = ServiceBridge(
      send: sent.add,
      timeout: const Duration(milliseconds: 20),
    );
  });
  tearDown(() => bridge.dispose());

  Map<String, Object?> reply({
    String session = 'service-1',
    int sequence = 1,
    String status = 'connected',
  }) => {
    'kind': 'response',
    'client_id': bridge.clientId,
    'request_id': sent.last['request_id'],
    'session': session,
    'sequence': sequence,
    'ok': true,
    'snapshot': {'status': status},
  };

  test(
    'correlates responses and sends only controls with a known session',
    () async {
      await expectLater(bridge.request('reconnect'), throwsStateError);
      expect(sent, isEmpty);
      final snapshot = bridge.request('snapshot');
      bridge.receive(reply());
      await snapshot;
      final reconnect = bridge.request('reconnect');
      expect(sent.last['session'], 'service-1');
      bridge.receive(reply(sequence: 2));
      await reconnect;
      expect(bridge.latest!['status'], 'connected');
    },
  );

  test(
    'ignores another page, old session and out-of-order snapshots',
    () async {
      final pending = bridge.request('snapshot');
      bridge.receive(reply());
      await pending;
      bridge.receive({
        'kind': 'event',
        'client_id': 'old-page',
        'session': 'service-1',
        'sequence': 10,
        'snapshot': {'status': 'wrong'},
      });
      bridge.receive({
        'kind': 'event',
        'client_id': bridge.clientId,
        'session': 'service-0',
        'sequence': 10,
        'snapshot': {'status': 'wrong'},
      });
      bridge.receive({
        'kind': 'event',
        'client_id': bridge.clientId,
        'session': 'service-1',
        'sequence': 0,
        'snapshot': {'status': 'wrong'},
      });
      expect(bridge.latest!['status'], 'connected');
      bridge.receive({
        'kind': 'event',
        'client_id': bridge.clientId,
        'session': 'service-1',
        'sequence': 2,
        'snapshot': {'status': 'reconnecting'},
      });
      expect(bridge.latest!['status'], 'reconnecting');
    },
  );

  test('explicit snapshot can handshake a restarted service', () async {
    final first = bridge.request('snapshot');
    bridge.receive(reply());
    await first;
    final next = bridge.request('snapshot');
    bridge.receive(reply(session: 'service-2', sequence: 0, status: 'stopped'));
    await next;
    expect(bridge.latest!['status'], 'stopped');
  });

  test(
    'service unavailable times out and late responses do not update state',
    () async {
      final response = bridge.request('snapshot');
      final oldReply = reply();
      await expectLater(response, throwsA(isA<Exception>()));
      bridge.receive(oldReply);
      expect(bridge.latest, isNull);
    },
  );

  test(
    'page disposal releases pending requests without sending service stop',
    () async {
      final response = bridge.request('snapshot');
      final failure = expectLater(response, throwsStateError);
      await bridge.dispose();
      await failure;
      expect(sent.map((command) => command['type']), ['snapshot']);
      bridge.receive(reply());
      expect(bridge.latest, isNull);
    },
  );
}
