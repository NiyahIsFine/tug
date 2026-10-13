import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tug_android/notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.tug/notification_permission');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('page permission request waits for native activity response', () async {
    int requests = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'request');
      expect(call.arguments, isNull);
      ++requests;
      return null;
    });
    await AndroidMessageNotifications().requestPermission();
    expect(requests, 1);
  });

  test('unavailable settings propagate without claiming permission', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    await expectLater(
      AndroidMessageNotifications().requestPermission(),
      throwsA(isA<PlatformException>()),
    );
  });
}
