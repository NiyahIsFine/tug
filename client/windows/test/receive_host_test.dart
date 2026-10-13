import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tug_core/tug_core.dart';
import 'package:tug_windows/app_controller.dart';
import 'package:tug_windows/settings.dart';
import 'package:tug_windows/host_protocol.dart';
import 'package:tug_windows/host_server.dart';
import 'package:tug_windows/remote_controller.dart';

import 'support.dart';

void main() {
  test('real receive survives page changes/save failure/notification failure; stop persists', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final socketReady = Completer<WebSocket>();
    var upgrades = 0;
    final requests = server.listen((request) async {
      upgrades++;
      final socket = await WebSocketTransformer.upgrade(request);
      if (!socketReady.isCompleted) socketReady.complete(socket);
      socket.add(
        jsonEncode({
          'type': 'hello',
          'version': 1,
          'heartbeat_interval_seconds': 120,
          'server_time': '2026-10-10T00:00:00Z',
        }),
      );
    });
    final config = ReceiverConfig('http://127.0.0.1:${server.port}', 'ab');
    final store = MemoryStore(AppSettings(configuration: config));
    final sink = FakeNotifications();
    final controller = ReceiveController(
      store: store,
      startup: FakeStartup(),
      notifications: sink,
    );
    final host = HostServer(controller);
    RemoteController? view;
    final connected = controller.receiver.events.firstWhere(
      (event) =>
          event is SnapshotEvent &&
          event.snapshot.status == ReceiverStatus.connected,
    );
    Future<void> sendMessage(String id, String body) async {
      final received = controller.receiver.events.firstWhere(
        (event) => event is MessageEvent && event.message.id == id,
      );
      final socket = await socketReady.future;
      socket.add(
        jsonEncode({
          'type': 'message',
          'version': 1,
          'message': {
            'id': id,
            'title': 'Alert',
            'body': body,
            'timestamp': '2026-10-10T00:00:00Z',
            'received_at': '2026-10-10T00:00:01Z',
          },
        }),
      );
      await received.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
    }

    try {
      await controller.initialize();
      await connected.timeout(const Duration(seconds: 5));
      await host.start();
      view = RemoteController(host.port, host.capability);
      await view.initialize();
      expect(view.snapshot.status, ReceiverStatus.connected);
      expect(jsonEncode(host.snapshot), isNot(contains('receive_token')));
      expect((host.snapshot['settings'] as Map).keys, isNot(contains('token')));
      final anonymous = HttpClient();
      try {
        final request = await anonymous.postUrl(
          Uri.http('127.0.0.1:${host.port}', '/command'),
        );
        request.write(jsonEncode({'type': 'receiving', 'enabled': false}));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.forbidden);
        await response.drain<void>();
        expect(controller.settings.receiving, isTrue);
      } finally {
        anonymous.close(force: true);
      }
      final socket = await socketReady.future;
      await sendMessage(
        '550e8400-e29b-41d4-a716-446655440000',
        'Message delivered to notifications',
      );
      expect(sink.shown.single.body, 'Message delivered to notifications');
      await view.refreshStartup();
      expect(
        view.snapshot.messages.single.body,
        'Message delivered to notifications',
      );
      view.openPage(AppPage.settings);
      view.openPage(AppPage.messages);
      await view.shutdown();
      expect(controller.snapshot.status, ReceiverStatus.connected);
      sink.fail = true;
      controller.openPage(AppPage.settings);
      controller.openPage(AppPage.messages);
      store.fail = true;
      expect(
        await controller.saveTarget('http://127.0.0.1:9', 'new-secret'),
        isFalse,
      );
      expect(controller.snapshot.status, ReceiverStatus.connected);
      await sendMessage(
        '550e8400-e29b-41d4-a716-446655440001',
        'Message retained after notification failure',
      );
      expect(
        controller.snapshot.messages.first.body,
        'Message retained after notification failure',
      );
      expect(controller.notificationDiagnostic, contains('failed'));
      expect(upgrades, 1);
      store.fail = false;
      view = RemoteController(host.port, host.capability);
      await view.initialize();
      expect(
        view.snapshot.messages.first.body,
        'Message retained after notification failure',
      );
      expect(view.settings.configuration?.address, config.address);
      sink.fail = false;
      await view.testNotification();
      expect(sink.shown.last.id, 'test');
      expect(
        await handleHostCommand(controller, {
          'type': 'save_target',
          'address': config.address,
          'token': '',
        }),
        isTrue,
      );
      expect(controller.settings.configuration?.receiveToken, 'ab');
      expect(upgrades, 1);
      expect(await view.setReceiving(false), isTrue);
      await controller.receiver.recoveryHint();
      await controller.receiver.networkChanged(true);
      expect(controller.snapshot.status, ReceiverStatus.stopped);
      await host.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(view.error, contains('disconnected'));
      expect(view.canSave, isFalse);
      await controller.shutdown();
      final reopenedNotifications = FakeNotifications();
      final reopened = AppController(
        store: store,
        startup: FakeStartup(),
        notifications: reopenedNotifications,
      );
      addTearDown(reopened.shutdown);
      await reopened.initialize();
      expect(reopened.snapshot.status, ReceiverStatus.stopped);
      expect(
        reopened.snapshot.messages.first.body,
        'Message retained after notification failure',
      );
      expect(reopened.snapshot.messages, hasLength(2));
      expect(reopenedNotifications.shown, isEmpty);
      expect(upgrades, 1);
      await reopened.shutdown();
      await socket.close();
    } finally {
      await view?.shutdown();
      await host.close();
      await controller.shutdown();
      await requests.cancel();
      await server.close(force: true);
    }
  });

  test(
    'Exit waits for pending atomic save but does not start receiver afterward',
    () async {
      final store = MemoryStore(const AppSettings(receiving: false));
      final controller = AppController(
        store: store,
        startup: FakeStartup(),
        notifications: FakeNotifications(),
      );
      await controller.initialize();
      store.barrier = Completer<void>();
      final saving = controller.saveTarget('http://localhost:9', 'ab');
      var ended = false;
      final shuttingDown = controller.shutdown().then((_) {
        ended = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(ended, isFalse);
      store.barrier!.complete();
      expect(await saving, isTrue);
      await shuttingDown;
      expect(controller.snapshot.messages, isEmpty);
      expect(store.saved!.receiving, isFalse);
    },
  );
}
