import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _CallDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// Thin cross-platform FFI bridge to the shared Rust crypto core.
class E2eV2Core {
  E2eV2Core._();
  static final E2eV2Core instance = E2eV2Core._();

  DynamicLibrary? _lib;
  _CallDart? _call;
  _FreeDart? _free;
  String? _loadError;

  bool get isAvailable => _call != null;

  String? get loadError => _loadError;

  Future<bool> ensureLoaded() async {
    if (_call != null) return true;
    if (kIsWeb) {
      _loadError = 'E2E v2 FFI not available on web';
      return false;
    }
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        _lib = DynamicLibrary.process();
      } else if (Platform.isAndroid) {
        _lib = DynamicLibrary.open('libvoce_e2ee_core.so');
      } else if (Platform.isLinux) {
        _lib = DynamicLibrary.open('libvoce_e2ee_core.so');
      } else if (Platform.isWindows) {
        final dll = _resolveWindowsDll();
        if (dll == null) {
          _loadError = 'voce_e2ee_core.dll not found';
          return false;
        }
        _lib = DynamicLibrary.open(dll);
      } else {
        _loadError = 'The MLS core does not support this platform';
        return false;
      }
      _call = _lib!.lookupFunction<_CallNative, _CallDart>('voce_e2ee_call');
      _free = _lib!.lookupFunction<_FreeNative, _FreeDart>('voce_e2ee_free');
      return true;
    } catch (e) {
      _loadError = e.toString();
      return false;
    }
  }

  String? _resolveWindowsDll() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir${Platform.pathSeparator}voce_e2ee_core.dll',
      '$exeDir${Platform.pathSeparator}libs${Platform.pathSeparator}voce_e2ee_core.dll',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  Map<String, dynamic> call(String method, [Map<String, dynamic>? args]) {
    final fn = _call;
    final free = _free;
    if (fn == null || free == null) {
      throw StateError(_loadError ?? 'E2eV2Core not loaded');
    }
    final methodPtr = method.toNativeUtf8();
    final argsPtr = jsonEncode(args ?? {}).toNativeUtf8();
    try {
      final outPtr = fn(methodPtr, argsPtr);
      if (outPtr == nullptr) {
        throw StateError('voce_e2ee_call returned null');
      }
      try {
        final raw = outPtr.toDartString();
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        if (decoded['ok'] != true) {
          throw StateError('E2E v2 error: ${decoded['error']}');
        }
        return decoded;
      } finally {
        free(outPtr);
      }
    } finally {
      malloc.free(methodPtr);
      malloc.free(argsPtr);
    }
  }

  String version() {
    final r = call('version');
    return '${r['result']}';
  }

  /// Returns secret + public identity material from the Rust core.
  Map<String, dynamic> generateIdentity() {
    final r = call('generate_identity');
    return Map<String, dynamic>.from(r['result'] as Map);
  }

  Map<String, dynamic> generateSignedPrekey({
    required String secretX25519B64,
    required String secretEd25519B64,
    int keyId = 1,
  }) {
    final r = call('generate_signed_prekey', {
      'secret_x25519_b64': secretX25519B64,
      'secret_ed25519_b64': secretEd25519B64,
      'key_id': keyId,
    });
    return Map<String, dynamic>.from(r['result'] as Map);
  }
}
