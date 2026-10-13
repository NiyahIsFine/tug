import 'dart:convert';

import 'package:test/test.dart';
import 'package:tug_core/tug_core.dart';

import 'support.dart';

void main() {
  test('server root maps to authenticated WS/WSS target', () {
    expect(
      ReceiverConfig('https://example.com:8443', 'ab').webSocketUri.toString(),
      'wss://example.com:8443/api/v1/ws',
    );
    expect(
      ReceiverConfig('http://[::1]:16640/', 'ab').webSocketUri.toString(),
      'ws://[::1]:16640/api/v1/ws',
    );
    expect(ReceiverConfig('http://localhost', 'ab').isEncrypted, isFalse);
  });
  test('reject non-root, credentials, fragments and malformed hosts/ports', () {
    for (final address in [
      'ws://localhost',
      'http://localhost/base',
      'http://localhost/?',
      'http://localhost/#',
      'http://secret@localhost',
      'http://localhost:0',
      'http://localhost:65536',
      'http://',
      'http://bad host',
      'http://-bad.test',
      'http://bad%20host',
    ]) {
      expect(
        () => ReceiverConfig(address, 'ab'),
        throwsA(isA<ConfigurationException>()),
        reason: address,
      );
    }
  });
  test('current server token rule: 2+ printable non-space ASCII, no app length ceiling', () {
    expect(ReceiverConfig('https://localhost', 'ab').receiveToken, 'ab');
    expect(
      ReceiverConfig('https://localhost', 'a' * 4096).receiveToken.length,
      4096,
    );
    for (final token in ['', 'a', 'a b', 'ab\n', '😀', 'a\u007f']) {
      expect(
        () => ReceiverConfig('https://localhost', token),
        throwsA(isA<ConfigurationException>()),
      );
    }
    const token = 'secret-token';
    expect(
      ReceiverConfig('https://localhost', token).toString(),
      isNot(contains(token)),
    );
  });
  test(
    'hello accepts exact server range and rejects incompatible versions',
    () {
      expect(
        (parseServerFrame(hello()) as HelloFrame).heartbeat,
        const Duration(seconds: 120),
      );
      for (final seconds in [1, 600]) {
        expect(parseServerFrame(hello(heartbeat: seconds)), isA<HelloFrame>());
      }
      for (final seconds in [0, 601]) {
        expect(
          () => parseServerFrame(hello(heartbeat: seconds)),
          throwsA(isA<ReceiverFailure>()),
        );
      }
      expect(
        () => parseServerFrame(hello(version: 2)),
        throwsA(
          isA<ReceiverFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.configuration,
          ),
        ),
      );
    },
  );
  test(
    'Unicode and timezone-normalized message survives pure-data round trip',
    () {
      final parsed = (parseServerFrame(message(1)) as MessageFrame).message;
      expect(parsed.title, 'Alert 😀');
      expect(parsed.body, 'Message\nSecond line 😀');
      expect(parsed.timestamp, DateTime.utc(2026, 10, 10, 4));
      expect(jsonDecode(jsonEncode(parsed.toData()))['body'], parsed.body);
      expect(
        parseServerFrame(jsonEncode({'type': 'future', 'version': 1})),
        isA<UnknownFrame>(),
      );
    },
  );
  test(
    'malformed/binary/oversize frames and invalid calendar are rejected safely',
    () {
      for (final input in [
        null,
        <int>[1],
        '{}',
        'not-json',
        'x' * 32769,
        message(1, body: '😀' * 4097),
        message(1).replaceFirst('2026-10-10T', '2026-02-30T'),
      ]) {
        expect(() => parseServerFrame(input), throwsA(isA<ReceiverFailure>()));
      }
    },
  );
}
