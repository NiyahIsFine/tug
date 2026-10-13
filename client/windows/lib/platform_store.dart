import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tug_core/tug_core.dart';
import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

import 'settings.dart';

final class SecureSettingsStore implements SettingsStore {
  static const _uiForbidden = 1;
  SecureSettingsStore({String? directory})
    : directory = directory ?? '${Platform.environment['LOCALAPPDATA']}\\Tug';
  final String directory;
  File get _historyFile => File('$directory\\recent-messages.dpapi');
  File get _file => File('$directory\\settings.dpapi');

  @override
  Future<AppSettings?> load() async {
    final encoded = await _readEncrypted(_file, maxBytes: 1024 * 1024);
    return encoded == null ? null : AppSettings.decodeSecret(encoded);
  }

  @override
  Future<void> save(AppSettings settings) async {
    final bytes = utf8.encode(settings.encodeSecret());
    if (bytes.length > 1024 * 1024 - 4096) {
      throw const FormatException('Settings exceed the size limit.');
    }
    await _writeEncrypted(_file, bytes);
  }

  @override
  Future<List<ReceivedMessage>> loadHistory() async {
    final encoded = await _readEncrypted(
      _historyFile,
      maxBytes: TugReceiver.maxMessageBytes + 4096,
    );
    return encoded == null ? [] : RecentHistory.decode(encoded).messages;
  }

  @override
  Future<void> saveHistory(List<ReceivedMessage> messages) => _writeEncrypted(
    _historyFile,
    utf8.encode(RecentHistory(messages).encode()),
  );

  Future<String?> _readEncrypted(File file, {required int maxBytes}) async {
    if (!await file.exists()) return null;
    final size = await file.length();
    if (size == 0 || size > maxBytes) {
      throw const FormatException('Invalid encrypted record size.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Invalid encrypted record size.');
    }
    return utf8.decode(_crypt(bytes, protect: false));
  }

  Future<void> _writeEncrypted(File file, List<int> bytes) async {
    final encrypted = _crypt(Uint8List.fromList(bytes), protect: true);
    await Directory(directory).create(recursive: true);
    final temporary = File('${file.path}.new');
    try {
      await temporary.writeAsBytes(encrypted, flush: true);
      using((arena) {
        final result = MoveFileEx(
          arena.pcwstr(temporary.path),
          arena.pcwstr(file.path),
          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        );
        if (!result.value) {
          throw const FileSystemException(
            'Could not atomically replace the encrypted record.',
          );
        }
      });
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Uint8List _crypt(Uint8List input, {required bool protect}) => using((arena) {
    final buffer = arena<Uint8>(input.length);
    buffer.asTypedList(input.length).setAll(0, input);
    final source = arena<CRYPT_INTEGER_BLOB>();
    source.ref.cbData = input.length;
    source.ref.pbData = buffer;
    final target = arena<CRYPT_INTEGER_BLOB>();
    try {
      final result = protect
          ? CryptProtectData(source, null, null, null, _uiForbidden, target)
          : CryptUnprotectData(source, null, null, null, _uiForbidden, target);
      if (!result.value) {
        throw const FileSystemException(
          'Windows secure storage operation failed.',
        );
      }
      return Uint8List.fromList(
        target.ref.pbData.asTypedList(target.ref.cbData),
      );
    } finally {
      buffer.asTypedList(input.length).fillRange(0, input.length, 0);
      if (target.ref.pbData.address != 0) {
        target.ref.pbData
            .asTypedList(target.ref.cbData)
            .fillRange(0, target.ref.cbData, 0);
        LocalFree(HLOCAL(target.ref.pbData.cast()));
      }
    }
  });
}

final class WindowsStartupRegistration implements StartupRegistration {
  static const name = 'Tug';
  static const runPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const approvedPath =
      r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  WindowsStartupRegistration({String? executable})
    : executable = executable ?? Platform.resolvedExecutable;
  final String executable;
  String get command => '"$executable" --background';

  @override
  Future<StartupState> read() async {
    final run = CURRENT_USER.create(runPath);
    try {
      final value = run.getValue(name);
      if (value == null) {
        return const StartupState(enabled: false, registered: false);
      }
      if (value is! StringValue || value.value != command) {
        return const StartupState(
          enabled: false,
          registered: true,
          diagnostic:
              'App location changed. Turn startup off and on to update it.',
        );
      }
      try {
        final approved = CURRENT_USER.open(approvedPath);
        try {
          final approval = approved.getValue(name);
          if (approval is BinaryValue &&
              approval.value.isNotEmpty &&
              approval.value.first.isOdd) {
            return const StartupState(
              enabled: false,
              registered: true,
              diagnostic:
                  'Windows disabled startup. Enable Tug in Task Manager.',
            );
          }
        } finally {
          approved.close();
        }
      } on WindowsException catch (error) {
        if (error.hr != ERROR_FILE_NOT_FOUND.toHRESULT()) rethrow;
      }
      return const StartupState(enabled: true, registered: true);
    } finally {
      run.close();
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    final run = CURRENT_USER.create(runPath);
    try {
      if (enabled) {
        run.setValue(name, RegistryValue.string(command));
      } else if (run.getValue(name) != null) {
        run.removeValue(name);
      }
    } finally {
      run.close();
    }
  }
}
