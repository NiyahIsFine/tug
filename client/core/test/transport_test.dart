import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tug_core/tug_core.dart';

import 'support.dart';

void main() {
  test('real HTTP handshake classifies auth/configuration versus transient failures', () async {
    for (final status in [401, 403, 400, 404, 405, 503]) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.statusCode = status;
        await request.response.close();
      });
      final attempt = connectWebSocket(
        ReceiverConfig('http://127.0.0.1:${server.port}', 'ab'),
      );
      final expected = status == 401 || status == 403
          ? FailureKind.authentication
          : status == 503
          ? FailureKind.transient
          : FailureKind.configuration;
      await expectLater(
        attempt.connected,
        throwsA(
          isA<ReceiverFailure>().having(
            (failure) => failure.kind,
            'kind',
            expected,
          ),
        ),
      );
      attempt.cancel();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test(
    'real receive connection sends header only, native Ping/Pong keeps alive',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upgraded = Completer<WebSocket>();
      final subscription = server.listen((request) async {
        expect(request.uri.path, '/api/v1/ws');
        expect(request.uri.query, isEmpty);
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer ab',
        );
        expect(request.headers.value('Sec-WebSocket-Extensions'), isNull);
        final socket = await WebSocketTransformer.upgrade(
          request,
          compression: CompressionOptions.compressionOff,
        );
        upgraded.complete(socket);
        socket.add(hello(heartbeat: 1));
        socket.add(message(1));
      });
      final attempt = connectWebSocket(
        ReceiverConfig('http://127.0.0.1:${server.port}', 'ab'),
      );
      final connection = await attempt.connected;
      final frames = <Object?>[];
      final listening = connection.frames.listen(frames.add);
      final socket = await upgraded.future;
      final receivedApplicationFrames = <Object?>[];
      final serverListening = socket.listen(receivedApplicationFrames.add);
      connection.pingInterval = const Duration(seconds: 1);
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(frames, hasLength(2));
      expect(socket.readyState, WebSocket.open);
      expect(receivedApplicationFrames, isEmpty);
      await listening.cancel();
      await connection.close();
      await serverListening.cancel();
      await socket.close();
      await subscription.cancel();
      await server.close(force: true);
    },
  );

  test(
    'cancelled handshake does not produce a usable receive connection',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final arrived = Completer<void>();
      final subscription = server.listen((request) {
        arrived.complete();
      });
      final attempt = connectWebSocket(
        ReceiverConfig('http://127.0.0.1:${server.port}', 'ab'),
      );
      final expectation = expectLater(
        attempt.connected,
        throwsA(isA<ReceiverFailure>()),
      );
      await arrived.future;
      attempt.cancel();
      await expectation;
      await subscription.cancel();
      await server.close(force: true);
    },
  );
}
