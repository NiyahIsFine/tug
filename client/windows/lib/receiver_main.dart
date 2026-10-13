import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tug_core/tug_core.dart';

import 'host_server.dart';
import 'platform_store.dart';
import 'receive_controller.dart';

final class HostNotifications implements NotificationSink {
  int _request = 0;
  final _pending = <int, Completer<void>>{};

  @override
  Future<void> show(ReceivedMessage message) async {
    final request = ++_request;
    final completion = Completer<void>();
    _pending[request] = completion;
    stdout.writeln(
      jsonEncode({
        'type': 'notification',
        'request': request,
        'title': message.title,
        'body': message.body,
        'id': message.id,
      }),
    );
    try {
      await completion.future.timeout(const Duration(seconds: 8));
    } finally {
      _pending.remove(request);
    }
  }

  void complete(Map<String, dynamic> command) {
    final pending = _pending.remove(command['request']);
    if (pending == null) return;
    if (command['ok'] == true) {
      pending.complete();
    } else {
      pending.completeError(StateError('System notification failed.'));
    }
  }

  @override
  Future<void> dispose() async {
    for (final completion in _pending.values) {
      completion.completeError(StateError('Receive host is closing.'));
    }
    _pending.clear();
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) exit(64);
  final notifications = HostNotifications();
  final controller = ReceiveController(
    store: SecureSettingsStore(),
    startup: WindowsStartupRegistration(executable: arguments.single),
    notifications: notifications,
  );
  final server = HostServer(controller);
  final stopped = Completer<void>();
  bool closing = false;
  Future<void>? shutdown;
  Future<void> close() => shutdown ??= () async {
    closing = true;
    await server.close();
    await controller.shutdown();
    if (!stopped.isCompleted) stopped.complete();
  }();
  final input = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          try {
            final command = jsonDecode(line) as Map<String, dynamic>;
            switch (command['type']) {
              case 'notification_result':
                notifications.complete(command);
              case 'notification_status':
                controller.notificationDiagnostic =
                    command['diagnostic'] as String?;
                controller.notifyListeners();
              case 'resume':
                unawaited(controller.receiver.recoveryHint());
              case 'network':
                unawaited(
                  controller.receiver.networkChanged(
                    command['available'] == true,
                  ),
                );
              case 'shutdown':
                unawaited(close());
            }
          } catch (_) {}
        },
        onDone: () => unawaited(close()),
        onError: (Object _) => unawaited(close()),
      );
  await server.start();
  await controller.initialize();
  if (!closing) {
    stdout.writeln(
      jsonEncode({
        'type': 'ready',
        'port': server.port,
        'capability': server.capability,
        'needs_ui':
            controller.settings.configuration == null || !controller.canSave,
      }),
    );
  }
  await stopped.future;
  await close();
  await input.cancel();
}
