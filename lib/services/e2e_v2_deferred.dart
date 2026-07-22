import 'dart:convert';
import 'dart:typed_data';

import 'package:vocechat_client/services/e2e_v2_core.dart';

/// Result of a deferred content encryption (before any recipient key exists).
///
/// Field names match the shared-core Task 3 contract exactly:
/// `deferred_encrypt(body, metadata) -> {content_key, nonce, ciphertext, sha256}`.
class DeferredEncryptResult {
  final Uint8List contentKey;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List sha256;

  const DeferredEncryptResult({
    required this.contentKey,
    required this.nonce,
    required this.ciphertext,
    required this.sha256,
  });
}

/// Dart binding contract for the shared Rust crypto core's deferred-envelope
/// primitives (`deferred_encrypt` / `deferred_wrap_key` / `deferred_unwrap_key`
/// / `deferred_decrypt`), as specified for shared core Task 3 and consumed by
/// Web Task 5 and this Flutter Task 7.
///
/// All byte arrays cross the FFI boundary as base64 (per contract); this
/// interface deals in raw bytes so callers never touch base64 directly.
abstract class DeferredCryptoEngine {
  /// AES-256-GCM content encryption. [metadata] is bound as AAD so tampering
  /// with either ciphertext or metadata fails decryption.
  DeferredEncryptResult encrypt({
    required Uint8List body,
    required Uint8List metadata,
  });

  /// Wraps [contentKey] for a specific recipient device using X3DH/DR
  /// primitives already present in the shared core. Returns an opaque
  /// envelope (server wire class `dr_envelope`).
  Uint8List wrapKey({
    required Uint8List contentKey,
    required Map<String, dynamic> recipientBundle,
  });

  /// Unwraps an envelope produced by [wrapKey] using the local device's
  /// identity material, recovering the original content key.
  Uint8List unwrapKey({
    required Uint8List envelope,
    required Map<String, dynamic> localIdentity,
  });

  /// AES-256-GCM content decryption. Must fail closed (throw) if [sha256]
  /// does not match the decrypted body or the AEAD tag check fails.
  Uint8List decrypt({
    required Uint8List ciphertext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List sha256,
  });
}

/// FFI-backed [DeferredCryptoEngine].
///
/// *** Task 9 integration point ***
/// This calls `E2eV2Core.instance.call('deferred_encrypt'|'deferred_wrap_key'
/// |'deferred_unwrap_key'|'deferred_decrypt', {...})`, i.e. the same
/// `voce_e2ee_call` JSON-RPC bridge already used by every other FFI method in
/// this file (see [E2eV2Core.call]). As of this task, the native
/// `libvoce_e2ee_core` build linked into this repo does not yet export those
/// four methods (shared-core Task 3 adds them). Calling any method here will
/// throw a [StateError] with message `E2E v2 error: unknown method ...`
/// (surfaced by [E2eV2Core.call]) until Task 3/9 lands the native symbols —
/// no other Dart-side change should be required at that point. This class
/// (and its four call sites below) is exactly what Task 9 must exercise
/// end-to-end once the native library is rebuilt.
class NativeDeferredCryptoEngine implements DeferredCryptoEngine {
  final E2eV2Core _core;

  NativeDeferredCryptoEngine({E2eV2Core? core})
      : _core = core ?? E2eV2Core.instance;

  @override
  DeferredEncryptResult encrypt({
    required Uint8List body,
    required Uint8List metadata,
  }) {
    final r = _core.call('deferred_encrypt', {
      'body_b64': base64Encode(body),
      'metadata_b64': base64Encode(metadata),
    });
    final result = Map<String, dynamic>.from(r['result'] as Map);
    return DeferredEncryptResult(
      contentKey: base64Decode(result['content_key_b64'] as String),
      nonce: base64Decode(result['nonce_b64'] as String),
      ciphertext: base64Decode(result['ciphertext_b64'] as String),
      sha256: base64Decode(result['sha256_b64'] as String),
    );
  }

  @override
  Uint8List wrapKey({
    required Uint8List contentKey,
    required Map<String, dynamic> recipientBundle,
  }) {
    final r = _core.call('deferred_wrap_key', {
      'content_key_b64': base64Encode(contentKey),
      'recipient_bundle': recipientBundle,
    });
    final result = Map<String, dynamic>.from(r['result'] as Map);
    return base64Decode(result['envelope_b64'] as String);
  }

  @override
  Uint8List unwrapKey({
    required Uint8List envelope,
    required Map<String, dynamic> localIdentity,
  }) {
    final r = _core.call('deferred_unwrap_key', {
      'envelope_b64': base64Encode(envelope),
      'local_identity': localIdentity,
    });
    final result = Map<String, dynamic>.from(r['result'] as Map);
    return base64Decode(result['content_key_b64'] as String);
  }

  @override
  Uint8List decrypt({
    required Uint8List ciphertext,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List sha256,
  }) {
    final r = _core.call('deferred_decrypt', {
      'ciphertext_b64': base64Encode(ciphertext),
      'key_b64': base64Encode(key),
      'nonce_b64': base64Encode(nonce),
      'sha256_b64': base64Encode(sha256),
    });
    final result = Map<String, dynamic>.from(r['result'] as Map);
    return base64Decode(result['body_b64'] as String);
  }
}

/// High-level deferred-DM crypto orchestration used by
/// `voce_send_service.dart` / `e2e_v2_dm.dart` for the `dr-pending` send
/// path and its later recipient-envelope completion.
///
/// The [engine] is injectable so this can be unit-tested without a native
/// library (see test/e2e_v2_deferred_test.dart's fake engine); production
/// code defaults to [NativeDeferredCryptoEngine].
class E2eV2Deferred {
  final DeferredCryptoEngine engine;

  E2eV2Deferred({DeferredCryptoEngine? engine})
      : engine = engine ?? NativeDeferredCryptoEngine();

  /// Encrypts [body] with a fresh content key before any recipient bundle is
  /// known. Returns base64 fields matching the server's `dr-pending` wire
  /// contract (`algorithm=DEFERRED+AES-GCM`).
  Map<String, String> encryptPending({
    required Uint8List body,
    required Uint8List metadata,
  }) {
    final result = engine.encrypt(body: body, metadata: metadata);
    return {
      'content_key_b64': base64Encode(result.contentKey),
      'nonce_b64': base64Encode(result.nonce),
      'ciphertext_b64': base64Encode(result.ciphertext),
      'sha256_b64': base64Encode(result.sha256),
    };
  }

  /// Wraps a previously retained content key for one recipient device.
  /// Called once that device's bundle becomes available (identity SSE, or a
  /// background pending-envelope completion sweep).
  String wrapKeyForRecipient({
    required String contentKeyB64,
    required Map<String, dynamic> recipientBundle,
  }) {
    final envelope = engine.wrapKey(
      contentKey: base64Decode(contentKeyB64),
      recipientBundle: recipientBundle,
    );
    return base64Encode(envelope);
  }

  /// Recipient-side: unwrap the envelope to recover the content key, then
  /// decrypt the message body. Throws (fails closed) on any tamper/mismatch;
  /// callers must not fall back to plaintext.
  Uint8List unwrapAndDecrypt({
    required String envelopeB64,
    required Map<String, dynamic> localIdentity,
    required String ciphertextB64,
    required String nonceB64,
    required String sha256B64,
  }) {
    final contentKey = engine.unwrapKey(
      envelope: base64Decode(envelopeB64),
      localIdentity: localIdentity,
    );
    return engine.decrypt(
      ciphertext: base64Decode(ciphertextB64),
      key: contentKey,
      nonce: base64Decode(nonceB64),
      sha256: base64Decode(sha256B64),
    );
  }
}
