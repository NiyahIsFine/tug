import 'dart:convert';

import 'model.dart';
import 'protocol.dart';
import 'receiver.dart';

final class RecentHistory {
  RecentHistory([Iterable<ReceivedMessage> messages = const []]) {
    for (final message in messages.toList().reversed) {
      add(message);
    }
  }

  final _messages = <ReceivedMessage>[];

  List<ReceivedMessage> get messages => List.unmodifiable(_messages);

  bool add(ReceivedMessage message) {
    if (_messages.any((existing) => existing.id == message.id)) return false;
    _messages.insert(0, message);
    while (_messages.length > TugReceiver.maxMessages ||
        utf8.encode(encode()).length > TugReceiver.maxMessageBytes) {
      _messages.removeLast();
    }
    return true;
  }

  String encode() => jsonEncode({
    'version': 1,
    'messages': _messages.map((message) => message.toData()).toList(),
  });

  static RecentHistory decode(String encoded) {
    if (utf8.encode(encoded).length > TugReceiver.maxMessageBytes) {
      throw const FormatException('History exceeds its byte limit.');
    }
    final data = jsonDecode(encoded);
    if (data is! Map || data['version'] != 1 || data['messages'] is! List) {
      throw const FormatException('Invalid history format.');
    }
    final entries = data['messages'] as List;
    if (entries.length > TugReceiver.maxMessages) {
      throw const FormatException('History exceeds its count limit.');
    }
    final messages = entries.map((entry) {
      final frame = parseServerFrame(
        jsonEncode({'type': 'message', 'version': 1, 'message': entry}),
      );
      if (frame is! MessageFrame) throw const FormatException();
      return frame.message;
    }).toList();
    return RecentHistory(messages);
  }
}
