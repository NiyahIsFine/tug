import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'host_protocol.dart';
import 'receive_controller.dart';

final class HostServer {
  HostServer(this.controller);
  final ReceiveController controller;
  final capability = _capability();

  static String _capability() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
  }

  final _views = <_HostView>{};
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  Future<void> _commands = Future.value();
  Future<void>? _shutdown;
  bool _closing = false;
  int _revision = 0;

  int get port => _server!.port;
  Map<String, Object?> get snapshot => {
    ...hostSnapshot(controller),
    'revision': _revision,
  };

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    controller.addListener(_publish);
    _requests = _server!.listen((request) {
      unawaited(_handle(request).catchError((Object _) {}));
    });
  }

  void _publish() {
    ++_revision;
    if (_closing || _views.isEmpty) return;
    final event = 'data: ${jsonEncode(snapshot)}\n\n';
    for (final view in _views.toList()) {
      view.send(event);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (_closing ||
        request.headers.value(HttpHeaders.authorizationHeader) !=
            'Bearer $capability' ||
        request.headers.value('origin') != null) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'GET' &&
        request.uri.path == '/events' &&
        _views.length < 4) {
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.bufferOutput = false;
      late final _HostView view;
      view = _HostView(request.response, () => _views.remove(view));
      _views.add(view);
      view.send('data: ${jsonEncode(snapshot)}\n\n');
      return;
    }
    if (request.method != 'POST' || request.uri.path != '/command') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    try {
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 10))) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const FormatException('Command exceeds size limit.');
        }
        bytes.addAll(chunk);
      }
      final command = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final completion = Completer<bool>();
      _commands = _commands.then((_) async {
        try {
          if (_closing) throw StateError('Host is closing.');
          completion.complete(await handleHostCommand(controller, command));
        } catch (error, stack) {
          completion.completeError(error, stack);
        }
      });
      final ok = await completion.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': ok, 'snapshot': snapshot}));
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() => _shutdown ??= () async {
    _closing = true;
    controller.removeListener(_publish);
    for (final view in _views.toList()) {
      view.close();
    }
    _views.clear();
    await _server?.close(force: true);
    await _requests?.cancel();
    await _commands;
  }();
}

final class _HostView {
  _HostView(this.response, this.onClose) {
    unawaited(
      response.done.then((_) => close(), onError: (Object _) => close()),
    );
  }
  final HttpResponse response;
  final void Function() onClose;
  String? _pending;
  bool _writing = false;
  bool _closed = false;

  void send(String event) {
    if (_closed) return;
    _pending = event;
    if (!_writing) unawaited(_drain());
  }

  Future<void> _drain() async {
    _writing = true;
    try {
      while (!_closed && _pending != null) {
        final event = _pending!;
        _pending = null;
        response.write(event);
        await response.flush();
      }
    } catch (_) {
      close();
    } finally {
      _writing = false;
      if (_closed) _closeResponse();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _pending = null;
    onClose();
    if (!_writing) _closeResponse();
  }

  void _closeResponse() {
    unawaited(Future<void>.sync(response.close).catchError((Object _) {}));
  }
}
