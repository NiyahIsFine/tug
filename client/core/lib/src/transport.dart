import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'protocol.dart';

abstract interface class ReceiveConnection {
  Stream<Object?> get frames;
  set pingInterval(Duration interval);
  Future<void> close();
}

abstract interface class ConnectionAttempt {
  Future<ReceiveConnection> get connected;
  void cancel();
}

typedef Connector = ConnectionAttempt Function(ReceiverConfig configuration);

ConnectionAttempt connectWebSocket(ReceiverConfig configuration) =>
    _IoConnectionAttempt(configuration);

final class _IoConnectionAttempt implements ConnectionAttempt {
  _IoConnectionAttempt(ReceiverConfig configuration) {
    connected = _connect(configuration);
  }

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  bool _cancelled = false;
  WebSocket? _socket;
  @override
  late final Future<ReceiveConnection> connected;

  Future<ReceiveConnection> _connect(ReceiverConfig configuration) async {
    try {
      final socket = await WebSocket.connect(
        configuration.webSocketUri.toString(),
        headers: {
          HttpHeaders.authorizationHeader:
              'Bearer ${configuration.receiveToken}',
        },
        compression: CompressionOptions.compressionOff,
        customClient: _client,
      );
      _socket = socket;
      if (_cancelled) {
        unawaited(socket.close());
        throw const ReceiverFailure(
          FailureKind.transient,
          'Connection cancelled.',
        );
      }
      return _IoReceiveConnection(socket, _client);
    } on HandshakeException {
      throw const ReceiverFailure(
        FailureKind.configuration,
        'TLS certificate check failed. Check the certificate and device clock.',
      );
    } on WebSocketException catch (error) {
      final status = error.httpStatusCode;
      if (status == 401 || status == 403) {
        throw const ReceiverFailure(
          FailureKind.authentication,
          'Authentication failed. Check the receive token.',
        );
      }
      if (status == 400 || status == 404 || status == 405) {
        throw const ReceiverFailure(
          FailureKind.configuration,
          'Invalid WebSocket address or server configuration.',
        );
      }
      throw const ReceiverFailure(
        FailureKind.transient,
        'WebSocket connection failed. Retrying shortly.',
      );
    } on IOException {
      throw const ReceiverFailure(
        FailureKind.transient,
        'Cannot reach the server. Retrying shortly.',
      );
    } finally {
      if (_socket == null) _client.close(force: true);
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _client.close(force: true);
    final socket = _socket;
    if (socket != null) unawaited(socket.close());
  }
}

final class _IoReceiveConnection implements ReceiveConnection {
  _IoReceiveConnection(this.socket, this.client);
  final WebSocket socket;
  final HttpClient client;
  @override
  Stream<Object?> get frames => socket;
  @override
  set pingInterval(Duration interval) => socket.pingInterval = interval;
  @override
  Future<void> close() async {
    client.close(force: true);
    try {
      await socket
          .close(WebSocketStatus.goingAway)
          .timeout(const Duration(seconds: 2));
    } on TimeoutException {
      return;
    }
  }
}
