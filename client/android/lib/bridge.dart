import 'dart:async';
import 'dart:math';

final class ServiceBridge {
  ServiceBridge({
    required this.send,
    this.timeout = const Duration(seconds: 8),
  });
  final void Function(Map<String, Object?>) send;
  final Duration timeout;
  final clientId =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
  final _pending = <String, Completer<Map<String, Object?>>>{};
  final _handshakes = <String>{};
  final _updates = StreamController<Map<String, Object?>>.broadcast();
  String? _session;
  int _sequence = -1;
  int _request = 0;
  bool _disposed = false;
  bool _eventsEnabled = true;
  int _viewRevision = 0;
  Map<String, Object?>? latest;

  Stream<Map<String, Object?>> get updates => _updates.stream;

  Future<Map<String, Object?>> request(
    String type, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (_disposed) throw StateError('Page subscription disposed.');
    if (type != 'snapshot' && type != 'stop' && _session == null) {
      throw StateError('Read a service snapshot before sending controls.');
    }
    final requestId = '$clientId-${++_request}';
    final completer = Completer<Map<String, Object?>>();
    _pending[requestId] = completer;
    if (type == 'snapshot') _handshakes.add(requestId);
    try {
      send({
        ...arguments,
        if (type == 'snapshot') 'subscribe': _eventsEnabled,
        if (type == 'snapshot') 'view_revision': _viewRevision,
        'type': type,
        'request_id': requestId,
        'client_id': clientId,
        'session': _session,
      });
      final response = await completer.future.timeout(timeout);
      if (response['ok'] != true) {
        throw StateError(
          response['error'] as String? ?? 'Service request failed.',
        );
      }
      return response;
    } finally {
      _pending.remove(requestId);
      _handshakes.remove(requestId);
    }
  }

  void receive(Object data) {
    if (_disposed || data is! Map || data['client_id'] != clientId) return;
    final response = Map<String, Object?>.from(data);
    final session = response['session'];
    final sequence = response['sequence'];
    if (session is! String || sequence is! int) return;
    final requestId = response['request_id'];
    final pending = _pending[requestId];
    if (response['kind'] == 'response' && pending != null) {
      if (_handshakes.contains(requestId) && _session != session) {
        _session = session;
        _sequence = -1;
      }
      if (_session != session) return;
      if (!_eventsEnabled && _handshakes.contains(requestId)) _unsubscribe();
      _acceptSnapshot(response, sequence);
      if (!pending.isCompleted) pending.complete(response);
    } else if (_eventsEnabled &&
        response['kind'] == 'event' &&
        session == _session) {
      _acceptSnapshot(response, sequence);
    }
  }

  void _acceptSnapshot(Map<String, Object?> response, int sequence) {
    if (sequence < _sequence || response['snapshot'] is! Map) return;
    _sequence = sequence;
    latest = Map<String, Object?>.from(response['snapshot'] as Map);
    if (_eventsEnabled) _updates.add(latest!);
  }

  void setEventsEnabled(bool enabled) {
    if (_disposed || _eventsEnabled == enabled) return;
    _eventsEnabled = enabled;
    ++_viewRevision;
    if (!enabled) _unsubscribe();
  }

  void _unsubscribe() {
    if (_session == null || _disposed) return;
    send({
      'type': 'unsubscribe',
      'request_id': '$clientId-${++_request}',
      'client_id': clientId,
      'session': _session,
      'view_revision': _viewRevision,
    });
  }

  void detach() {
    _session = null;
    _sequence = -1;
    latest = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Service session ended.'));
      }
    }
    _pending.clear();
    _handshakes.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    detach();
    await _updates.close();
  }
}
