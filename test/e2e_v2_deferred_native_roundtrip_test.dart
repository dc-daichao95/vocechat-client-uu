// Task 9 real-engine evidence test.
//
// Unlike test/e2e_v2_deferred_test.dart (which deliberately uses a fake
// DeferredCryptoEngine and asserts the native path fails closed until the
// native lib exists), this test exercises the REAL production
// `NativeDeferredCryptoEngine` against the actual compiled
// `voce_e2ee_core` native library, through the exact same `E2eV2Core.call`
// JSON-RPC bridge production code uses. It is skipped (not failed) if the
// native library cannot be located/loaded in the current environment, so it
// is safe to leave in the suite permanently: it becomes a real regression
// gate on any machine/CI that has the native lib available, and a no-op
// elsewhere.
//
// Run with: flutter test test/e2e_v2_deferred_native_roundtrip_test.dart
// (`flutter test` runs on the `flutter_tester` engine binary, so
// `Platform.resolvedExecutable` is `flutter_tester.exe`/`flutter_tester`; the
// Task 9 native build places `voce_e2ee_core.dll`/`libvoce_e2ee_core.so` next
// to it, or `flutter_tester` finds `libvoce_e2ee_core.so` via the process's
// own symbol table on Linux/Android, per E2eV2Core's existing lookup rules).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2e_v2_core.dart';
import 'package:vocechat_client/services/e2e_v2_deferred.dart';

Future<void> main() async {
  final core = E2eV2Core.instance;
  final loaded = await core.ensureLoaded();
  if (!loaded) {
    // Environment doesn't have the native lib on this run's search path.
    // Not a failure of this test file; Task 9 report documents exactly
    // where the native lib must live per platform.
    test('SKIP: native voce_e2ee_core lib not loaded', () {
      // ignore: avoid_print
      print('SKIP reason: ${core.loadError}');
    }, skip: 'native voce_e2ee_core lib not loaded: ${core.loadError}');
    return;
  }

  test('real NativeDeferredCryptoEngine round trip against the native lib', () {
    _runRealEngineChecks(core);
  });
}

void _runRealEngineChecks(E2eV2Core core) {
  final engine = NativeDeferredCryptoEngine(core: core);
  final deferred = E2eV2Deferred(engine: engine);

  int passed = 0;
  void check(String name, void Function() fn) {
    fn();
    passed++;
    // ignore: avoid_print
    print('  ok - $name');
  }

  // version() must report the real crate version through the real bridge.
  check('version reports 0.1.0 via real native call', () {
    final v = core.call('version', {});
    if (v['result'] != '0.1.0') {
      throw StateError('unexpected version result: $v');
    }
  });

  // Build a real recipient identity + signed prekey via the same native lib.
  final identity = core.call('generate_identity', {});
  final identityResult = Map<String, dynamic>.from(identity['result'] as Map);
  final spk = core.call('generate_signed_prekey', {
    'secret_x25519_b64': identityResult['secret_x25519_b64'],
    'secret_ed25519_b64': identityResult['secret_ed25519_b64'],
    'key_id': 1,
  });
  final spkResult = Map<String, dynamic>.from(spk['result'] as Map);

  final recipientBundle = <String, dynamic>{
    'identity': identityResult['public'],
    'signed_prekey': spkResult['public'],
    'one_time_prekey_b64': null,
    'one_time_prekey_id': null,
  };
  final localIdentity = <String, dynamic>{
    'ik_secret_b64': identityResult['secret_x25519_b64'],
    'spk_secret_b64': spkResult['secret_b64'],
    'otk_secret_b64': null,
  };

  final body = Uint8List.fromList(
      utf8.encode('Task 9 Flutter <-> real native engine round trip'));
  final metadata = {'id': 'flutter-native-roundtrip-1', 'mime': 'text/plain'};

  final pending = deferred.encryptPending(body: body, metadata: metadata);
  check('encryptPending returns all 4 fields', () {
    for (final f in [
      'content_key_b64',
      'nonce_b64',
      'ciphertext_b64',
      'sha256_b64'
    ]) {
      if (!pending.containsKey(f)) throw StateError('missing $f');
    }
  });

  final envelope = deferred.wrapKeyForRecipient(
    contentKeyB64: pending['content_key_b64']!,
    recipientBundle: recipientBundle,
  );
  check('wrapKeyForRecipient returns a structured envelope', () {
    if (envelope['wrapped_key_b64'] == null) {
      throw StateError('missing wrapped_key_b64 in $envelope');
    }
  });

  final recovered = deferred.verifyUnwrapAndDecrypt(
    metadata: metadata,
    sha256B64: pending['sha256_b64']!,
    envelope: envelope,
    localIdentity: localIdentity,
    ciphertextB64: pending['ciphertext_b64']!,
    nonceB64: pending['nonce_b64']!,
  );
  check('verifyUnwrapAndDecrypt recovers the original plaintext', () {
    if (utf8.decode(recovered) !=
        'Task 9 Flutter <-> real native engine round trip') {
      throw StateError('plaintext mismatch: ${utf8.decode(recovered)}');
    }
  });

  // Fail-closed: tampered metadata must be rejected before decrypt.
  check('tampered metadata is rejected (fail-closed)', () {
    var threw = false;
    try {
      deferred.verifyUnwrapAndDecrypt(
        metadata: {'id': 'flutter-native-roundtrip-1', 'mime': 'text/evil'},
        sha256B64: pending['sha256_b64']!,
        envelope: envelope,
        localIdentity: localIdentity,
        ciphertextB64: pending['ciphertext_b64']!,
        nonceB64: pending['nonce_b64']!,
      );
    } on StateError {
      threw = true;
    }
    if (!threw) throw StateError('expected StateError for tampered metadata');
  });

  // Fail-closed: wrong recipient cannot unwrap.
  final otherIdentity = Map<String, dynamic>.from(
      core.call('generate_identity', {})['result'] as Map);
  final otherSpk = core.call('generate_signed_prekey', {
    'secret_x25519_b64': otherIdentity['secret_x25519_b64'],
    'secret_ed25519_b64': otherIdentity['secret_ed25519_b64'],
    'key_id': 1,
  });
  final otherSpkResult = Map<String, dynamic>.from(otherSpk['result'] as Map);
  check('wrong recipient device fails to unwrap (fail-closed)', () {
    var threw = false;
    try {
      engine.unwrapKey(envelope: envelope, localIdentity: {
        'ik_secret_b64': otherIdentity['secret_x25519_b64'],
        'spk_secret_b64': otherSpkResult['secret_b64'],
        'otk_secret_b64': null,
      });
    } catch (_) {
      threw = true;
    }
    if (!threw) throw StateError('expected failure for wrong recipient');
  });

  // ignore: avoid_print
  print('\n$passed checks passed against REAL native voce_e2ee_core.dll.');
}
