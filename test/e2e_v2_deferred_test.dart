import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2e_v2_core.dart';
import 'package:vocechat_client/services/e2e_v2_deferred.dart';

/// In-memory stand-in for the shared Rust core's deferred-envelope methods,
/// matching the finalized Task 3 contract shapes (see
/// `.superpowers/sdd/reports/task-3-report.md` §5/§12). Used until Task 9
/// rebuilds the native lib with the six `deferred_*` symbols — see
/// [NativeDeferredCryptoEngine].
class _FakeDeferredCryptoEngine implements DeferredCryptoEngine {
  final Map<String, Uint8List> _wrappedKeyByRecipient = {};
  bool tamperCiphertextOnDecrypt = false;

  /// Deterministic, order-independent 32-byte commitment over canonical
  /// metadata (sorted keys, matching the crate's BTreeMap serialization). Not
  /// a real SHA-256 — this is a test double; the real digest is the native
  /// core's concern. The only properties tests rely on are determinism,
  /// key-order independence, and collision-resistance across distinct inputs.
  static Uint8List _fold32(List<int> input) {
    final out = Uint8List(32);
    for (var i = 0; i < input.length; i++) {
      out[i % 32] = (out[i % 32] * 31 + input[i] + 7) & 0xff;
    }
    return out;
  }

  static Uint8List _canonical(Map<String, dynamic> metadata) {
    final sorted = <String, dynamic>{};
    final keys = metadata.keys.toList()..sort();
    for (final k in keys) {
      sorted[k] = metadata[k];
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(sorted)));
  }

  @override
  Uint8List metadataCommitment(Map<String, dynamic> metadata) =>
      _fold32(_canonical(metadata));

  @override
  bool verifyMetadata(Map<String, dynamic> metadata, Uint8List sha256) {
    final expected = metadataCommitment(metadata);
    if (expected.length != sha256.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ sha256[i];
    }
    return diff == 0;
  }

  @override
  DeferredEncryptResult encrypt({
    required Uint8List body,
    required Map<String, dynamic> metadata,
  }) {
    // sha256 = the metadata commitment, which also doubles as the AEAD AAD.
    final commitment = metadataCommitment(metadata);
    final key = _fold32(utf8.encode('key:${base64Encode(commitment)}'));
    final nonce = Uint8List.fromList(List.filled(12, 1));
    final ciphertext = Uint8List.fromList(
        List.generate(body.length, (i) => body[i] ^ key[i % key.length]));
    return DeferredEncryptResult(
      contentKey: key,
      nonce: nonce,
      ciphertext: ciphertext,
      sha256: commitment,
    );
  }

  @override
  Map<String, dynamic> wrapKey({
    required Uint8List contentKey,
    required Map<String, dynamic> recipientBundle,
  }) {
    final deviceId = _deviceIdOf(recipientBundle);
    _wrappedKeyByRecipient[deviceId] = contentKey;
    // Structured envelope shape from the Task 3 contract.
    return {
      'alg': 'DEFERRED+AES-GCM',
      'x3dh_initial': {'to': deviceId},
      'nonce_b64': base64Encode(List.filled(12, 2)),
      'wrapped_key_b64': base64Encode(contentKey),
    };
  }

  @override
  Uint8List unwrapKey({
    required Map<String, dynamic> envelope,
    required Map<String, dynamic> localIdentity,
  }) {
    final deviceId = envelope['x3dh_initial']['to'] as String;
    final key = _wrappedKeyByRecipient[deviceId];
    if (key == null) {
      throw StateError('no envelope for device $deviceId');
    }
    // Recipient identity must match the device the key was wrapped for.
    if (localIdentity['ik_secret_b64'] != 'ik:$deviceId') {
      throw StateError('envelope not addressed to this device');
    }
    return key;
  }

  @override
  Uint8List decrypt({
    required Uint8List ciphertext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List sha256,
  }) {
    if (tamperCiphertextOnDecrypt) {
      throw StateError('AEAD tag mismatch (tampered ciphertext)');
    }
    return Uint8List.fromList(List.generate(
        ciphertext.length, (i) => ciphertext[i] ^ key[i % key.length]));
  }

  static String _deviceIdOf(Map<String, dynamic> bundle) {
    final id = bundle['identity'];
    if (id is Map && id['device_id'] != null) return '${id['device_id']}';
    return '${bundle['device_id']}';
  }
}

Map<String, dynamic> _bundleFor(String deviceId) => {
      'identity': {'device_id': deviceId, 'identity_dh_pub_b64': 'x'},
      'signed_prekey': {'key_id': 1, 'dh_pub_b64': 'y', 'signature_b64': 'z'},
      'one_time_prekey_b64': null,
      'one_time_prekey_id': null,
    };

Map<String, dynamic> _localIdentityFor(String deviceId) => {
      'ik_secret_b64': 'ik:$deviceId',
      'spk_secret_b64': 'spk:$deviceId',
      'otk_secret_b64': null,
    };

void main() {
  group('E2eV2Deferred round trip (fake engine)', () {
    test('encrypt -> wrap -> verify+unwrap+decrypt recovers body', () {
      final fake = _FakeDeferredCryptoEngine();
      final deferred = E2eV2Deferred(engine: fake);

      final body = Uint8List.fromList(utf8.encode('hello deferred world'));
      final metadata = {'id': 'msg-1', 'mime': 'text/plain'};

      final pending = deferred.encryptPending(body: body, metadata: metadata);
      expect(
          pending.keys,
          containsAll([
            'content_key_b64',
            'nonce_b64',
            'ciphertext_b64',
            'sha256_b64'
          ]));

      final envelope = deferred.wrapKeyForRecipient(
        contentKeyB64: pending['content_key_b64']!,
        recipientBundle: _bundleFor('peer-device-1'),
      );

      final recovered = deferred.verifyUnwrapAndDecrypt(
        metadata: metadata,
        sha256B64: pending['sha256_b64']!,
        envelope: envelope,
        localIdentity: _localIdentityFor('peer-device-1'),
        ciphertextB64: pending['ciphertext_b64']!,
        nonceB64: pending['nonce_b64']!,
      );

      expect(utf8.decode(recovered), 'hello deferred world');
    });

    test('spoofed metadata is rejected even with a valid ciphertext/sha256',
        () {
      // CRITICAL 1 threat: a compromised transport rewrites the plaintext
      // metadata it relays. The recipient recomputes the commitment from the
      // metadata IT received and must reject the mismatch before trusting body.
      final fake = _FakeDeferredCryptoEngine();
      final deferred = E2eV2Deferred(engine: fake);
      final metadata = {'id': 'msg-1', 'mime': 'text/plain'};
      final pending = deferred.encryptPending(
        body: Uint8List.fromList(utf8.encode('secret')),
        metadata: metadata,
      );
      final envelope = deferred.wrapKeyForRecipient(
        contentKeyB64: pending['content_key_b64']!,
        recipientBundle: _bundleFor('device-a'),
      );

      final spoofed = {'id': 'msg-1', 'mime': 'text/markdown'};
      expect(
        () => deferred.verifyUnwrapAndDecrypt(
          metadata: spoofed,
          sha256B64: pending['sha256_b64']!,
          envelope: envelope,
          localIdentity: _localIdentityFor('device-a'),
          ciphertextB64: pending['ciphertext_b64']!,
          nonceB64: pending['nonce_b64']!,
        ),
        throwsStateError,
      );
    });

    test('verifyMetadata: true for matching, false for tampered', () {
      final fake = _FakeDeferredCryptoEngine();
      final deferred = E2eV2Deferred(engine: fake);
      final metadata = {'id': 'msg-9', 'mime': 'text/plain'};
      final pending = deferred.encryptPending(
        body: Uint8List.fromList(utf8.encode('x')),
        metadata: metadata,
      );
      expect(deferred.verifyMetadata(metadata, pending['sha256_b64']!), isTrue);
      expect(
        deferred.verifyMetadata(
            {'id': 'msg-9', 'mime': 'evil'}, pending['sha256_b64']!),
        isFalse,
      );
    });

    test('unwrap fails closed for the wrong recipient device', () {
      final fake = _FakeDeferredCryptoEngine();
      final deferred = E2eV2Deferred(engine: fake);
      final metadata = {'id': 'msg-2', 'mime': 'text/plain'};
      final pending = deferred.encryptPending(
        body: Uint8List.fromList(utf8.encode('secret')),
        metadata: metadata,
      );
      final envelope = deferred.wrapKeyForRecipient(
        contentKeyB64: pending['content_key_b64']!,
        recipientBundle: _bundleFor('device-a'),
      );

      expect(
        () => deferred.verifyUnwrapAndDecrypt(
          metadata: metadata,
          sha256B64: pending['sha256_b64']!,
          envelope: envelope,
          localIdentity: _localIdentityFor('device-b'),
          ciphertextB64: pending['ciphertext_b64']!,
          nonceB64: pending['nonce_b64']!,
        ),
        throwsStateError,
      );
    });

    test('tampered ciphertext throws instead of returning garbage plaintext',
        () {
      final fake = _FakeDeferredCryptoEngine()
        ..tamperCiphertextOnDecrypt = true;
      final deferred = E2eV2Deferred(engine: fake);
      final metadata = {'id': 'msg-3', 'mime': 'text/plain'};
      final pending = deferred.encryptPending(
        body: Uint8List.fromList(utf8.encode('secret')),
        metadata: metadata,
      );
      final envelope = deferred.wrapKeyForRecipient(
        contentKeyB64: pending['content_key_b64']!,
        recipientBundle: _bundleFor('device-a'),
      );

      expect(
        () => deferred.verifyUnwrapAndDecrypt(
          metadata: metadata,
          sha256B64: pending['sha256_b64']!,
          envelope: envelope,
          localIdentity: _localIdentityFor('device-a'),
          ciphertextB64: pending['ciphertext_b64']!,
          nonceB64: pending['nonce_b64']!,
        ),
        throwsStateError,
      );
    });

    test('different metadata (AAD) yields a different content key', () {
      final fake = _FakeDeferredCryptoEngine();
      final deferred = E2eV2Deferred(engine: fake);
      final body = Uint8List.fromList(utf8.encode('same body'));

      final a = deferred
          .encryptPending(body: body, metadata: {'id': 'a', 'mime': 'p'});
      final b = deferred
          .encryptPending(body: body, metadata: {'id': 'b', 'mime': 'p'});

      expect(a['content_key_b64'], isNot(b['content_key_b64']));
    });

    test('metadata key order does not change the commitment', () {
      final fake = _FakeDeferredCryptoEngine();
      final one = fake.metadataCommitment({'id': 'x', 'mime': 'p', 'kind': 1});
      final two = fake.metadataCommitment({'kind': 1, 'mime': 'p', 'id': 'x'});
      expect(one, two);
    });
  });

  group('NativeDeferredCryptoEngine (Task 9 FFI integration point)', () {
    test(
        'either fails closed (native lib absent) or succeeds end-to-end '
        '(native lib present, Task 9) — never silently degrades', () async {
      final core = E2eV2Core.instance;
      final loaded = await core.ensureLoaded();
      final engine = NativeDeferredCryptoEngine(core: core);
      if (!loaded) {
        // No native lib on this run's search path: every method must throw
        // (never silently succeed / fall back to plaintext).
        expect(
          () => engine.encrypt(body: Uint8List(0), metadata: const {'id': 'x'}),
          throwsStateError,
        );
        expect(
          () => engine.metadataCommitment(const {'id': 'x'}),
          throwsStateError,
        );
        return;
      }
      // Task 9: native lib is present (voce_e2ee_core rebuilt with the six
      // deferred_* symbols) — the real engine must now actually work, not
      // throw. The full round trip (encrypt/wrap/unwrap/decrypt + fail-closed
      // negative cases) against the real native lib is covered end-to-end by
      // test/e2e_v2_deferred_native_roundtrip_test.dart; here we just assert
      // this call site no longer throws "unknown method".
      final result =
          engine.encrypt(body: Uint8List(0), metadata: const {'id': 'x'});
      expect(result.contentKey.length, 32);
    });
  });
}
