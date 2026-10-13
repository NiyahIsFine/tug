import 'dart:convert';

import 'package:test/test.dart';
import 'package:tug_core/tug_core.dart';

void main() {
  test(
    'pure-data commands correlate responses and never broadcast secrets',
    () async {
      final receiver = TugReceiver(receiving: false);
      const token = 'private-control-token';
      final response = await receiver.executeDataCommand({
        'request_id': 'configure-1',
        'type': 'configure',
        'server': 'http://localhost',
        'receive_token': token,
      });
      expect(response['ok'], isTrue);
      expect(response['request_id'], 'configure-1');
      expect(jsonEncode(response), isNot(contains(token)));
      expect(receiver.snapshot.status, ReceiverStatus.stopped);
      final invalid = await receiver.executeDataCommand({
        'request_id': 'bad',
        'type': 'unknown',
        'secret': token,
      });
      expect(invalid['ok'], isFalse);
      expect(jsonEncode(invalid), isNot(contains(token)));
      await receiver.executeDataCommand({
        'request_id': 'exit',
        'type': 'dispose',
      });
    },
  );
}
