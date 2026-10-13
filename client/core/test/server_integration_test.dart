import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tug_core/tug_core.dart';

void main() {
  final executable = Platform.environment['TUG_TEST_SERVER_EXE'];
  test(
    'Go server: short token auth, Unicode broadcast, no offline replay',
    () async {
      final server = await Process.start(
        executable!,
        ['--listen', '127.0.0.1:0', '--log-messages=false'],
        environment: {'TUG_SEND_TOKEN': 'ab', 'TUG_RECEIVE_TOKEN': 'cd'},
      );
      final ready = Completer<String>();
      final errors = server.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final match = RegExp(r'tug-server listening on (127\.0\.0\.1:\d+)')
                .firstMatch(line);
            if (match != null && !ready.isCompleted) {
              ready.complete('http://${match.group(1)}');
            }
          });
      final output = server.stdout.drain<void>();
      final receiver = TugReceiver();
      final received = <ReceivedMessage>[];
      final events = receiver.events.listen((event) {
        if (event is MessageEvent) received.add(event.message);
      });
      final http = HttpClient();
      try {
        final address = await ready.future.timeout(const Duration(seconds: 10));
        Future<void> waitConnected() async {
          if (receiver.snapshot.status == ReceiverStatus.connected) return;
          await receiver.events
              .firstWhere(
                (event) =>
                    event is SnapshotEvent &&
                    event.snapshot.status == ReceiverStatus.connected,
              )
              .timeout(const Duration(seconds: 10));
        }

        Future<Map<String, dynamic>> push(String body) async {
          final request = await http.postUrl(
            Uri.parse('$address/api/v1/messages'),
          );
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ab');
          request.headers.contentType = ContentType.json;
          request.add(
            utf8.encode(
              jsonEncode({'title': 'Unicode alert 😀', 'body': body}),
            ),
          );
          final response = await request.close();
          expect(response.statusCode, 202);
          return jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, dynamic>;
        }

        await receiver.updateConfiguration(ReceiverConfig(address, 'cd'));
        await waitConnected();
        final first = receiver.events.firstWhere(
          (event) => event is MessageEvent,
        );
        final queued = await push('First line\nSecond line 😀');
        expect(queued['online_clients'], 1);
        await first.timeout(const Duration(seconds: 10));
        expect(received.single.body, 'First line\nSecond line 😀');
        await receiver.stop();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final offline = await push('Do not replay this message');
        expect(offline['online_clients'], 0);
        await receiver.recoveryHint();
        expect(receiver.snapshot.status, ReceiverStatus.stopped);
        await receiver.start();
        await waitConnected();
        final second = receiver.events.firstWhere(
          (event) => event is MessageEvent,
        );
        await push('Receiving resumed');
        await second.timeout(const Duration(seconds: 10));
        expect(received.map((message) => message.body), [
          'First line\nSecond line 😀',
          'Receiving resumed',
        ]);
        final wrong = TugReceiver();
        try {
          final failed = wrong.events.firstWhere(
            (event) =>
                event is SnapshotEvent &&
                event.snapshot.status == ReceiverStatus.authenticationFailed,
          );
          await wrong.updateConfiguration(ReceiverConfig(address, 'wrong'));
          await failed.timeout(const Duration(seconds: 10));
          expect(wrong.snapshot.retryAt, isNull);
        } finally {
          await wrong.dispose();
        }
      } finally {
        http.close(force: true);
        await events.cancel();
        await receiver.dispose();
        server.kill();
        await server.exitCode.timeout(const Duration(seconds: 5));
        await errors.cancel();
        await output;
      }
    },
    skip: executable == null
        ? 'Set TUG_TEST_SERVER_EXE to a local build of the existing Go server.'
        : false,
  );
}
