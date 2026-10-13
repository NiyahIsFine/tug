import 'dart:convert';

import 'model.dart';

enum FailureKind { transient, authentication, configuration }

final class ReceiverFailure implements Exception {
  const ReceiverFailure(this.kind, this.reason);
  final FailureKind kind;
  final String reason;
  @override
  String toString() => reason;
}

sealed class ServerFrame {
  const ServerFrame();
}

final class HelloFrame extends ServerFrame {
  const HelloFrame(this.heartbeat);
  final Duration heartbeat;
}

final class MessageFrame extends ServerFrame {
  const MessageFrame(this.message);
  final ReceivedMessage message;
}

final class UnknownFrame extends ServerFrame {
  const UnknownFrame();
}

ServerFrame parseServerFrame(Object? input) {
  const invalid = ReceiverFailure(
    FailureKind.transient,
    'Invalid server frame.',
  );
  try {
    if (input is! String || utf8.encode(input).length > 32768) throw invalid;
    final decoded = jsonDecode(input);
    if (decoded is! Map<String, dynamic> || decoded['type'] is! String) {
      throw invalid;
    }
    if (decoded['version'] != 1) {
      throw const ReceiverFailure(
        FailureKind.configuration,
        'Unsupported protocol. Update Tug or check the server version.',
      );
    }
    switch (decoded['type']) {
      case 'hello':
        final seconds = decoded['heartbeat_interval_seconds'];
        if (seconds is! int || seconds < 1 || seconds > 600) throw invalid;
        _time(decoded['server_time']);
        return HelloFrame(Duration(seconds: seconds));
      case 'message':
        final message = decoded['message'];
        if (message is! Map<String, dynamic>) throw invalid;
        final id = message['id'];
        final title = message['title'];
        final body = message['body'];
        if (id is! String ||
            !RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
            ).hasMatch(id) ||
            title is! String ||
            title.trim().isEmpty ||
            title.runes.length > 120 ||
            body is! String ||
            body.trim().isEmpty ||
            body.runes.length > 4096) {
          throw invalid;
        }
        return MessageFrame(
          ReceivedMessage(
            id: id.toLowerCase(),
            title: title,
            body: body,
            timestamp: _time(message['timestamp']),
            receivedAt: _time(message['received_at']),
          ),
        );
      default:
        return const UnknownFrame();
    }
  } on FormatException {
    throw invalid;
  }
}

DateTime _time(Object? input) {
  if (input is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
      ).hasMatch(input)) {
    throw const FormatException();
  }
  if (!input.endsWith('Z')) {
    final offset = input.substring(input.length - 5);
    if (int.parse(offset.substring(0, 2)) > 23 ||
        int.parse(offset.substring(3, 5)) > 59) {
      throw const FormatException();
    }
  }
  final parsed = DateTime.parse(input);
  final date = input.substring(0, 10);
  final calendar = DateTime.parse('${date}T00:00:00Z');
  if (calendar.toIso8601String().substring(0, 10) != date ||
      int.parse(input.substring(11, 13)) > 23 ||
      int.parse(input.substring(14, 16)) > 59 ||
      int.parse(input.substring(17, 19)) > 59) {
    throw const FormatException();
  }
  return parsed.toUtc();
}
