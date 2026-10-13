import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tug_android/platform_store.dart';
import 'package:tug_android/settings.dart';
import 'package:tug_core/tug_core.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const intentChannel = MethodChannel('dev.tug/receive_intent');
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(intentChannel, null);
    messenger.setMockMethodCallHandler(secureChannel, null);
  });

  test('recent messages use their own encrypted key without token or native preferences', () async {
    String? stored;
    messenger.setMockMethodCallHandler(
      intentChannel,
      (call) async => fail('history must not use plain preferences'),
    );
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      expect(call.arguments['key'], 'recent_messages_v1');
      expect(call.arguments['options']['resetOnError'], 'false');
      if (call.method == 'write') stored = call.arguments['value'] as String;
      if (call.method == 'read') return stored;
      return null;
    });
    final store = PlatformStore();
    expect(await store.readHistory(), isEmpty);
    final received = (parseServerFrame(message(1)) as MessageFrame).message;
    await store.saveHistory([received]);
    expect((await store.readHistory()).single.toData(), received.toData());
    expect(jsonDecode(stored!).keys, unorderedEquals(['version', 'messages']));
    expect(stored, isNot(contains('token')));
  });

  test('invalid or inaccessible encrypted history propagates without silently clearing it', () async {
    int writes = 0;
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method == 'write') ++writes;
      return '{invalid';
    });
    await expectLater(PlatformStore().readHistory(), throwsFormatException);
    expect(writes, 0);
    messenger.setMockMethodCallHandler(
      secureChannel,
      (call) async => throw PlatformException(code: 'locked'),
    );
    await expectLater(
      PlatformStore().readHistory(),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      PlatformStore().saveHistory([]),
      throwsA(isA<PlatformException>()),
    );
  });

  test('first-open prompt claim is persisted without credentials or receive intent', () async {
    bool handled = false;
    messenger.setMockMethodCallHandler(
      secureChannel,
      (call) async => fail('no credentials'),
    );
    messenger.setMockMethodCallHandler(intentChannel, (call) async {
      expect(call.method, 'claim_notification_prompt');
      expect(call.arguments, isNull);
      final first = !handled;
      handled = true;
      return first;
    });
    final store = PlatformStore();
    expect(await store.claimNotificationPrompt(), true);
    expect(await store.claimNotificationPrompt(), false);
  });

  test(
    'background query preserves restricted, unrestricted and unknown values',
    () async {
      bool? value;
      messenger.setMockMethodCallHandler(intentChannel, (call) async {
        expect(call.method, 'background_restricted');
        return value;
      });
      final store = PlatformStore();
      expect(await store.readBackgroundRestricted(), isNull);
      value = true;
      expect(await store.readBackgroundRestricted(), true);
      value = false;
      expect(await store.readBackgroundRestricted(), false);
    },
  );

  test('foreground resume sends only the expected intent revision', () async {
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      fail('foreground resume must not access credentials');
    });
    messenger.setMockMethodCallHandler(intentChannel, (call) async {
      expect(call.method, 'resume_foreground');
      expect(call.arguments, {'expected_revision': 7});
      return null;
    });
    await PlatformStore().allowForegroundResume(expectedRevision: 7);
  });

  test(
    'foreground resume maps intent conflicts and propagates storage failure',
    () async {
      messenger.setMockMethodCallHandler(intentChannel, (call) async {
        throw PlatformException(code: 'conflict');
      });
      await expectLater(
        PlatformStore().allowForegroundResume(expectedRevision: 7),
        throwsA(isA<IntentConflict>()),
      );
      messenger.setMockMethodCallHandler(intentChannel, (call) async {
        throw PlatformException(code: 'storage');
      });
      await expectLater(
        PlatformStore().allowForegroundResume(expectedRevision: 7),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'recovery diagnostics are read and bounded native error is recorded',
    () async {
      messenger.setMockMethodCallHandler(intentChannel, (call) async {
        if (call.method == 'read_preferences') {
          return {
            'recovery_error': 'Background service blocked by the system.',
          };
        }
        expect(call.method, 'recovery_error');
        expect(call.arguments, {'error': 'Cannot load secure settings.'});
        return null;
      });
      final store = PlatformStore();
      expect(
        (await store.readPreferences()).recoveryError,
        'Background service blocked by the system.',
      );
      await store.recordRecoveryError('Cannot load secure settings.');
    },
  );

  test('preference commit and read failures propagate to the page', () async {
    messenger.setMockMethodCallHandler(intentChannel, (call) async {
      throw PlatformException(code: 'storage');
    });
    final store = PlatformStore();
    await expectLater(
      store.readPreferences(),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      store.claimNotificationPrompt(),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'intent is versioned and stale starts fail rather than overwriting a stop',
    () async {
      messenger.setMockMethodCallHandler(intentChannel, (call) async {
        if (call.method == 'read') return {'enabled': false, 'revision': 3};
        expect(call.arguments['expected_revision'], 2);
        throw PlatformException(code: 'conflict');
      });
      final store = PlatformStore();
      expect((await store.readIntent()).enabled, false);
      await expectLater(
        store.setReceiving(true, expectedRevision: 2),
        throwsA(isA<IntentConflict>()),
      );
    },
  );

  test('configuration token uses encrypted plugin storage, never intent preferences', () async {
    String? stored;
    messenger.setMockMethodCallHandler(intentChannel, (call) async {
      fail('configuration must not enter intent channel');
    });
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method == 'write') {
        stored = call.arguments['value'] as String;
        expect(call.arguments['options']['resetOnError'], 'false');
      }
      if (call.method == 'read') return stored;
      return null;
    });
    final store = PlatformStore();
    await store.saveConfiguration(
      ReceiverConfig('https://example.com', 'secret-token'),
    );
    expect((await store.readConfiguration())!.receiveToken, 'secret-token');
    expect(jsonDecode(stored!)['server'], 'https://example.com/');
  });

  test(
    'secure store failures propagate instead of clearing credentials silently',
    () async {
      messenger.setMockMethodCallHandler(secureChannel, (call) async {
        throw PlatformException(code: 'locked');
      });
      await expectLater(
        PlatformStore().readConfiguration(),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
