import 'dart:convert';

import 'package:tug_core/tug_core.dart';

final class AppSettings {
  const AppSettings({
    this.configuration,
    this.receiving = true,
    this.autoStart = true,
  });
  final ReceiverConfig? configuration;
  final bool receiving;
  final bool autoStart;

  AppSettings copyWith({
    ReceiverConfig? configuration,
    bool? receiving,
    bool? autoStart,
  }) => AppSettings(
    configuration: configuration ?? this.configuration,
    receiving: receiving ?? this.receiving,
    autoStart: autoStart ?? this.autoStart,
  );

  String encodeSecret() => jsonEncode({
    'schema': 1,
    'server': configuration?.address,
    'receive_token': configuration?.receiveToken,
    'receiving': receiving,
    'auto_start': autoStart,
  });

  static AppSettings decodeSecret(String input) {
    final data = jsonDecode(input);
    if (data is! Map<String, dynamic> ||
        data['schema'] != 1 ||
        data['receiving'] is! bool ||
        data['auto_start'] is! bool ||
        (data['server'] == null) != (data['receive_token'] == null)) {
      throw const FormatException('Invalid saved settings format.');
    }
    final server = data['server'];
    final token = data['receive_token'];
    if (server != null && (server is! String || token is! String)) {
      throw const FormatException('Invalid saved settings format.');
    }
    return AppSettings(
      configuration: server == null
          ? null
          : ReceiverConfig(server as String, token as String),
      receiving: data['receiving'] as bool,
      autoStart: data['auto_start'] as bool,
    );
  }

  @override
  String toString() => 'AppSettings(<redacted>)';
}

abstract interface class SettingsStore {
  Future<AppSettings?> load();
  Future<void> save(AppSettings settings);
  Future<List<ReceivedMessage>> loadHistory();
  Future<void> saveHistory(List<ReceivedMessage> messages);
}

final class StartupState {
  const StartupState({
    required this.enabled,
    required this.registered,
    this.diagnostic,
  });
  final bool enabled;
  final bool registered;
  final String? diagnostic;
}

abstract interface class StartupRegistration {
  Future<StartupState> read();
  Future<void> setEnabled(bool enabled);
}
