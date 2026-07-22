import 'dart:convert';
import 'dart:typed_data';

import 'package:vocechat_client/services/e2e_v2_core.dart';

/// Result of a deferred content encryption (before any recipient key exists).
///
/// Field names match the finalized shared-core Task 3 contract exactly:
/// `deferred_encrypt(body, metadata) -> {content_key, nonce, ciphertext, sha256}`.
/// `sha256` is NOT a plain ciphertext hash — it is the metadata commitment
/// (SHA-256 of canonical metadata JSON) that also doubles as the AEAD AAD.
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
/// primitives, matching the *finalized* Task 3 FFI shapes (see
/// `.superpowers/sdd/reports/task-3-report.md` §5 and §12):
///
///   deferred_encrypt              {body_b64, metadata:<raw JSON>} -> {content_key_b64, nonce_b64, ciphertext_b64, sha256_b64}
///   deferred_decrypt             {ciphertext_b64, content_key_b64, nonce_b64, sha256_b64} -> {body_b64}
///   deferred_wrap_key            {content_key_b64, recipient_bundle} -> {envelope:{alg, x3dh_initial, nonce_b64, wrapped_key_b64}}
///   deferred_unwrap_key          {envelope:<object>, local_identity:{ik_secret_b64, spk_secret_b64, otk_secret_b64?}} -> {content_key_b64}
///   deferred_metadata_commitment {metadata:<raw JSON>} -> {sha256_b64}
///   deferred_verify_metadata     {metadata:<raw JSON>, sha256_b64} -> {matches:bool}
///
/// Note `metadata` crosses the boundary as a raw JSON value (NOT base64); all
/// other byte arrays are base64. Canonicalization of metadata is done inside
/// the crate, so callers re-derive the commitment simply by passing back the
/// metadata they received.
abstract class DeferredCryptoEngine {
  /// AES-256-GCM content encryption. [metadata] is bound as AAD via the
  /// metadata commitment so tampering with either ciphertext or metadata fails
  /// decryption. [metadata] MUST contain a unique per-message id.
  DeferredEncryptResult encrypt({
    required Uint8List body,
    required Map<String, dynamic> metadata,
  });

  /// Recomputes the metadata commitment (SHA-256 of canonical metadata JSON).
  Uint8List metadataCommitment(Map<String, dynamic> metadata);

  /// Verifies that [sha256] is the commitment of [metadata]. Recipients MUST
  /// call this against the metadata they actually received and REJECT on a
  /// `false` result before trusting the decrypted body (a compromised
  /// transport can otherwise rewrite relayed plaintext metadata).
  bool verifyMetadata(Map<String, dynamic> metadata, Uint8List sha256);

  /// Wraps [contentKey] for a specific recipient device using X3DH/DR
  /// primitives already present in the shared core. Returns the structured
  /// envelope object `{alg, x3dh_initial, nonce_b64, wrapped_key_b64}`.
  Map<String, dynamic> wrapKey({
    required Uint8List contentKey,
    required Map<String, dynamic> recipientBundle,
  });

  /// Unwraps a structured [envelope] produced by [wrapKey] using the local
  /// device's identity secrets, recovering the original content key.
  Uint8List unwrapKey({
    required Map<String, dynamic> envelope,
    required Map<String, dynamic> localIdentity,
  });

  /// AES-256-GCM content decryption. Must fail closed (throw) if [sha256]
  /// (the metadata commitment / AAD) does not match or the AEAD tag check
  /// fails.
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
/// This calls `E2eV2Core.instance.call('deferred_*', {...})`, i.e. the same
/// `voce_e2ee_call` JSON-RPC bridge already used by every other FFI method
/// (see [E2eV2Core.call]). The argument/result field names below match the
/// finalized Task 3 contract exactly. If the native `libvoce_e2ee_core`
/// linked into this repo's build does not yet export a method, [E2eV2Core.call]
/// throws a `StateError('E2E v2 error: unknown method ...')` — the binding
/// fails closed and never falls back to plaintext. Task 9 must rebuild the
/// native lib with these six symbols and re-run the round-trip tests.
class NativeDeferredCryptoEngine implements DeferredCryptoEngine {
  final E2eV2Core _core;

  NativeDeferredCryptoEngine({E2eV2Core? core})
      : _core = core ?? E2eV2Core.instance;

  @override
  DeferredEncryptResult encrypt({
    required Uint8List body,
    required Map<String, dynamic> metadata,
  }) {
    final r = _core.call('deferred_encrypt', {
      'body_b64': base64Encode(body),
      // metadata is a raw JSON value per the Task 3 contract (NOT base64).
      'metadata': metadata,
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
  Uint8List metadataCommitment(Map<String, dynamic> metadata) {
    final r = _core.call('deferred_metadata_commitment', {
      'metadata': metadata,
    });
    final result = Map<String, dynamic>.from(r['result'] as Map);
    return base64Decode(result['sha256_b64'] as String);
  }

  @override
  bool verifyMetadata(Map<String, dynamic> metadata, Uint8List sha256) {
    final r = _core.call('deferred_verify_metadata', {
      'metadata': metadata,
      'sha256_b64': base64Encode(sha256),
    });
    final result = Map<String, dynamic>.from(r['result'] as Map);
    return result['matches'] == true;
  }

  @override
  Map<String, dynamic> wrapKey({
    required Uint8List contentKey,
    required Map<String, dynamic> recipientBundle,
  }) {
    final r = _core.call('deferred_wrap_key', {
      'content_key_b64': base64Encode(contentKey),
      'recipient_bundle': recipientBundle,
    });
    final result = Map<String, dynamic>.from(r['result'] as Map);
    return Map<String, dynamic>.from(result['envelope'] as Map);
  }

  @override
  Uint8List unwrapKey({
    required Map<String, dynamic> envelope,
    required Map<String, dynamic> localIdentity,
  }) {
    final r = _core.call('deferred_unwrap_key', {
      'envelope': envelope,
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
      'content_key_b64': base64Encode(key),
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
  /// known. [metadata] MUST carry a unique per-message id and is transmitted
  /// on the wire so the recipient can recompute/verify the commitment.
  /// Returns base64 fields matching the server's `dr-pending` wire contract
  /// (`algorithm=DEFERRED+AES-GCM`).
  Map<String, String> encryptPending({
    required Uint8List body,
    required Map<String, dynamic> metadata,
  }) {
    final result = engine.encrypt(body: body, metadata: metadata);
    return {
      'content_key_b64': base64Encode(result.contentKey),
      'nonce_b64': base64Encode(result.nonce),
      'ciphertext_b64': base64Encode(result.ciphertext),
      'sha256_b64': base64Encode(result.sha256),
    };
  }

  /// Verifies a received metadata JSON against a received commitment digest.
  bool verifyMetadata(Map<String, dynamic> metadata, String sha256B64) =>
      engine.verifyMetadata(metadata, base64Decode(sha256B64));

  /// Wraps a previously retained content key for one recipient device.
  /// Called once that device's bundle becomes available (identity SSE, or a
  /// background pending-envelope completion sweep). Returns the structured
  /// envelope object to be transmitted.
  Map<String, dynamic> wrapKeyForRecipient({
    required String contentKeyB64,
    required Map<String, dynamic> recipientBundle,
  }) {
    return engine.wrapKey(
      contentKey: base64Decode(contentKeyB64),
      recipientBundle: recipientBundle,
    );
  }

  /// Recipient side: MANDATORY verify the metadata commitment against the
  /// metadata actually received, then unwrap the envelope to recover the
  /// content key and decrypt. Throws (fails closed) on commitment mismatch,
  /// tamper, or wrong recipient; callers must not fall back to plaintext.
  Uint8List verifyUnwrapAndDecrypt({
    required Map<String, dynamic> metadata,
    required String sha256B64,
    required Map<String, dynamic> envelope,
    required Map<String, dynamic> localIdentity,
    required String ciphertextB64,
    required String nonceB64,
  }) {
    // 1. Recompute/verify the commitment from the metadata WE received. A
    //    compromised server that rewrote the plaintext metadata is rejected
    //    here, before any body is trusted.
    if (!engine.verifyMetadata(metadata, base64Decode(sha256B64))) {
      throw StateError('deferred metadata commitment mismatch');
    }
    // 2. Unwrap the content key for this device.
    final contentKey =
        engine.unwrapKey(envelope: envelope, localIdentity: localIdentity);
    // 3. Decrypt with the verified commitment as AAD.
    return engine.decrypt(
      ciphertext: base64Decode(ciphertextB64),
      key: contentKey,
      nonce: base64Decode(nonceB64),
      sha256: base64Decode(sha256B64),
    );
  }
}
