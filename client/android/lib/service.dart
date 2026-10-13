import 'dart:async';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:tug_core/tug_core.dart';

import 'notifications.dart';
import 'platform_store.dart';
import 'receive_host.dart';

ForegroundTaskOptions receiveTaskOptions() => ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.nothing(),
  autoRunOnBoot: false,
  autoRunOnMyPackageReplaced: false,
  allowWakeLock: false,
  allowWifiLock: false,
  allowAutoRestart: false,
  stopWithTask: false,
);

void initializeForegroundService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'tug_service',
      channelName: 'Tug receive service',
      channelDescription: 'Background message receiving',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: receiveTaskOptions(),
  );
}

@pragma('vm:entry-point')
void startReceiveTask() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(ReceiveTaskHandler());
}

final class ReceiveTaskHandler extends TaskHandler {
  late final host = AndroidReceiveHost(
    store: PlatformStore(),
    recordStartupFailure: PlatformStore().recordRecoveryError,
    notifications: AndroidMessageNotifications(),
    send: FlutterForegroundTask.sendDataToMain,
    stopService: () async {
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) {
        throw StateError('Service stop failed.');
      }
    },
    updateStatus: (status) async {
      final result = await FlutterForegroundTask.updateService(
        notificationText: AppText.status(status),
      );
      if (result is ServiceRequestFailure) {
        throw StateError('Notification update failed.');
      }
    },
  );

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) =>
      host.initialize(
        network: Connectivity().onConnectivityChanged.map(
          (interfaces) => interfaces
              .where((interface) => interface != ConnectivityResult.none)
              .map((interface) => interface.name)
              .toList(),
        ),
      );

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) => host.dispose();

  @override
  void onReceiveData(Object data) {
    if (data is Map) {
      unawaited(
        host.handle(Map<String, Object?>.from(data)).catchError((Object _) {}),
      );
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') unawaited(host.stop().catchError((Object _) {}));
  }
}
