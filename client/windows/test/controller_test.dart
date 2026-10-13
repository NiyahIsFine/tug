import 'package:flutter_test/flutter_test.dart';
import 'package:tug_core/tug_core.dart';
import 'package:tug_windows/app_controller.dart';
import 'package:tug_windows/settings.dart';

import 'support.dart';

void main() {
  test(
    'first launch enables startup once, subsequent user-off choice preserved',
    () async {
      final store = MemoryStore();
      final startup = FakeStartup();
      final controller = AppController(
        store: store,
        startup: startup,
        notifications: FakeNotifications(),
      );
      await controller.initialize();
      expect(controller.page, AppPage.settings);
      expect(startup.changes, 1);
      expect(controller.snapshot.status, ReceiverStatus.unconfigured);
      expect(await controller.setAutoStart(false), isTrue);
      await controller.shutdown();
      final reopened = AppController(
        store: store,
        startup: startup,
        notifications: FakeNotifications(),
      );
      await reopened.initialize();
      expect(reopened.settings.autoStart, isFalse);
      expect(startup.changes, 2);
      await reopened.shutdown();
    },
  );

  test(
    'validation and secure-save failure preserve old config and stopped intent',
    () async {
      final old = ReceiverConfig('http://localhost:16640', 'old-token');
      final store = MemoryStore(
        AppSettings(configuration: old, receiving: false),
      );
      final controller = AppController(
        store: store,
        startup: FakeStartup(),
        notifications: FakeNotifications(),
      );
      await controller.initialize();
      expect(
        await controller.saveTarget('http://localhost/path', 'ab'),
        isFalse,
      );
      expect(controller.settings.configuration, same(old));
      store.fail = true;
      expect(
        await controller.saveTarget('http://localhost:8081', 'new-token'),
        isFalse,
      );
      expect(controller.settings.configuration, same(old));
      expect(store.saved!.configuration, same(old));
      expect(controller.snapshot.status, ReceiverStatus.stopped);
      expect(controller.error, isNot(contains('old-token')));
      expect(controller.error, isNot(contains('new-token')));
      await controller.shutdown();
    },
  );
}
