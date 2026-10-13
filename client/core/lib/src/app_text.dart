abstract final class AppText {
  static const messages = 'Messages';
  static const recentMessages = 'Recent messages';
  static const settings = 'Settings';
  static const serverAndAuthentication = 'Server and authentication';
  static const serverAddress = 'Server address';
  static const receiveToken = 'Receive token';
  static const save = 'Save';
  static const saving = 'Saving...';
  static const start = 'Start';
  static const stop = 'Stop';
  static const reconnect = 'Reconnect';
  static const refresh = 'Refresh';
  static const testNotification = 'Test notification';
  static const testNotificationTitle = 'Tug test notification';
  static const testNotificationBody =
      'Local test only. This does not check server delivery.';
  static const noMessages = 'No messages yet.';
  static const unknownTime = 'Unknown time';
  static const historySummary =
      'Keeps 20 messages (128 KiB), encrypted on this device, even after closing. '
      'Older messages are removed. No offline delivery.';
  static const messageUnavailable = 'This message is no longer available.';
  static const configurationRequired =
      'Add a server address and receive token in Settings.';
  static const notificationsDisabled =
      'Notifications are off. You can still receive and view messages.';
  static const notificationUnavailable =
      'Notifications are unavailable. You can still receive and view messages.';
  static const notificationFailed =
      'Notification failed. The message is still in Recent messages.';
  static const historyReadFailed =
      'Cannot load message history. Saved history is unchanged; '
      'new messages stay in memory.';
  static const historySaveFailed =
      'Cannot save message history. Messages may be lost after restarting.';

  static String status(String status) => switch (status) {
    'unconfigured' => 'Not configured',
    'stopped' => 'Stopped',
    'connecting' => 'Connecting',
    'connected' => 'Connected',
    'reconnecting' => 'Reconnecting',
    'authenticationFailed' => 'Authentication failed',
    'configurationError' => 'Configuration error',
    _ => 'Unknown status',
  };
}
