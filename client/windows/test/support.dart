import 'dart:async';

import 'package:tug_core/tug_core.dart';
import 'package:tug_windows/app_controller.dart';
import 'package:tug_windows/settings.dart';

final class MemoryStore implements SettingsStore {
  MemoryStore([this.saved]);
  AppSettings? saved;
  bool fail = false;
  Completer<void>? barrier;
  List<ReceivedMessage> history = [];

  @override
  Future<List<ReceivedMessage>> loadHistory() async {
    return List.of(history);
  }

  @override
  Future<void> saveHistory(List<ReceivedMessage> messages) async {
    history = List.of(messages);
  }

  @override
  Future<AppSettings?> load() async => saved;
  @override
  Future<void> save(AppSettings settings) async {
    if (barrier != null) await barrier!.future;
    if (fail) throw StateError('mock store unavailable');
    saved = settings;
  }
}

final class FakeStartup implements StartupRegistration {
  bool enabled = false;
  int changes = 0;
  @override
  Future<StartupState> read() async =>
      StartupState(enabled: enabled, registered: enabled);
  @override
  Future<void> setEnabled(bool value) async {
    changes++;
    enabled = value;
  }
}

final class FakeNotifications implements NotificationSink {
  bool fail = false;
  final shown = <ReceivedMessage>[];
  @override
  Future<void> show(ReceivedMessage message) async {
    if (fail) throw StateError('mock notifications unavailable');
    shown.add(message);
  }

  @override
  Future<void> dispose() async {}
}
