import 'dart:convert';

import 'package:test/test.dart';
import 'package:tug_core/tug_core.dart';

void main() {
  ReceivedMessage received(
    int sequence, {
    String body = 'Message body\n😀',
  }) => ReceivedMessage(
    id: '550e8400-e29b-41d4-a716-${sequence.toRadixString(16).padLeft(12, "0")}',
    title: 'Saved message',
    body: body,
    timestamp: DateTime.utc(2026, 10, 12),
    receivedAt: DateTime.utc(2026, 10, 12, 0, 0, 1),
  );

  test('history keeps newest 20 in receive order and deduplicates IDs', () {
    final history = RecentHistory();
    for (var sequence = 0; sequence < 25; sequence++) {
      history.add(received(sequence));
    }
    expect(history.messages, hasLength(20));
    expect(history.messages.first.id, received(24).id);
    expect(history.messages.last.id, received(5).id);
    expect(history.add(received(24)), false);
    final restored = RecentHistory.decode(history.encode());
    expect(
      restored.messages.map((entry) => entry.toData()),
      history.messages.map((entry) => entry.toData()),
    );
  });

  test(
    'encoded history including metadata stays under 128 KiB and evicts oldest',
    () {
      final history = RecentHistory();
      for (var sequence = 0; sequence < 40; sequence++) {
        history.add(received(sequence, body: '😀' * 4096));
      }
      expect(
        utf8.encode(history.encode()).length,
        lessThanOrEqualTo(TugReceiver.maxMessageBytes),
      );
      expect(history.messages.length, lessThan(20));
      expect(history.messages.first.id, received(39).id);
      expect(
        RecentHistory.decode(history.encode()).messages,
        hasLength(history.messages.length),
      );
    },
  );

  test(
    'invalid schema, oversized input, count and malicious fields are rejected',
    () {
      expect(
        () => RecentHistory.decode('{"version":2,"messages":[]}'),
        throwsFormatException,
      );
      expect(
        () => RecentHistory.decode(' ' * (TugReceiver.maxMessageBytes + 1)),
        throwsFormatException,
      );
      expect(
        () => RecentHistory.decode(
          jsonEncode({
            'version': 1,
            'messages': List.filled(21, received(1).toData()),
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => RecentHistory.decode(
          jsonEncode({
            'version': 1,
            'messages': [
              {...received(1).toData(), 'id': 'invalid'},
            ],
          }),
        ),
        throwsA(isA<ReceiverFailure>()),
      );
      expect(
        () => RecentHistory.decode(
          jsonEncode({
            'version': 1,
            'messages': [
              {...received(1).toData(), 'timestamp': '2026-02-30T00:00:00Z'},
            ],
          }),
        ),
        throwsA(isA<ReceiverFailure>()),
      );
    },
  );
}
