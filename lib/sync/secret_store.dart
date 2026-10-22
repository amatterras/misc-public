// Stores small secrets (device tokens, the hub's admin token) encrypted with
// Windows DPAPI, which ties them to the current Windows user account: a
// copied file is useless on another account or machine. Pure Dart (dart:ffi).
// ignore_for_file: non_constant_identifier_names

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Secure storage provided by the operating system (the iOS Keychain).
/// Kept as an interface so this file stays plain Dart for the hub.
abstract interface class KeychainBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Set by the app at start-up on iPhone/iPad. When set, secrets go to the
/// Keychain and the file only records where (it never holds the secret).
KeychainBackend? secretKeychain;

/// Keychain entry name for [file], e.g. `THEapp.hub.token`.
String _keychainKey(File file) => 'THEapp.${file.uri.pathSegments.last}';

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptC = Int32 Function(
  Pointer<_Blob>,
  Pointer<Utf16>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _CryptDart = int Function(
  Pointer<_Blob>,
  Pointer<Utf16>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);
typedef _UnprotectC = Int32 Function(
  Pointer<_Blob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _UnprotectDart = int Function(
  Pointer<_Blob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);

const _uiForbidden = 0x1;

Uint8List? _dpapi(Uint8List input, {required bool protect}) {
  final crypt32 = DynamicLibrary.open('crypt32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final localFree = kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('LocalFree');
  final inBlob = calloc<_Blob>();
  final outBlob = calloc<_Blob>();
  final buffer = calloc<Uint8>(input.isEmpty ? 1 : input.length);
  try {
    buffer.asTypedList(input.length).setAll(0, input);
    inBlob.ref
      ..cbData = input.length
      ..pbData = buffer;
    final int ok;
    if (protect) {
      final fn = crypt32.lookupFunction<_CryptC, _CryptDart>(
        'CryptProtectData',
      );
      ok = fn(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
    } else {
      final fn = crypt32.lookupFunction<_UnprotectC, _UnprotectDart>(
        'CryptUnprotectData',
      );
      ok = fn(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _uiForbidden,
        outBlob,
      );
    }
    if (ok == 0) return null;
    final result = Uint8List.fromList(
      outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
    );
    localFree(outBlob.ref.pbData.cast());
    return result;
  } finally {
    calloc
      ..free(buffer)
      ..free(inBlob)
      ..free(outBlob);
  }
}

/// Writes [secret] to [file], encrypted for this Windows user. On other
/// platforms the file is written as-is (the iOS client will use the
/// Keychain instead).
Future<void> writeSecret(File file, String secret) async {
  final bytes = Uint8List.fromList(utf8.encode(secret));
  final Map<String, String> json;
  final keychain = secretKeychain;
  if (keychain != null) {
    final key = _keychainKey(file);
    await keychain.write(key, secret);
    json = {'keychain': key};
  } else if (Platform.isWindows) {
    final protected = _dpapi(bytes, protect: true);
    if (protected == null) {
      throw const FileSystemException('Could not encrypt secret');
    }
    json = {'dpapi': base64Encode(protected)};
  } else {
    json = {'plain': secret};
  }
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(json), flush: true);
  if (Platform.isLinux || Platform.isMacOS) {
    // No DPAPI here (e.g. a mirror on a Raspberry Pi): readable by this user
    // only, set before the file gets its real name.
    final r = await Process.run('chmod', ['600', tmp.path]);
    if (r.exitCode != 0) {
      await tmp.delete();
      throw FileSystemException('Could not protect secret file', file.path);
    }
  }
  await tmp.rename(file.path);
}

/// Removes a secret written by [writeSecret] (file and Keychain entry).
Future<void> deleteSecret(File file) async {
  if (secretKeychain != null) {
    try {
      await secretKeychain!.delete(_keychainKey(file));
    } catch (_) {}
  }
  if (await file.exists()) await file.delete();
}

/// Reads a secret written by [writeSecret]; null if missing or unreadable.
Future<String?> readSecret(File file) async {
  try {
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['keychain'] is String) {
      return await secretKeychain?.read(json['keychain'] as String);
    }
    if (json['dpapi'] is String) {
      if (!Platform.isWindows) return null;
      final plain = _dpapi(
        base64Decode(json['dpapi'] as String),
        protect: false,
      );
      return plain == null ? null : utf8.decode(plain);
    }
    return json['plain'] as String?;
  } catch (_) {
    return null;
  }
}
