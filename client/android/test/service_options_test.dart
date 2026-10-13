import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tug_android/service.dart';

void main() {
  test('prototype disables locks, periodic callbacks and alarm restarts', () {
    final options = receiveTaskOptions();
    expect(options.allowWakeLock, false);
    expect(options.allowWifiLock, false);
    expect(options.allowAutoRestart, false);
    expect(options.autoRunOnBoot, false);
    expect(options.autoRunOnMyPackageReplaced, false);
    expect(options.stopWithTask, false);
    expect(options.eventAction.type, ForegroundTaskEventType.nothing);
  });
}
