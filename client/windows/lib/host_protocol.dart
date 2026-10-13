import 'receive_controller.dart';

Map<String, Object?> hostSnapshot(ReceiveController controller) => {
  ...controller.snapshot.toData(),
  'settings': {
    'server': controller.settings.configuration?.address,
    'receiving': controller.settings.receiving,
    'auto_start': controller.settings.autoStart,
  },
  'startup': {
    'enabled': controller.startupState.enabled,
    'registered': controller.startupState.registered,
    'diagnostic': controller.startupState.diagnostic,
  },
  'page': controller.page.name,
  'ready': controller.ready,
  'can_save': controller.canSave,
  'saving': controller.saving,
  'error': controller.error,
  'notification_diagnostic': controller.notificationDiagnostic,
  'history_diagnostic': controller.historyDiagnostic,
};

Future<bool> handleHostCommand(
  ReceiveController controller,
  Map<String, dynamic> command,
) async {
  switch (command['type']) {
    case 'snapshot':
      return true;
    case 'save_target':
      final address = command['address'];
      final token = command['token'];
      if (address is! String || token is! String) {
        throw const FormatException('Invalid configuration command.');
      }
      final effectiveToken = token.isEmpty
          ? controller.settings.configuration?.receiveToken ?? ''
          : token;
      return controller.saveTarget(address, effectiveToken);
    case 'receiving':
      final enabled = command['enabled'];
      if (enabled is! bool) throw const FormatException('Invalid intent.');
      return controller.setReceiving(enabled);
    case 'auto_start':
      final enabled = command['enabled'];
      if (enabled is! bool) {
        throw const FormatException('Invalid startup intent.');
      }
      return controller.setAutoStart(enabled);
    case 'reconnect':
      await controller.reconnect();
      return true;
    case 'test_notification':
      await controller.testNotification();
      return true;
    case 'refresh_startup':
      await controller.refreshStartup();
      return true;
    default:
      throw const FormatException('Unknown host command.');
  }
}
