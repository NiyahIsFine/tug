import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tug_android/app_controller.dart';
import 'package:tug_android/settings.dart';

import 'app_support.dart';
import 'support.dart';

void main() {
  late MemoryStore store;
  late ServiceFake service;
  late PageNotificationFake notifications;
  late AppController controller;
  setUp(() {
    store = MemoryStore();
    store.intent = const ReceiveIntent(enabled: false, revision: 1);
    service = ServiceFake();
    notifications = PageNotificationFake();
    controller = AppController(
      store: store,
      service: service,
      notifications: notifications,
    );
  });
  tearDown(() => controller.dispose());

  test(
    'first-open grant is reflected without starting an unconfigured service',
    () async {
      store.configuration = null;
      notifications.permission = false;
      notifications.permissionAfterRequest = true;
      await controller.setVisible(true);
      expect(notifications.requests, 1);
      expect(controller.notificationsEnabled, true);
      expect(service.starts, 0);
    },
  );

  test(
    'disposing during test authorization never posts a late notification',
    () async {
      store.notificationPromptHandled = true;
      notifications.permission = false;
      await controller.setVisible(true);
      notifications.permissionBarrier = Completer<void>();
      notifications.permissionAfterRequest = true;
      final testing = controller.testNotification();
      await pump();
      controller.dispose();
      notifications.permissionBarrier!.complete();
      await testing;
      expect(notifications.tests, 0);
    },
  );

  test(
    'first open prompts once, including across app recreation after denial',
    () async {
      notifications.permission = false;
      await controller.setVisible(true);
      expect(notifications.requests, 1);
      expect(controller.notificationsEnabled, false);
      expect(store.notificationPromptHandled, true);
      await controller.setVisible(false);
      await controller.setVisible(true);
      await controller.refresh();
      expect(notifications.requests, 1);
      controller.dispose();
      controller = AppController(
        store: store,
        service: service,
        notifications: notifications,
      );
      await controller.setVisible(true);
      expect(notifications.requests, 1);
    },
  );

  test('first open with permission already enabled never prompts later automatically', () async {
    await controller.setVisible(true);
    expect(notifications.requests, 0);
    notifications.permission = false;
    await controller.setVisible(false);
    await controller.setVisible(true);
    expect(controller.notificationsEnabled, false);
    expect(notifications.requests, 0);
  });

  test('test requests permission each time after denial and only posts after grant', () async {
    notifications.permission = false;
    await controller.setVisible(true);
    await controller.testNotification();
    expect(notifications.requests, 2);
    expect(notifications.tests, 0);
    await controller.testNotification();
    expect(notifications.requests, 3);
    expect(notifications.tests, 0);
    notifications.permissionAfterRequest = true;
    await controller.testNotification();
    expect(notifications.requests, 4);
    expect(notifications.tests, 1);
    expect(controller.notificationsEnabled, true);
    await controller.testNotification();
    expect(notifications.requests, 4);
    expect(notifications.tests, 2);
  });

  test(
    'test waits for settings return before checking grant or sending',
    () async {
      store.notificationPromptHandled = true;
      notifications.permission = false;
      await controller.setVisible(true);
      notifications.permissionBarrier = Completer<void>();
      notifications.permissionAfterRequest = true;
      final testing = controller.testNotification();
      await pump();
      await controller.setVisible(false);
      expect(notifications.tests, 0);
      await controller.setVisible(true);
      notifications.permissionBarrier!.complete();
      await testing;
      await pump();
      expect(notifications.tests, 1);
      expect(notifications.requests, 1);
    },
  );

  test('background detection refreshes independently and query failure stays unknown', () async {
    store.backgroundRestricted = true;
    await controller.setVisible(true);
    expect(controller.backgroundRestricted, true);
    store.backgroundRestricted = false;
    await controller.refresh();
    expect(controller.backgroundRestricted, false);
    store.failBackgroundRead = true;
    await controller.refresh();
    expect(controller.backgroundRestricted, isNull);
    expect(controller.error, isNull);
  });

  test('saved stopped intent never starts on open or resume', () async {
    await controller.setVisible(true);
    expect(service.starts, 0);
    store.intent = const ReceiveIntent(enabled: false, revision: 2);
    await controller.setVisible(false);
    await controller.setVisible(true);
    expect(service.starts, 0);
  });

  test(
    'open resumes saved enabled intent without a preference or revision change',
    () async {
      store.intent = const ReceiveIntent(enabled: true, revision: 1);
      await controller.setVisible(true);
      expect(service.starts, 1);
      expect(store.intent.revision, 1);
      expect(notifications.requests, 0);
      expect(store.foregroundResumes, 1);
      await controller.stop();
      await controller.setVisible(false);
      await controller.setVisible(true);
      expect(service.starts, 1);
      expect(store.intent.enabled, false);
    },
  );

  test(
    'paused page unsubscribes without stopping and resumes latest cache once',
    () async {
      service.running = true;
      await controller.setVisible(true);
      await controller.setVisible(false);
      expect(service.commands.last['type'], 'unsubscribe');
      service.event({
        ...service.snapshot,
        'messages': [
          {'id': 'background', 'title': 'New message'},
        ],
      });
      expect(controller.messages, isEmpty);
      expect(service.stops, 0);
      await controller.setVisible(true);
      expect(controller.messages.single['id'], 'background');
      expect(
        service.commands.where((command) => command['type'] == 'snapshot'),
        hasLength(2),
      );
      expect(service.starts, 0);
    },
  );

  test('recreated app restores reception after process loss but retains explicit stop', () async {
    await controller.setVisible(true);
    await controller.start();
    expect(store.intent.enabled, true);
    controller.dispose();
    service.running = false;
    controller = AppController(
      store: store,
      service: service,
      notifications: notifications,
    );
    await controller.setVisible(true);
    expect(service.starts, 2);
    expect(controller.status, 'connected');
    expect(notifications.requests, 0);
    await controller.stop();
    controller.dispose();
    controller = AppController(
      store: store,
      service: service,
      notifications: notifications,
    );
    await controller.setVisible(true);
    expect(service.starts, 2);
    expect(controller.status, 'stopped');
  });

  test('foreground resume clears system-stop warning', () async {
    store.intent = const ReceiveIntent(enabled: true, revision: 7);
    store.preferences = const AppPreferences(
      recoveryError: 'Background service paused. Open Tug to resume.',
    );
    await controller.setVisible(true);
    expect(service.starts, 1);
    expect(store.intent.revision, 7);
    expect(store.preferences.recoveryError, isNull);
    expect(controller.preferences.recoveryError, isNull);
    expect(notifications.requests, 0);
  });

  test('enabled intent without configuration does not resume', () async {
    store.intent = const ReceiveIntent(enabled: true, revision: 1);
    store.configuration = null;
    await controller.setVisible(true);
    expect(service.starts, 0);
    expect(store.foregroundResumes, 0);
  });

  test(
    'stop preempts pending foreground allowance and never resumes stale intent',
    () async {
      store.intent = const ReceiveIntent(enabled: true, revision: 1);
      store.foregroundResumeBarrier = Completer<void>();
      final opening = controller.setVisible(true);
      await pump();
      expect(store.foregroundResumes, 1);
      await controller.stop();
      store.foregroundResumeBarrier!.complete();
      await opening;
      expect(service.starts, 0);
      expect(store.intent.enabled, false);
    },
  );

  test(
    'hidden page cannot launch service after pending foreground allowance',
    () async {
      store.intent = const ReceiveIntent(enabled: true, revision: 1);
      store.foregroundResumeBarrier = Completer<void>();
      final opening = controller.setVisible(true);
      await pump();
      await controller.setVisible(false);
      store.foregroundResumeBarrier!.complete();
      await opening;
      expect(service.starts, 0);
      expect(store.intent.enabled, true);
      await controller.setVisible(true);
      expect(service.starts, 1);
    },
  );

  test(
    'failed foreground allowance never launches or rewrites reception',
    () async {
      store.intent = const ReceiveIntent(enabled: true, revision: 1);
      store.failForegroundResume = true;
      await controller.setVisible(true);
      expect(service.starts, 0);
      expect(store.intent.enabled, true);
      expect(store.intent.revision, 1);
      expect(controller.error, isNotNull);
    },
  );

  test('failed resumed launch retains intent for next app restart', () async {
    store.intent = const ReceiveIntent(enabled: true, revision: 1);
    service.failStart = true;
    await controller.setVisible(true);
    expect(controller.error, isNotNull);
    expect(store.intent.enabled, true);
    expect(store.intent.revision, 1);
    controller.dispose();
    service.failStart = false;
    controller = AppController(
      store: store,
      service: service,
      notifications: notifications,
    );
    await controller.setVisible(true);
    expect(service.starts, 2);
    expect(controller.status, 'connected');
  });

  test(
    'pause during initial handshake cancels subscription after late response',
    () async {
      service.running = true;
      service.snapshotBarrier = Completer<void>();
      final opening = controller.setVisible(true);
      await pump();
      await controller.setVisible(false);
      service.snapshotBarrier!.complete();
      await opening;
      expect(service.subscribe, false);
      expect(service.commands.last['type'], 'unsubscribe');
      expect(service.stops, 0);
    },
  );

  test('start never prompts for notification permission again', () async {
    notifications.permission = false;
    await controller.setVisible(true);
    expect(notifications.requests, 1);
    await controller.start();
    expect(notifications.requests, 1);
    expect(service.starts, 1);
  });

  test('stop during resumed service launch releases late service without restarting', () async {
    store.intent = const ReceiveIntent(enabled: true, revision: 1);
    service.startBarrier = Completer<void>();
    final opening = controller.setVisible(true);
    await pump();
    expect(service.starts, 1);
    await controller.stop();
    service.startBarrier!.complete();
    await opening;
    expect(service.running, false);
    expect(service.stops, 1);
    expect(store.intent.enabled, false);
  });

  test('failed stop persistence suppresses local resume', () async {
    store.intent = const ReceiveIntent(enabled: true, revision: 1);
    service.running = true;
    await controller.setVisible(true);
    store.failStop = true;
    await controller.stop();
    expect(controller.error, isNotNull);
    await controller.setVisible(false);
    await controller.setVisible(true);
    expect(service.starts, 0);
  });

  test(
    'configuration validation and blank token preserve secure state',
    () async {
      await controller.setVisible(true);
      await controller.saveConfiguration('https://example.com/path', 'ab');
      expect(controller.error, isNotNull);
      expect(store.configuration!.address, 'https://example.com/');
      await controller.saveConfiguration('https://other.example', '');
      expect(controller.error, isNull);
      expect(store.configuration!.receiveToken, 'test-receive-token');
      expect(controller.server, 'https://other.example/');
      expect(service.starts, 0);
    },
  );

  test('dispose releases UI callback without stopping receiver', () async {
    service.running = true;
    await controller.setVisible(true);
    controller.dispose();
    expect(service.callbacks, isEmpty);
    expect(service.commands.last['type'], 'unsubscribe');
    expect(service.stops, 0);
  });

  test(
    'permission denial remains separate from a running connection',
    () async {
      notifications.permission = false;
      service.running = true;
      service.snapshot = {...service.snapshot, 'notifications_enabled': false};
      await controller.setVisible(true);
      expect(controller.status, 'connected');
      expect(controller.notificationsEnabled, false);
      await controller.testNotification();
      expect(notifications.tests, 0);
      expect(notifications.requests, 2);
      expect(controller.notificationsEnabled, false);
    },
  );
}
