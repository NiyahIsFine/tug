import 'package:flutter/foundation.dart';
import 'package:tug_core/tug_core.dart';

import 'receive_controller.dart';
import 'settings.dart';

export 'receive_controller.dart';

abstract interface class AppView implements Listenable {
  AppSettings get settings;
  StartupState get startupState;
  ReceiverSnapshot get snapshot;
  AppPage get page;
  String? get error;
  String? get notificationDiagnostic;
  String? get activationDiagnostic;
  String? get historyDiagnostic;
  String? get selectedMessageId;
  bool get saving;
  bool get canSave;
  Future<void> initialize();
  Future<bool> saveTarget(String address, String token);
  Future<bool> setReceiving(bool receiving);
  Future<bool> setAutoStart(bool enabled);
  Future<void> reconnect();
  Future<void> refreshStartup();
  Future<void> testNotification();
  void openPage(AppPage next, {String? messageId});
  Future<void> shutdown();
}

class AppController extends ReceiveController implements AppView {
  AppController({
    required super.store,
    required super.startup,
    required super.notifications,
    super.receiver,
  });
}
