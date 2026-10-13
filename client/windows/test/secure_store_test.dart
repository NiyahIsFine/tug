import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tug_core/tug_core.dart';
import 'package:tug_windows/platform_store.dart';
import 'package:tug_windows/settings.dart';

void main() {
  test('DPAPI history is independent from credentials, atomic and rejects corruption without clearing settings', () async {
    final directory = await Directory.systemTemp.createTemp('tug-history-');
    try {
      final store = SecureSettingsStore(directory: directory.path);
      expect(await store.loadHistory(), isEmpty);
      final settings = AppSettings(
        configuration: ReceiverConfig('https://localhost', 'receive-secret'),
        receiving: false,
      );
      await store.save(settings);
      final settingsFile = File('${directory.path}\\settings.dpapi');
      final settingsBytes = await settingsFile.readAsBytes();
      final message = ReceivedMessage(
        id: '550e8400-e29b-41d4-a716-446655440000',
        title: 'Message history',
        body: 'Private saved message body',
        timestamp: DateTime.utc(2026, 10, 12),
        receivedAt: DateTime.utc(2026, 10, 12, 0, 0, 1),
      );
      await store.saveHistory([message]);
      final file = File('${directory.path}\\recent-messages.dpapi');
      final encrypted = await file.readAsBytes();
      expect(
        utf8.decode(encrypted, allowMalformed: true),
        isNot(contains(message.body)),
      );
      expect((await store.loadHistory()).single.toData(), message.toData());
      expect(await settingsFile.readAsBytes(), settingsBytes);
      expect(await File('${file.path}.new').exists(), false);
      await file.writeAsBytes([0, 1, 2, 3]);
      await expectLater(store.loadHistory(), throwsA(anything));
      expect(await file.readAsBytes(), [0, 1, 2, 3]);
      expect(
        (await store.load())!.configuration!.matches(settings.configuration!),
        true,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test(
    'real Windows DPAPI encrypts atomic record and rejects corrupt ciphertext',
    () async {
      final directory = await Directory.systemTemp.createTemp('tug-dpapi-');
      try {
        final store = SecureSettingsStore(directory: directory.path);
        expect(
          WindowsStartupRegistration(
            executable: r'C:\Portable Apps\Tug\tug.exe',
          ).command,
          '"C:\\Portable Apps\\Tug\\tug.exe" --background',
        );
        expect(await store.load(), isNull);
        final settings = AppSettings(
          configuration: ReceiverConfig(
            'https://localhost',
            'secret-receive-token',
          ),
          receiving: false,
          autoStart: false,
        );
        await store.save(settings);
        final file = File('${directory.path}\\settings.dpapi');
        final encrypted = await file.readAsBytes();
        expect(
          utf8.decode(encrypted, allowMalformed: true),
          isNot(contains('secret-receive-token')),
        );
        expect(
          (await store.load())!.configuration!.matches(settings.configuration!),
          isTrue,
        );
        expect((await store.load())!.receiving, isFalse);
        expect(await File('${file.path}.new').exists(), isFalse);
        await file.writeAsBytes([0, 1, 2, 3]);
        await expectLater(store.load(), throwsA(anything));
        expect(await file.readAsBytes(), [0, 1, 2, 3]);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
