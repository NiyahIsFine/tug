import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tug_android/app_controller.dart';
import 'package:tug_android/app_page.dart';
import 'package:tug_android/settings.dart';
import 'package:tug_core/tug_core.dart';

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

  Future<void> show(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: TugPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settings(WidgetTester tester) async {
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
  }

  testWidgets('host input preserves bracketed IPv6 and rejects path prefixes', (
    tester,
  ) async {
    await show(tester);
    await settings(tester);
    final server = find.byKey(const ValueKey('server-field'));
    await tester.enterText(server, '[::1]:8443');
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.configuration!.address, 'https://[::1]:8443/');
    expect(tester.widget<TextField>(server).controller!.text, '[::1]:8443');
    await tester.ensureVisible(server);
    await tester.pumpAndSettle();
    await tester.enterText(server, 'example.com/path');
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(controller.error, isNotNull);
    expect(store.configuration!.address, 'https://[::1]:8443/');
  });

  testWidgets(
    'test notification sends only after permission is granted',
    (tester) async {
      notifications.permission = false;
      store.notificationPromptHandled = true;
      await show(tester);
      await settings(tester);
      await tester.ensureVisible(find.text('Test notification'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test notification'));
      await tester.pumpAndSettle();
      expect(notifications.requests, 1);
      expect(notifications.tests, 0);
      notifications.permissionAfterRequest = true;
      await tester.ensureVisible(find.text('Test notification'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test notification'));
      await tester.pumpAndSettle();
      expect(notifications.tests, 1);
    },
  );

  testWidgets(
    'protocol selector restores saved HTTP address and saves host with port',
    (tester) async {
      store.configuration = ReceiverConfig(
        'http://127.0.0.1:16640',
        'secret-token',
      );
      await show(tester);
      await settings(tester);
      final server = find.byKey(const ValueKey('server-field'));
      expect(
        tester.widget<TextField>(server).controller!.text,
        '127.0.0.1:16640',
      );
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('scheme-http')))
            .selected,
        true,
      );
      await tester.tap(find.byKey(const ValueKey('scheme-https')));
      await tester.enterText(server, 'example.com:8443');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(store.configuration!.address, 'https://example.com:8443/');
      expect(
        tester.widget<TextField>(server).controller!.text,
        'example.com:8443',
      );
    },
  );

  testWidgets(
    'stop keeps message list and selectable detail across page reopen',
    (tester) async {
      final received = (parseServerFrame(message(1)) as MessageFrame).message;
      store.history = [received];
      service.running = true;
      service.snapshot = {
        ...service.snapshot,
        'messages': [received.toData()],
      };
      await show(tester);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.text('1/20'), findsOneWidget);
      await tester.tap(find.text(received.title));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == received.body,
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      controller = AppController(
        store: store,
        service: service,
        notifications: notifications,
      );
      await show(tester);
      expect(find.text('1/20'), findsOneWidget);
      expect(find.text(received.title), findsOneWidget);
      expect(service.starts, 0);
    },
  );

  testWidgets(
    'unconfigured empty page guides setup without automatic service start',
    (tester) async {
      store.configuration = null;
      await show(tester);
      expect(find.text('Not configured'), findsOneWidget);
      expect(find.text(AppText.noMessages), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
      expect(service.starts, 0);
      await settings(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('token-field')))
            .obscureText,
        true,
      );
      expect(find.text('Connect on launch'), findsNothing);
    },
  );

  testWidgets(
    'detail displays selectable plain text and reports evicted messages',
    (tester) async {
      service.running = true;
      service.snapshot = {
        ...service.snapshot,
        'messages': [
          {
            'id': 'one',
            'title': 'Message title 😀',
            'body': '<script>alert(1)</script>\nhttps://example.com/test',
            'timestamp': '2026-10-12T00:00:00Z',
            'received_at': '2026-10-12T00:00:01Z',
          },
        ],
      };
      await show(tester);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('1/20'), findsOneWidget);
      await tester.tap(find.text('Message title 😀'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText && widget.data!.contains('<script>'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Messages are plain text. Links do not open automatically.'),
        findsNothing,
      );
      service.event({...service.snapshot, 'messages': <Object?>[]});
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This message is no longer available.'),
        findsOneWidget,
      );
      expect(service.starts, 0);
    },
  );

  testWidgets(
    'settings never refill token, preserve drafts and clear successfully saved input',
    (tester) async {
      await show(tester);
      await settings(tester);
      final token = find.byKey(const ValueKey('token-field'));
      final server = find.byKey(const ValueKey('server-field'));
      expect(tester.widget<TextField>(token).controller!.text, isEmpty);
      await tester.enterText(server, 'draft.example.com');
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(server).controller!.text,
        'draft.example.com',
      );
      final secret = store.configuration!.receiveToken;
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(store.configuration!.receiveToken, secret);
      expect(store.configuration!.address, 'https://draft.example.com/');
      expect(tester.widget<TextField>(token).controller!.text, isEmpty);
      await tester.ensureVisible(token);
      await tester.enterText(token, 'replacement-secret');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(store.configuration!.receiveToken, 'replacement-secret');
      expect(tester.widget<TextField>(token).controller!.text, isEmpty);
    },
  );

  testWidgets('failed save keeps editable credentials and reports failure', (
    tester,
  ) async {
    await show(tester);
    await settings(tester);
    store.failSave = true;
    final token = find.byKey(const ValueKey('token-field'));
    await tester.enterText(token, 'not-saved');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Operation failed'), findsOneWidget);
    expect(tester.widget<TextField>(token).controller!.text, 'not-saved');
    expect(store.configuration!.receiveToken, isNot('not-saved'));
  });

  testWidgets(
    'Home suspends UI events and resume restores cache without stopping reception',
    (tester) async {
      service.running = true;
      await show(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(service.subscribe, false);
      expect(service.stops, 0);
      final commandCount = service.commands.length;
      await tester.pump(const Duration(minutes: 2));
      expect(service.commands.length, commandCount);
      service.snapshot = {...service.snapshot, 'status': 'reconnecting'};
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.subscribe, true);
      expect(find.text('Reconnecting'), findsOneWidget);
      expect(service.starts, 0);
    },
  );

  testWidgets('start remains cancellable while service launch is pending', (
    tester,
  ) async {
    await show(tester);
    service.startBarrier = Completer<void>();
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    service.startBarrier!.complete();
    await tester.pumpAndSettle();
    expect(service.starts, 1);
    expect(service.running, false);
    expect(store.intent.enabled, false);
    expect(find.text('Start'), findsOneWidget);
  });
}
