import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:tug_core/tug_core.dart';

import 'app_controller.dart';
import 'service.dart';

final class PlatformReceiverService implements ReceiverService {
  @override
  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  @override
  void send(Map<String, Object?> command) =>
      FlutterForegroundTask.sendDataToTask(command);

  @override
  void addCallback(void Function(Object) callback) =>
      FlutterForegroundTask.addTaskDataCallback(callback);

  @override
  void removeCallback(void Function(Object) callback) =>
      FlutterForegroundTask.removeTaskDataCallback(callback);

  @override
  Future<void> start() async {
    final result = await FlutterForegroundTask.startService(
      serviceId: 1,
      serviceTypes: [ForegroundServiceTypes.specialUse],
      notificationTitle: 'Tug receive service',
      notificationText: AppText.status('connecting'),
      notificationIcon: const NotificationIcon(
        metaDataName: 'dev.tug.NOTIFICATION_ICON',
      ),
      notificationButtons: [
        const NotificationButton(id: 'stop', text: AppText.stop),
      ],
      callback: startReceiveTask,
    );
    if (result is ServiceRequestFailure) {
      throw StateError('Service start failed.');
    }
  }

  @override
  Future<void> stop() async {
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      throw StateError('Service stop failed.');
    }
  }
}
