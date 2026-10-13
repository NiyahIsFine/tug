import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tug_core/tug_core.dart';

import 'app_controller.dart';
import 'remote_controller.dart';

class TugApp extends StatelessWidget {
  const TugApp({super.key, required this.controller});
  final AppView controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tug',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff4263eb)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff7f8fa),
    ),
    home: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Tug'),
          backgroundColor: const Color(0xfff7f8fa),
          actions: [
            TextButton(
              onPressed: () => controller.openPage(AppPage.messages),
              child: const Text(AppText.messages),
            ),
            TextButton(
              onPressed: () => controller.openPage(AppPage.settings),
              child: const Text(AppText.settings),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (controller.error != null) _Notice(controller.error!),
              if (controller.activationDiagnostic != null)
                _Notice(controller.activationDiagnostic!),
              Expanded(
                child: controller.page == AppPage.settings
                    ? SettingsPage(controller: controller)
                    : MessagesPage(controller: controller),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key, required this.controller});
  final AppView controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final status = AppText.status(snapshot.status.name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.circle,
              size: 10,
              color: snapshot.status == ReceiverStatus.connected
                  ? Colors.green
                  : Colors.grey,
            ),
            const SizedBox(width: 8),
            Text(status),
            const Spacer(),
            TextButton(
              onPressed: controller.canSave
                  ? () => unawaited(
                      controller.setReceiving(!controller.settings.receiving),
                    )
                  : null,
              child: Text(
                controller.settings.receiving ? AppText.stop : AppText.start,
              ),
            ),
            TextButton(
              onPressed: snapshot.receiving
                  ? () => unawaited(controller.reconnect())
                  : null,
              child: const Text(AppText.reconnect),
            ),
            TextButton(
              onPressed: () => unawaited(controller.testNotification()),
              child: const Text(AppText.testNotification),
            ),
          ],
        ),
        if (snapshot.diagnostic != null) _Notice(snapshot.diagnostic!),
        if (controller.notificationDiagnostic != null)
          _Notice(controller.notificationDiagnostic!),
        if (controller.historyDiagnostic != null)
          _Notice(controller.historyDiagnostic!),
        const SizedBox(height: 20),
        Text(
          AppText.recentMessages,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        const Text(
          AppText.historySummary,
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: snapshot.messages.isEmpty
              ? const Center(
                  child: Text(
                    '${AppText.noMessages}\nClose the window to keep receiving in the system tray.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.separated(
                  itemCount: snapshot.messages.length,
                  separatorBuilder: (_, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final message = snapshot.messages[index];
                    final selected = controller.selectedMessageId == message.id;
                    return Card(
                      color: selected
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Colors.white,
                      elevation: 0,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    message.title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  _time(message.receivedAt),
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SelectableText(message.body),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _time(DateTime timestamp) {
    final local = timestamp.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});
  final AppView controller;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController address;
  late final TextEditingController token;
  late String scheme;
  @override
  void initState() {
    super.initState();
    final configuration = widget.controller.settings.configuration;
    address = TextEditingController(
      text: configuration?.server.authority ?? '',
    );
    scheme = configuration?.server.scheme ?? 'https';
    token = TextEditingController(
      text: widget.controller is RemoteController
          ? ''
          : configuration?.receiveToken ?? '',
    );
  }

  @override
  void dispose() {
    address.dispose();
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final configuration = controller.settings.configuration;
    return ListView(
      children: [
        Text(
          AppText.settings,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 24),
        Card(
          elevation: 0,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Start at login'),
                  value: controller.settings.autoStart,
                  onChanged: controller.canSave
                      ? (value) => unawaited(controller.setAutoStart(value))
                      : null,
                ),
                if (controller.startupState.diagnostic != null)
                  _Notice(controller.startupState.diagnostic!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 0,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  AppText.serverAndAuthentication,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final option in ['https', 'http'])
                      ChoiceChip(
                        key: ValueKey('scheme-$option'),
                        label: Text(option.toUpperCase()),
                        selected: scheme == option,
                        onSelected: controller.saving
                            ? null
                            : (_) => setState(() => scheme = option),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('server-field'),
                  controller: address,
                  enabled: !controller.saving,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: AppText.serverAddress,
                    hintText: 'tug.example.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('token-field'),
                  controller: token,
                  enabled: !controller.saving,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: AppText.receiveToken,
                    hintText:
                        widget.controller is RemoteController &&
                            configuration != null
                        ? 'Leave blank to keep the saved token'
                        : null,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: controller.canSave
                        ? () => unawaited(
                            controller.saveTarget(
                              '$scheme://${address.text.trim()}',
                              token.text,
                            ),
                          )
                        : null,
                    child: Text(
                      controller.saving ? AppText.saving : AppText.save,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(color: Color(0xff8a5c18), fontSize: 12),
    ),
  );
}
