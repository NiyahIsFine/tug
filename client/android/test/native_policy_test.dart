import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('static check: vendored service has no restart alarm call', () {
    final source = File(
      'vendor/flutter_foreground_task/android/src/main/kotlin/com/pravera/flutter_foreground_task/service/ForegroundService.kt',
    ).readAsStringSync();
    expect(source, isNot(contains('RestartReceiver.setRestartAlarm')));
  });

  test('manifest removes background recovery receivers and permissions', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('service.RestartReceiver" tools:node="remove"'));
    expect(manifest, contains('service.RebootReceiver" tools:node="remove"'));
    expect(
      manifest,
      contains(
        'android.permission.RECEIVE_BOOT_COMPLETED" tools:node="remove"',
      ),
    );
    expect(
      manifest,
      contains('android.permission.WAKE_LOCK" tools:node="remove"'),
    );
  });

  test(
    'manifest declares special-use service without stopping on task removal',
    () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('android:foregroundServiceType="specialUse"'));
      expect(manifest, contains('android:stopWithTask="false"'));
    },
  );

  test('manifest disables application backup', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('android:allowBackup="false"'));
  });

  test('static check: service start and restart paths reference the guard', () {
    final source = File(
      'vendor/flutter_foreground_task/android/src/main/kotlin/com/pravera/flutter_foreground_task/service/ForegroundService.kt',
    ).readAsStringSync();
    expect(source, contains('startGuard?.invoke(this, intent)'));
    expect(source, contains('startGuard?.invoke(this, null) != false'));
  });

  test(
    'static check: application registers recovery and the startup guard',
    () {
      final application = File(
        'android/app/src/main/kotlin/dev/tug/tug_android/TugApplication.kt',
      ).readAsStringSync();
      expect(
        application,
        contains('ReceiveRecovery.reconcileUserStop(applicationContext)'),
      );
      expect(
        application,
        contains(
          'ForegroundService.startGuard = ReceiveRecovery::allowServiceStart',
        ),
      );
    },
  );

  test('static check: resume channel references the intent revision policy', () {
    final channel = File(
      'android/app/src/main/kotlin/dev/tug/tug_android/ReceiveIntentChannel.kt',
    ).readAsStringSync();
    expect(channel, contains('RecoveryPolicy.canResumeOnOpen'));
  });
}
