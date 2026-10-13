import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tug_core/tug_core.dart';

import 'settings.dart';

final class PlatformStore implements AndroidStore {
  static const _channel = MethodChannel('dev.tug/receive_intent');
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  static const _configurationKey = 'receiver_configuration_v1';
  static const _historyKey = 'recent_messages_v1';

  ReceiveIntent _intent(Map<Object?, Object?> data) => ReceiveIntent(
    enabled: data['enabled'] == true,
    revision: data['revision'] as int,
  );

  @override
  Future<ReceiveIntent> readIntent() async =>
      _intent((await _channel.invokeMapMethod<Object?, Object?>('read'))!);

  @override
  Future<ReceiveIntent> setReceiving(
    bool enabled, {
    int? expectedRevision,
  }) async {
    try {
      return _intent(
        (await _channel.invokeMapMethod<Object?, Object?>('set', {
          'enabled': enabled,
          'expected_revision': expectedRevision,
        }))!,
      );
    } on PlatformException catch (error) {
      if (error.code == 'conflict') throw const IntentConflict();
      rethrow;
    }
  }

  @override
  Future<ReceiverConfig?> readConfiguration() async {
    final encoded = await _storage.read(key: _configurationKey);
    if (encoded == null) return null;
    final data = jsonDecode(encoded) as Map<String, dynamic>;
    return ReceiverConfig(data['server'] as String, data['token'] as String);
  }

  @override
  Future<void> saveConfiguration(ReceiverConfig configuration) =>
      _storage.write(
        key: _configurationKey,
        value: jsonEncode({
          'server': configuration.address,
          'token': configuration.receiveToken,
        }),
      );

  @override
  Future<AppPreferences> readPreferences() async {
    final data = await _channel.invokeMapMethod<Object?, Object?>(
      'read_preferences',
    );
    return AppPreferences(recoveryError: data?['recovery_error'] as String?);
  }

  @override
  Future<bool> claimNotificationPrompt() async =>
      await _channel.invokeMethod<bool>('claim_notification_prompt') ?? false;

  @override
  Future<bool?> readBackgroundRestricted() =>
      _channel.invokeMethod<bool>('background_restricted');

  @override
  Future<void> allowForegroundResume({required int expectedRevision}) async {
    try {
      await _channel.invokeMethod<void>('resume_foreground', {
        'expected_revision': expectedRevision,
      });
    } on PlatformException catch (error) {
      if (error.code == 'conflict') throw const IntentConflict();
      rethrow;
    }
  }

  Future<void> recordRecoveryError(String error) =>
      _channel.invokeMethod<void>('recovery_error', {'error': error});

  @override
  Future<List<ReceivedMessage>> readHistory() async {
    final encoded = await _storage.read(key: _historyKey);
    return encoded == null ? [] : RecentHistory.decode(encoded).messages;
  }

  @override
  Future<void> saveHistory(List<ReceivedMessage> messages) =>
      _storage.write(key: _historyKey, value: RecentHistory(messages).encode());
}
