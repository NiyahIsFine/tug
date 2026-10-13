import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tug_core/tug_core.dart';

import 'app_controller.dart';

String _time(String? value) {
  final parsed = DateTime.tryParse(value ?? '')?.toLocal();
  if (parsed == null) return AppText.unknownTime;
  String pad(int number) => number.toString().padLeft(2, '0');
  return '${parsed.month}/${parsed.day} ${pad(parsed.hour)}:${pad(parsed.minute)}:${pad(parsed.second)}';
}

class TugPage extends StatefulWidget {
  const TugPage({super.key, required this.controller});
  final AppController controller;

  @override
  State<TugPage> createState() => _TugPageState();
}

class _TugPageState extends State<TugPage> with WidgetsBindingObserver {
  final _server = TextEditingController();
  final _token = TextEditingController();
  bool _dirty = false;
  String _scheme = 'https';
  int _page = 0;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_syncFields);
    _syncFields();
    unawaited(
      controller.setVisible(
        WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      ),
    );
  }

  void _syncFields() {
    if (!_dirty && controller.ready) {
      final address = Uri.tryParse(controller.server);
      _server.text = address?.authority ?? '';
      _scheme = address?.scheme == 'http' ? 'http' : 'https';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(controller.setVisible(state == AppLifecycleState.resumed));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_syncFields);
    controller.dispose();
    _server.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    await controller.saveConfiguration(
      '$_scheme://${_server.text.trim()}',
      _token.text,
    );
    if (!mounted || controller.error != null) return;
    _dirty = false;
    _syncFields();
    _token.clear();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(
          _page == 0
              ? 'Tug · ${AppText.messages}'
              : 'Tug · ${AppText.settings}',
        ),
        actions: [
          if (_page == 0)
            IconButton(
              tooltip: AppText.refresh,
              onPressed: controller.busy ? null : controller.refresh,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.busy) const LinearProgressIndicator(),
            if (controller.error != null)
              _feedback(controller.error!, error: true),
            if (controller.notice != null) _feedback(controller.notice!),
            Expanded(child: _page == 0 ? _messages() : _settings()),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        onDestinationSelected: (index) => setState(() => _page = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.inbox_outlined),
            selectedIcon: Icon(Icons.inbox),
            label: AppText.messages,
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: AppText.settings,
          ),
        ],
      ),
    ),
  );

  Widget _feedback(String text, {bool error = false}) => Container(
    width: double.infinity,
    color: error
        ? Theme.of(context).colorScheme.errorContainer
        : Theme.of(context).colorScheme.secondaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
  );

  Widget _status() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                controller.status == 'connected'
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_outlined,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  AppText.status(controller.status),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            controller.server.isEmpty
                ? AppText.configurationRequired
                : controller.server,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            controller.serviceRunning
                ? 'Receiving in the background.'
                : 'Receive service is stopped.',
          ),
          if (!controller.notificationsEnabled)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(AppText.notificationsDisabled),
            ),
          if (controller.diagnostic != null) Text(controller.diagnostic!),
          if (controller.platformError != null) Text(controller.platformError!),
          if (controller.historyError != null) Text(controller.historyError!),
          if (controller.retryAt != null)
            Text('Next retry: ${_time(controller.retryAt!.toIso8601String())}'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: controller.canStop
                    ? controller.stop
                    : (controller.busy || !controller.ready
                          ? null
                          : controller.start),
                icon: Icon(controller.canStop ? Icons.stop : Icons.play_arrow),
                label: Text(controller.canStop ? AppText.stop : AppText.start),
              ),
              OutlinedButton.icon(
                onPressed: controller.serviceRunning && !controller.busy
                    ? controller.reconnect
                    : null,
                icon: const Icon(Icons.sync),
                label: const Text(AppText.reconnect),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _messages() {
    final messages = controller.messages;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: messages.length + 3,
      itemBuilder: (context, index) {
        if (index == 0) return _status();
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    AppText.recentMessages,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text('${messages.length}/20'),
              ],
            ),
          );
        }
        if (index == messages.length + 2) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                if (messages.isEmpty) ...[
                  const Icon(Icons.mark_email_unread_outlined, size: 42),
                  const SizedBox(height: 12),
                  const Text(AppText.noMessages),
                  const SizedBox(height: 8),
                ],
                const Text(AppText.historySummary, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text(
                  'Uninstalling or clearing app data deletes message history.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }
        final message = messages[index - 2];
        return Card(
          key: ValueKey(message['id']),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 10,
            ),
            title: Text(
              message['title'] as String? ?? 'Untitled',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Text(
                  message['body'] as String? ?? '',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  'Received: ${_time(message['received_at'] as String?)}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showMessage(message['id'] as String),
          ),
        );
      },
    );
  }

  void _showMessage(String id) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.8,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final matches = controller.messages.where(
                (message) => message['id'] == id,
              );
              if (matches.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(AppText.messageUnavailable),
                  ),
                );
              }
              final message = matches.first;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      message['title'] as String? ?? '',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text('Sent: ${_time(message['timestamp'] as String?)}'),
                    Text(
                      'Received: ${_time(message['received_at'] as String?)}',
                    ),
                    const Divider(height: 32),
                    SelectableText(message['body'] as String? ?? ''),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _settings() => ListView(
    key: const ValueKey('settings-list'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppText.serverAndAuthentication,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                children: [
                  for (final scheme in ['https', 'http'])
                    ChoiceChip(
                      key: ValueKey('scheme-$scheme'),
                      label: Text(scheme.toUpperCase()),
                      selected: _scheme == scheme,
                      onSelected: controller.busy
                          ? null
                          : (_) => setState(() {
                              _scheme = scheme;
                              _dirty = true;
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('server-field'),
                controller: _server,
                enabled: !controller.busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                onChanged: (_) => _dirty = true,
                decoration: const InputDecoration(
                  labelText: AppText.serverAddress,
                  hintText: 'tug.example.com',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('token-field'),
                controller: _token,
                enabled: !controller.busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: AppText.receiveToken,
                  hintText: controller.hasToken
                      ? 'Leave blank to keep current token'
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: controller.busy || !controller.ready ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text(AppText.save),
              ),
            ],
          ),
        ),
      ),
      if (controller.preferences.recoveryError != null)
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.warning_amber),
                title: const Text('Background service'),
                subtitle: Text(controller.preferences.recoveryError!),
              ),
            ],
          ),
        ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Notifications and background',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              if (!controller.notificationsEnabled) ...[
                const Text(AppText.notificationsDisabled),
                const SizedBox(height: 10),
              ],
              const Text(
                'Allow Tug to run in the background in system settings.',
              ),
              if (controller.backgroundRestricted == true) ...[
                const SizedBox(height: 10),
                const Text(
                  'Background activity is restricted. Check system settings.',
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: controller.busy
                        ? null
                        : controller.testNotification,
                    child: const Text(AppText.testNotification),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
