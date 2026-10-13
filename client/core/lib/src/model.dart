import 'dart:convert';

enum ReceiverStatus {
  unconfigured,
  stopped,
  connecting,
  connected,
  reconnecting,
  authenticationFailed,
  configurationError,
}

final class ReceivedMessage {
  const ReceivedMessage({
    required this.id,
    required this.title,
    required this.body,
    required this.timestamp,
    required this.receivedAt,
  });

  final String id;
  final String title;
  final String body;
  final DateTime timestamp;
  final DateTime receivedAt;

  Map<String, Object?> toData() => {
    'id': id,
    'title': title,
    'body': body,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'received_at': receivedAt.toUtc().toIso8601String(),
  };

  int get byteSize => utf8.encode(jsonEncode(toData())).length;
}

final class ReceiverSnapshot {
  ReceiverSnapshot({
    required this.status,
    required this.receiving,
    required Iterable<ReceivedMessage> messages,
    this.diagnostic,
    this.retryAt,
  }) : messages = List.unmodifiable(messages);

  final ReceiverStatus status;
  final bool receiving;
  final List<ReceivedMessage> messages;
  final String? diagnostic;
  final DateTime? retryAt;

  Map<String, Object?> toData() => {
    'status': status.name,
    'receiving': receiving,
    'messages': messages.map((message) => message.toData()).toList(),
    'diagnostic': diagnostic,
    'retry_at': retryAt?.toUtc().toIso8601String(),
  };
}

sealed class ReceiverEvent {
  const ReceiverEvent();
  Map<String, Object?> toData();
}

final class SnapshotEvent extends ReceiverEvent {
  const SnapshotEvent(this.snapshot);
  final ReceiverSnapshot snapshot;
  @override
  Map<String, Object?> toData() => {
    'type': 'snapshot',
    'snapshot': snapshot.toData(),
  };
}

final class MessageEvent extends ReceiverEvent {
  const MessageEvent(this.message);
  final ReceivedMessage message;
  @override
  Map<String, Object?> toData() => {
    'type': 'message',
    'message': message.toData(),
  };
}
