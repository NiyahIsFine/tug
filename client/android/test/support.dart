import 'dart:async';
import 'dart:convert';

import 'package:tug_android/receive_host.dart';
import 'package:tug_android/settings.dart';
import 'package:tug_core/tug_core.dart';

final class MemoryStore implements AndroidStore {
  ReceiverConfig? configuration = ReceiverConfig(
    'https://example.com',
    'test-receive-token',
  );
  ReceiveIntent intent = const ReceiveIntent(enabled: true, revision: 1);
  AppPreferences preferences = const AppPreferences();
  bool failRead = false;
  bool failSave = false;
  bool notificationPromptHandled = false;
  bool failPromptClaim = false;
  bool? backgroundRestricted;
  bool failBackgroundRead = false;
  bool failStop = false;
  bool failForegroundResume = false;
  Completer<void>? foregroundResumeBarrier;
  int foregroundResumes = 0;
  Completer<void>? readBarrier;
  Completer<void>? saveBarrier;
  List<ReceivedMessage> history = [];
  bool failHistoryRead = false;
  bool failHistorySave = false;
  Completer<void>? historyReadBarrier;
  Completer<void>? historySaveBarrier;
  int historyWrites = 0;

  @override
  Future<List<ReceivedMessage>> readHistory() async {
    await historyReadBarrier?.future;
    if (failHistoryRead) throw StateError('history read failed');
    return List.of(history);
  }

  @override
  Future<void> saveHistory(List<ReceivedMessage> messages) async {
    ++historyWrites;
    await historySaveBarrier?.future;
    if (failHistorySave) throw StateError('history save failed');
    history = List.of(messages);
  }

  @override
  Future<ReceiveIntent> readIntent() async => intent;

  @override
  Future<void> allowForegroundResume({required int expectedRevision}) async {
    ++foregroundResumes;
    await foregroundResumeBarrier?.future;
    if (failForegroundResume) throw StateError('foreground resume failed');
    if (!intent.enabled || intent.revision != expectedRevision) {
      throw const IntentConflict();
    }
    preferences = const AppPreferences();
  }

  @override
  Future<ReceiveIntent> setReceiving(
    bool enabled, {
    int? expectedRevision,
  }) async {
    if (failStop) throw StateError('secret storage failure');
    if (expectedRevision != null && expectedRevision != intent.revision) {
      throw const IntentConflict();
    }
    return intent = ReceiveIntent(
      enabled: enabled,
      revision: intent.revision + 1,
    );
  }

  @override
  Future<ReceiverConfig?> readConfiguration() async {
    await readBarrier?.future;
    if (failRead) throw StateError('secret storage failure');
    return configuration;
  }

  @override
  Future<void> saveConfiguration(ReceiverConfig value) async {
    await saveBarrier?.future;
    if (failSave) throw StateError('secret storage failure');
    configuration = value;
  }

  @override
  Future<AppPreferences> readPreferences() async => preferences;

  @override
  Future<bool> claimNotificationPrompt() async {
    if (failPromptClaim) throw StateError('prompt claim failed');
    if (notificationPromptHandled) return false;
    notificationPromptHandled = true;
    return true;
  }

  @override
  Future<bool?> readBackgroundRestricted() async {
    if (failBackgroundRead) throw StateError('background query failed');
    return backgroundRestricted;
  }
}

final class FakeNotifications implements MessageNotifications {
  bool permission = true;
  bool fail = false;
  bool failInitialize = false;
  Completer<void>? barrier;
  int attempts = 0;
  final shown = <String>[];
  final slots = <int>[];
  @override
  Future<void> initialize() async {
    if (failInitialize) throw StateError('plugin');
  }

  @override
  Future<bool> enabled() async => permission;
  @override
  Future<void> show(ReceivedMessage message, int slot) async {
    attempts++;
    await barrier?.future;
    if (fail) throw StateError('plugin');
    shown.add(message.id);
    slots.add(slot);
  }

  @override
  Future<void> test() async {
    if (!permission || fail) throw StateError('plugin');
  }
}

final class FakeConnection implements ReceiveConnection {
  final framesController = StreamController<Object?>();
  bool closed = false;
  Duration? heartbeat;
  @override
  Stream<Object?> get frames => framesController.stream;
  @override
  set pingInterval(Duration interval) {
    heartbeat = interval;
  }

  @override
  Future<void> close() async {
    closed = true;
    unawaited(framesController.close());
  }
}

final class FakeAttempt implements ConnectionAttempt {
  final completer = Completer<ReceiveConnection>();
  bool cancelled = false;
  @override
  Future<ReceiveConnection> get connected => completer.future;
  @override
  void cancel() {
    cancelled = true;
  }
}

final class FakeTransport {
  final attempts = <FakeAttempt>[];
  ConnectionAttempt connect(ReceiverConfig configuration) {
    final attempt = FakeAttempt();
    attempts.add(attempt);
    return attempt;
  }

  FakeConnection accept() {
    final connection = FakeConnection();
    attempts.last.completer.complete(connection);
    return connection;
  }
}

String hello() => jsonEncode({
  'type': 'hello',
  'version': 1,
  'heartbeat_interval_seconds': 120,
  'server_time': '2026-10-11T00:00:00Z',
});
String message(
  int sequence, {
  String body = 'Message body\nSecond line 😀',
}) => jsonEncode({
  'type': 'message',
  'version': 1,
  'message': {
    'id':
        '550e8400-e29b-41d4-a716-${sequence.toRadixString(16).padLeft(12, "0")}',
    'title': 'Tug notification',
    'body': body,
    'timestamp': '2026-10-11T00:00:00Z',
    'received_at': '2026-10-11T00:00:01Z',
  },
});
Future<void> pump() async {
  for (var iteration = 0; iteration < 6; iteration++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class HostFixture {
  HostFixture({MemoryStore? store}) : store = store ?? MemoryStore();
  final MemoryStore store;
  final notifications = FakeNotifications();
  final transport = FakeTransport();
  final sent = <Map<String, Object?>>[];
  int serviceStops = 0;
  final startupFailures = <String>[];
  bool failStartupReport = false;
  late final host = AndroidReceiveHost(
    store: store,
    recordStartupFailure: (error) async {
      if (failStartupReport) throw StateError('report failed');
      startupFailures.add(error);
    },
    notifications: notifications,
    send: sent.add,
    stopService: () async {
      serviceStops++;
    },
    updateStatus: (status) async {},
    receiver: TugReceiver(connector: transport.connect, receiving: false),
  );
  Future<void> command(
    String type, {
    String client = 'page',
    String? session,
    Map<String, Object?> arguments = const {},
  }) => host.handle({
    ...arguments,
    'type': type,
    'request_id': 'request-${sent.length}',
    'client_id': client,
    'session': session ?? host.session,
  });
  Future<FakeConnection> connect() async {
    await host.initialize();
    final connection = transport.accept();
    await pump();
    connection.framesController.add(hello());
    await pump();
    return connection;
  }
}
