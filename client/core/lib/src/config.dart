final class ConfigurationException implements Exception {
  const ConfigurationException(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

final class ReceiverConfig {
  ReceiverConfig(String address, this.receiveToken)
    : server = _parseAddress(address) {
    if (receiveToken.length < 2 ||
        receiveToken.codeUnits.any(
          (character) => character < 33 || character > 126,
        )) {
      throw const ConfigurationException(
        'Use at least 2 printable ASCII characters, without spaces.',
      );
    }
  }

  final Uri server;
  final String receiveToken;
  String get address => server.toString();
  bool get isEncrypted => server.scheme == 'https';
  Uri get webSocketUri =>
      server.replace(scheme: isEncrypted ? 'wss' : 'ws', path: '/api/v1/ws');

  bool matches(ReceiverConfig other) =>
      server == other.server && receiveToken == other.receiveToken;

  @override
  String toString() => 'ReceiverConfig(<redacted>)';

  static Uri _parseAddress(String address) {
    try {
      final input = address.trim();
      if (input.isEmpty ||
          input.contains(RegExp(r'[\s\\]')) ||
          input.contains('?') ||
          input.contains('#')) {
        throw const FormatException();
      }
      final uri = Uri.parse(input);
      if ((uri.scheme != 'http' && uri.scheme != 'https') ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.host.contains('%')) {
        throw const FormatException();
      }
      if (!uri.host.contains(':') &&
          (!RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(uri.host) ||
              uri.host
                  .split('.')
                  .any(
                    (label) =>
                        label.isEmpty ||
                        label.startsWith('-') ||
                        label.endsWith('-') ||
                        label.length > 63,
                  ))) {
        throw const FormatException();
      }
      return uri.replace(path: '/');
    } on FormatException {
      throw const ConfigurationException(
        'Enter an HTTP or HTTPS server address. No path, query, or fragment.',
      );
    }
  }
}
