import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'remote_controller.dart';
import 'ui.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.length < 3) return;
  final controller = RemoteController(int.parse(arguments[0]), arguments[1]);
  const channel = MethodChannel('dev.tug/windows_host');
  String? pending;
  bool ready = false;
  void open(String request) {
    final parts = request.split('\t');
    controller.openPage(
      parts.first == 'settings' ? AppPage.settings : AppPage.messages,
      messageId: parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null,
    );
  }

  channel.setMethodCallHandler((call) async {
    if (call.method == 'launch' && call.arguments is String) {
      if (ready) {
        open(call.arguments as String);
      } else {
        pending = call.arguments as String;
      }
    } else if (call.method == 'focus' && ready) {
      unawaited(controller.refreshStartup());
    }
  });
  await controller.initialize();
  open(pending ?? arguments.skip(2).join('\t'));
  ready = true;
  runApp(TugApp(controller: controller));
  await channel.invokeMethod<void>('ready');
}
