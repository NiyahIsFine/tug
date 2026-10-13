import 'config.dart';
import 'receiver.dart';

extension ReceiverDataControl on TugReceiver {
  Future<Map<String, Object?>> executeDataCommand(
    Map<String, Object?> command,
  ) async {
    final requestId = command['request_id'];
    if (requestId is! String || requestId.isEmpty || requestId.length > 128) {
      return {'ok': false, 'error': 'Invalid control request ID.'};
    }
    try {
      switch (command['type']) {
        case 'snapshot':
          break;
        case 'start':
          await start();
        case 'stop':
          await stop();
        case 'reconnect':
          await reconnect();
        case 'recovery':
          await recoveryHint();
        case 'network':
          final available = command['available'];
          if (available is! bool) {
            throw const FormatException();
          }
          await networkChanged(available);
        case 'configure':
          final server = command['server'];
          final token = command['receive_token'];
          if (server is! String || token is! String) {
            throw const FormatException();
          }
          await updateConfiguration(ReceiverConfig(server, token));
        case 'dispose':
          await dispose();
        default:
          throw const FormatException();
      }
      return {
        'request_id': requestId,
        'ok': true,
        'snapshot': snapshot.toData(),
      };
    } on ConfigurationException catch (error) {
      return {'request_id': requestId, 'ok': false, 'error': error.reason};
    } catch (_) {
      return {
        'request_id': requestId,
        'ok': false,
        'error': 'Invalid control request or receiver already disposed.',
      };
    }
  }
}
