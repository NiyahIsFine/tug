import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tug_core/tug_core.dart';

import 'app_controller.dart';
import 'settings.dart';

final class RemoteController extends ChangeNotifier implements AppView {
  RemoteController(this.port, this.capability);

  @override
  AppSettings settings = const AppSettings();
  @override
  StartupState startupState = const StartupState(
    enabled: false,
    registered: false,
  );
  @override
  AppPage page = AppPage.messages;
  @override
  String? error;
  @override
  String? notificationDiagnostic;
  @override
  String? activationDiagnostic;
  @override
  String? historyDiagnostic;
  @override
  String? selectedMessageId;
  @override
  bool saving = false;

  final int port;
  final String capability;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  StreamSubscription<String>? _events;
  ReceiverSnapshot _snapshot = ReceiverSnapshot(
    status: ReceiverStatus.unconfigured,
    receiving: false,
    messages: const [],
  );
  bool _canSave = false;
  bool _closed = false;
  int _revision = -1;

  @override
  ReceiverSnapshot get snapshot => _snapshot;
  @override
  bool get canSave => !_closed && _canSave && !saving;

  Future<HttpClientRequest> _request(String method, String path) async {
    final request = await _http.openUrl(
      method,
      Uri.http('127.0.0.1:$port', path),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $capability');
    return request;
  }

  void _apply(Map<String, dynamic> data) {
    if (_closed) return;
    final revision = data['revision'] as int;
    if (revision < _revision) return;
    _revision = revision;
    final configuration = data['settings'] as Map;
    final address = configuration['server'] as String?;
    settings = AppSettings(
      configuration: address == null
          ? null
          : ReceiverConfig(address, 'redacted'),
      receiving: configuration['receiving'] == true,
      autoStart: configuration['auto_start'] == true,
    );
    final startup = data['startup'] as Map;
    startupState = StartupState(
      enabled: startup['enabled'] == true,
      registered: startup['registered'] == true,
      diagnostic: startup['diagnostic'] as String?,
    );
    _snapshot = ReceiverSnapshot(
      status: ReceiverStatus.values.byName(data['status'] as String),
      receiving: data['receiving'] == true,
      messages: (data['messages'] as List).map(
        (entry) => (parseServerFrame(
          jsonEncode({'type': 'message', 'version': 1, 'message': entry}),
        ) as MessageFrame).message,
      ),
      diagnostic: data['diagnostic'] as String?,
      retryAt: data['retry_at'] == null
          ? null
          : DateTime.parse(data['retry_at'] as String),
    );
    _canSave = data['can_save'] == true;
    error = data['error'] as String?;
    notificationDiagnostic = data['notification_diagnostic'] as String?;
    historyDiagnostic = data['history_diagnostic'] as String?;
    notifyListeners();
  }

  Future<bool> _command(Map<String, Object?> command) async {
    if (_closed || saving) return false;
    saving = true;
    notifyListeners();
    try {
      final request = await _request('POST', '/command');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(command));
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('Command failed.');
      }
      final data = jsonDecode(
        await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 15)),
      ) as Map<String, dynamic>;
      _apply(Map<String, dynamic>.from(data['snapshot'] as Map));
      return data['ok'] == true;
    } catch (_) {
      if (!_closed) {
        error =
            'Cannot reach the receive host. Close this window and reopen Tug.';
      }
      return false;
    } finally {
      saving = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  Future<void> initialize() async {
    final synchronized = await _command({'type': 'snapshot'});
    if (!synchronized || _closed) return;
    page = settings.configuration == null ? AppPage.settings : AppPage.messages;
    try {
      final response = await (await _request(
        'GET',
        '/events',
      )).close().timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('Subscription failed.');
      }
      _events = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (line.startsWith('data: ')) {
                try {
                  _apply(jsonDecode(line.substring(6)) as Map<String, dynamic>);
                } catch (_) {}
              }
            },
            onDone: _disconnected,
            onError: (Object _) => _disconnected(),
          );
    } catch (_) {
      _disconnected();
    }
  }

  void _disconnected() {
    if (_closed) return;
    _canSave = false;
    error = 'Receive host disconnected. Close this window and reopen Tug.';
    notifyListeners();
  }

  @override
  Future<bool> saveTarget(String address, String token) =>
      _command({'type': 'save_target', 'address': address, 'token': token});
  @override
  Future<bool> setReceiving(bool receiving) =>
      _command({'type': 'receiving', 'enabled': receiving});
  @override
  Future<bool> setAutoStart(bool enabled) =>
      _command({'type': 'auto_start', 'enabled': enabled});
  @override
  Future<void> reconnect() async {
    await _command({'type': 'reconnect'});
  }

  @override
  Future<void> refreshStartup() async {
    await _command({'type': 'refresh_startup'});
  }

  @override
  Future<void> testNotification() async {
    await _command({'type': 'test_notification'});
  }

  @override
  void openPage(AppPage next, {String? messageId}) {
    if (_closed) return;
    page = next;
    selectedMessageId = messageId;
    activationDiagnostic =
        messageId != null &&
            !snapshot.messages.any((message) => message.id == messageId)
        ? AppText.messageUnavailable
        : null;
    notifyListeners();
  }

  @override
  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    _http.close(force: true);
    await _events?.cancel();
    dispose();
  }
}
