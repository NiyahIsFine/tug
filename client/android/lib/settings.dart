import 'package:tug_core/tug_core.dart';

final class ReceiveIntent {
  const ReceiveIntent({required this.enabled, required this.revision});
  final bool enabled;
  final int revision;
}

final class AppPreferences {
  const AppPreferences({this.recoveryError});
  final String? recoveryError;
}

abstract interface class AndroidStore {
  Future<ReceiveIntent> readIntent();
  Future<ReceiveIntent> setReceiving(bool enabled, {int? expectedRevision});
  Future<void> allowForegroundResume({required int expectedRevision});
  Future<ReceiverConfig?> readConfiguration();
  Future<void> saveConfiguration(ReceiverConfig configuration);
  Future<AppPreferences> readPreferences();
  Future<bool> claimNotificationPrompt();
  Future<bool?> readBackgroundRestricted();
  Future<List<ReceivedMessage>> readHistory();
  Future<void> saveHistory(List<ReceivedMessage> messages);
}

final class IntentConflict implements Exception {
  const IntentConflict();
}
