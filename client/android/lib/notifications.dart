import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:tug_core/tug_core.dart';

import 'receive_host.dart';
import 'app_controller.dart';

final class AndroidMessageNotifications
    implements MessageNotifications, PageNotifications {
  final plugin = FlutterLocalNotificationsPlugin();
  AndroidFlutterLocalNotificationsPlugin? get android => plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<void> initialize() async {
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_tug'),
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'tug_messages',
        'Tug messages',
        description: 'New message notifications',
        importance: Importance.high,
      ),
    );
  }

  @override
  Future<bool> enabled() async =>
      await android?.areNotificationsEnabled() ?? false;

  @override
  Future<void> requestPermission() async {
    await const MethodChannel('dev.tug/notification_permission')
        .invokeMethod<void>('request');
  }

  @override
  Future<void> show(ReceivedMessage message, int slot) => plugin.show(
    id: 100 + slot,
    title: message.title,
    body: message.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'tug_messages',
        'Tug messages',
        icon: 'ic_stat_tug',
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
        styleInformation: BigTextStyleInformation(
          message.body,
          htmlFormatBigText: false,
          htmlFormatContentTitle: false,
          htmlFormatContent: false,
        ),
      ),
    ),
  );

  @override
  Future<void> test() => plugin.show(
    id: 99,
    title: AppText.testNotificationTitle,
    body: AppText.testNotificationBody,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'tug_messages',
        'Tug messages',
        icon: 'ic_stat_tug',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}
