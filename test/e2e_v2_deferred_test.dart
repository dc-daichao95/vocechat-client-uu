import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2e_v2_core.dart';
import 'package:vocechat_client/services/e2e_v2_deferred.dart';

/// In-memory stand-in for the shared Rust core's deferred-envelope methods.
/// Used until shared-core Task 3 lands `deferred_encrypt`/`deferred_wrap_key`/
/// `deferred_unwrap_key`/`deferred_decrypt` natively (see
/// [NativeDeferredCryptoEngine] doc comment for the exact Task 9 wiring
/// point this fake stands in for).
class _FakeDeferredCryptoEngine implements DeferredCryptoEngine {
  final Map<String, Uint8List> _wrappedKeyByRecipient = {};
  bool tamperCiphertextOnDecrypt = false;

  @override
  DeferredEncryptResult encrypt({
    required Uint8List body,
    required Uint8List metadata,
  }) {
    // Fake "content key" derived deterministically from metadata so tests
    // can assert AAD binding without real AES-GCM.
    final key = Uint8List.fromList(
        utf8.encode('key:${base64Encode(metadata)}').take(32).toList()
          ..addAll(List.filled(32, 7)));
    final nonce = Uint8List.fromList(List.filled(12, 1));
    // "Ciphertext" = body XOR key (repeating) + metadata length tag, just
    // enough to exercise tamper detection deterministically.
    final ciphertext = Uint8List.fromList(
        List.generate(body.length, (i) => body[i] ^ key[i % key.length]));
    final sha256 = Uint8List.fromList(utf8
        .encode('sha:${ciphertext.length}:${metadata.length}')
        .take(32)
        .toList());
    return DeferredEncryptResult(
      contentKey: key.sublist(0, 32),
      nonce: nonce,
      ciphertext: ciphertext,
      sha256: sha256,
    );
  }

  @override
  Uint8List wrapKey({
    required Uint8List contentKey,
    required Map<String, dynamic> recipientBundle,
  }) {
    final deviceId = recipientBundle['device_id'] as String;
    _wrappedKeyByRecipient[deviceId] = contentKey;
    // Envelope is just an opaque marker carrying the recipient device id;
    // real core would produce an X3DH/DR-wrapped ciphertext.
    return Uint8List.fromList(utf8.encode('envelope:$deviceId'));
  }

  @override
  Uint8List unwrapKey({
    required Uint8List envelope,
    required Map<String, dynamic> localIdentity,
  }) {
    final marker = utf8.decode(envelope);
    final deviceId = marker.split(':').last;
    final key = _wrappedKeyByRecipient[deviceId];
    if (key == null) {
      throw StateError('no envelope for device $deviceId');
    }
    if (localIdentity['device_id'] != deviceId) {
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
}

void main() {
  group('E2eV2Deferred round trip (fake engine)', () {
    test(
        'encryptPending -> wrapKeyForRecipient -> unwrapAndDecrypt recovers body',
        () {
      final fake = _FakeDeferredCryptoEngine();
      final deferred = E2eV2Deferred(engine: fake);

      final body = Uint8List.fromList(utf8.encode('hello deferred world'));
      final metadata = Uint8List.fromList(utf8.encode('text/plain'));

      final pending = deferred.encryptPending(body: body, metadata: metadata);
      expect(
          pending.keys,
          containsAll([
            'content_key_b64',
            'nonce_b64',
            'ciphertext_b64',
            'sha256_b64'
          ]));

      final envelopeB64 = deferred.wrapKeyForRecipient(
        contentKeyB64: pending['content_key_b64']!,
        recipientBundle: {'device_id': 'peer-device-1'},
      );

      final recovered = deferred.unwrapAndDecrypt(
        envelopeB64: envelopeB64,
        localIdentity: {'device_id': 'peer-device-1'},
        ciphertextB64: pending['ciphertext_b64']!,
        nonceB64: pending['nonce_b64']!,
        sha256B64: pending['sha256_b64']!,
      );

      expect(utf8.decode(recovered), 'hello deferred world');
    });

    test(
        'unwrap fails closed for the wrong recipient device (no plaintext fallback)',
        () {
      final fake = _FakeDeferredCryptoEngine();
      final deferred = E2eV2Deferred(engine: fake);
      final pending = deferred.encryptPending(
        body: Uint8List.fromList(utf8.encode('secret')),
        metadata: Uint8List.fromList(utf8.encode('text/plain')),
      );
      final envelopeB64 = deferred.wrapKeyForRecipient(
        contentKeyB64: pending['content_key_b64']!,
        recipientBundle: {'device_id': 'device-a'},
      );

      expect(
        () => deferred.unwrapAndDecrypt(
          envelopeB64: envelopeB64,
          localIdentity: {'device_id': 'device-b'},
          ciphertextB64: pending['ciphertext_b64']!,
          nonceB64: pending['nonce_b64']!,
          sha256B64: pending['sha256_b64']!,
        ),
        throwsStateError,
      );
    });

    test('tampered ciphertext throws instead of returning garbage plaintext',
        () {
      final fake = _FakeDeferredCryptoEngine()
        ..tamperCiphertextOnDecrypt = true;
      final deferred = E2eV2Deferred(engine: fake);
      final pending = deferred.encryptPending(
        body: Uint8List.fromList(utf8.encode('secret')),
        metadata: Uint8List.fromList(utf8.encode('text/plain')),
      );
      final envelopeB64 = deferred.wrapKeyForRecipient(
        contentKeyB64: pending['content_key_b64']!,
        recipientBundle: {'device_id': 'device-a'},
      );

      expect(
        () => deferred.unwrapAndDecrypt(
          envelopeB64: envelopeB64,
          localIdentity: {'device_id': 'device-a'},
          ciphertextB64: pending['ciphertext_b64']!,
          nonceB64: pending['nonce_b64']!,
          sha256B64: pending['sha256_b64']!,
        ),
        throwsStateError,
      );
    });

    test('different metadata (AAD) yields a different content key', () {
      final fake = _FakeDeferredCryptoEngine();
      final deferred = E2eV2Deferred(engine: fake);
      final body = Uint8List.fromList(utf8.encode('same body'));

      final a = deferred.encryptPending(
          body: body, metadata: Uint8List.fromList(utf8.encode('text/plain')));
      final b = deferred.encryptPending(
          body: body,
          metadata: Uint8List.fromList(utf8.encode('text/markdown')));

      expect(a['content_key_b64'], isNot(b['content_key_b64']));
    });
  });

  group('NativeDeferredCryptoEngine (Task 9 FFI integration point)', () {
    test(
        'surfaces a clear error until shared-core Task 3/9 exports deferred_* natively',
        () async {
      final core = E2eV2Core.instance;
      // On this CI/dev machine the native lib may or may not be present;
      // either way, calling the not-yet-implemented method must not silently
      // succeed or fall back to plaintext.
      final loaded = await core.ensureLoaded();
      final engine = NativeDeferredCryptoEngine(core: core);
      if (!loaded) {
        expect(
          () => engine.encrypt(body: Uint8List(0), metadata: Uint8List(0)),
          throwsStateError,
        );
        return;
      }
      expect(
        () => engine.encrypt(body: Uint8List(0), metadata: Uint8List(0)),
        throwsStateError,
      );
    });
  });
}
