import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_controller.dart';
import 'app_page.dart';
import 'notifications.dart';
import 'platform_service.dart';
import 'platform_store.dart';
import 'service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  initializeForegroundService();
  runApp(const TugApp());
}

class TugApp extends StatefulWidget {
  const TugApp({super.key});

  @override
  State<TugApp> createState() => _TugAppState();
}

class _TugAppState extends State<TugApp> {
  late final controller = AppController(
    store: PlatformStore(),
    service: PlatformReceiverService(),
    notifications: AndroidMessageNotifications(),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tug',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff25685a)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff5f7f5),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: TugPage(controller: controller),
  );
}
