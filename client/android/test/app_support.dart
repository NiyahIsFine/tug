import 'dart:async';

import 'package:tug_android/app_controller.dart';

final class PageNotificationFake implements PageNotifications {
  bool permission = true;
  bool? permissionAfterRequest;
  int requests = 0;
  int tests = 0;
  Completer<void>? permissionBarrier;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> enabled() async => permission;

  @override
  Future<void> requestPermission() async {
    ++requests;
    await permissionBarrier?.future;
    permission = permissionAfterRequest ?? permission;
  }

  @override
  Future<void> test() async => ++tests;
}

final class ServiceFake implements ReceiverService {
  bool running = false;
  bool subscribe = false;
  bool respond = true;
  bool failStart = false;
  int starts = 0;
  int stops = 0;
  int sequence = 0;
  Completer<void>? startBarrier;
  Completer<void>? snapshotBarrier;
  final callbacks = <void Function(Object)>[];
  final commands = <Map<String, Object?>>[];
  Map<String, Object?> snapshot = {
    'status': 'connected',
    'receiving': true,
    'server': 'https://example.com/',
    'has_token': true,
    'notifications_enabled': true,
    'messages': <Object?>[],
  };
  Map<String, Object?>? latestCommand;

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<void> start() async {
    ++starts;
    await startBarrier?.future;
    if (failStart) throw StateError('service launch failed');
    running = true;
  }

  @override
  Future<void> stop() async {
    ++stops;
    running = false;
  }

  @override
  void addCallback(void Function(Object) callback) => callbacks.add(callback);

  @override
  void removeCallback(void Function(Object) callback) =>
      callbacks.remove(callback);

  @override
  void send(Map<String, Object?> command) {
    commands.add(command);
    if (command['type'] == 'unsubscribe') {
      subscribe = false;
      return;
    }
    latestCommand = command;
    if (!respond) return;
    unawaited(_reply(command));
  }

  Future<void> _reply(Map<String, Object?> command) async {
    if (command['type'] == 'snapshot') {
      subscribe = command['subscribe'] == true;
      await snapshotBarrier?.future;
    }
    if (command['type'] == 'stop') {
      running = false;
      snapshot = {...snapshot, 'status': 'stopped', 'receiving': false};
    }
    emit({
      'kind': 'response',
      'session': 'service-1',
      'sequence': sequence,
      'client_id': command['client_id'],
      'request_id': command['request_id'],
      'ok': true,
      'snapshot': snapshot,
    });
  }

  void emit(Object data) {
    for (final callback in List.of(callbacks)) {
      callback(data);
    }
  }

  void event(Map<String, Object?> data) {
    snapshot = data;
    if (latestCommand == null) return;
    emit({
      'kind': 'event',
      'session': 'service-1',
      'sequence': ++sequence,
      'client_id': latestCommand!['client_id'],
      'snapshot': snapshot,
    });
  }
}
