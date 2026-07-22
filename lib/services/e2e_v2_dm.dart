import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vocechat_client/services/e2e_v2_core.dart';
import 'package:vocechat_client/services/e2e_v2_deferred.dart';
import 'package:vocechat_client/services/e2e_v2_identity.dart';
import 'package:vocechat_client/services/e2ee_v2_wire.dart';
import 'package:uuid/uuid.dart';

/// DM Double Ratchet encrypt/decrypt via FFI core (multi-device fan-out).
class E2eV2Dm {
  static final _secure = FlutterSecureStorage(wOptions: WindowsOptions());

  static String _sessionKey(
    int myUid,
    String myDevice,
    int remoteUid,
    String remoteDevice,
  ) =>
      'e2e_v2_dm:$myUid:$myDevice:$remoteUid:$remoteDevice';

  static String _plainKey(String deviceId, Object localId) =>
      'e2e_v2_plain:$deviceId:$localId';

  static Map<String, dynamic>? _parseIdentityPublic(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is Map &&
          j['identity_dh_pub_b64'] is String &&
          j['identity_sig_pub_b64'] is String) {
        return Map<String, dynamic>.from(j);
      }
    } catch (_) {}
    return null;
  }

  static bool peerSupportsV2(Map bundle) {
    final spk = bundle['signed_prekey_pub'];
    final sig = bundle['signed_prekey_sig'];
    final id = bundle['identity_key_pub'];
    final did = bundle['device_id'];
    return did is String &&
        did.isNotEmpty &&
        spk is String &&
        spk.isNotEmpty &&
        sig is String &&
        sig.isNotEmpty &&
        id is String &&
        _parseIdentityPublic(id) != null;
  }

  static Future<Map<String, dynamic>?> _loadLocal(int uid) async {
    final core = E2eV2Core.instance;
    if (!await core.ensureLoaded()) return null;
    final did = await E2eV2Identity.deviceId();
    final raw = await _secure.read(key: 'e2e_v2_secret:$uid:$did');
    final spkRaw = await _secure.read(key: 'e2e_v2_spk:$uid:$did');
    if (raw == null || spkRaw == null) return null;
    final secret = jsonDecode(raw) as Map<String, dynamic>;
    final spk = jsonDecode(spkRaw) as Map<String, dynamic>;
    return {
      'deviceId': did,
      'secret': secret,
      'spk': spk,
      'core': core,
    };
  }

  static Future<bool> canUse(int uid) async {
    return (await _loadLocal(uid)) != null;
  }

  static Future<Map<String, dynamic>?> _encryptToDevice({
    required int myUid,
    required Map<String, dynamic> local,
    required int recipientUid,
    required Map bundle,
    required String plaintextB64,
  }) async {
    if (!peerSupportsV2(bundle)) return null;
    final deviceId = local['deviceId'] as String;
    final peerDevice = bundle['device_id'] as String;
    if (peerDevice == deviceId) return null;

    final core = local['core'] as E2eV2Core;
    final secret = local['secret'] as Map<String, dynamic>;
    final identity = _parseIdentityPublic(bundle['identity_key_pub'] as String);
    if (identity == null) return null;

    final skKey = _sessionKey(myUid, deviceId, recipientUid, peerDevice);
    final existing = await _secure.read(key: skKey);

    late Map result;
    if (existing != null) {
      final r = core.call('ratchet_encrypt', {
        'state': jsonDecode(existing),
        'plaintext_b64': plaintextB64,
      });
      result = Map<String, dynamic>.from(r['result'] as Map);
    } else {
      final otk = bundle['one_time_prekey'];
      final r = core.call('dm_session_open_initiator', {
        'alice_x25519_b64': secret['secret_x25519_b64'],
        'alice_public': secret['public'],
        'bundle': {
          'identity': identity,
          'signed_prekey': {
            'key_id': 1,
            'dh_pub_b64': bundle['signed_prekey_pub'],
            'signature_b64': bundle['signed_prekey_sig'],
          },
          'one_time_prekey_b64': otk is Map ? otk['public_key'] : null,
          'one_time_prekey_id': otk is Map ? otk['key_id'] : null,
        },
        'plaintext_b64': plaintextB64,
      });
      result = Map<String, dynamic>.from(r['result'] as Map);
    }

    await _secure.write(key: skKey, value: jsonEncode(result['state']));

    final copy = <String, dynamic>{
      'device_id': peerDevice,
      'uid': recipientUid,
      'header': result['header'],
      'ciphertext_b64': result['ciphertext_b64'],
    };
    if (result['x3dh_initial'] != null) {
      copy['x3dh_initial'] = result['x3dh_initial'];
    }
    if (result['used_signed_prekey_id'] != null) {
      copy['used_signed_prekey_id'] = result['used_signed_prekey_id'];
    }
    return copy;
  }

  /// Encrypt for all [bundles] (peer devices + own other devices).
  static Future<({String content, E2eV2RoutingProperties properties})?>
      encryptText({
    required int uid,
    required int peerUid,
    required String plaintext,
    Map? bundle,
    List<Map>? bundles,
    String mime = 'text/plain',
    String? localId,
    int? kind,
    Uint8List? body,
  }) async {
    final local = await _loadLocal(uid);
    if (local == null) return null;
    final core = local['core'] as E2eV2Core;
    final eventKind = kind ?? (mime == 'text/markdown' ? 8 : 1);
    final eventBody = body ?? Uint8List.fromList(utf8.encode(plaintext));
    final encoded = core.call('mls_application_encode', {
      'kind': eventKind,
      'body_b64': base64Encode(eventBody),
      'metadata': {'1': base64Encode(utf8.encode(mime))},
    });
    final plaintextB64 = encoded['result']['plaintext_b64'] as String;

    final list = <Map>[...(bundles ?? [])];
    if (bundle != null) list.add(bundle);

    final seen = <String>{};
    final unique = <Map>[];
    for (final b in list) {
      final did = b['device_id'] as String?;
      if (did == null || seen.contains(did) || !peerSupportsV2(b)) continue;
      seen.add(did);
      unique.add(b);
    }

    if (!unique.any((b) => (b['uid'] as num?)?.toInt() == peerUid)) {
      return null;
    }

    final fanout = <Map<String, dynamic>>[];
    for (final b in unique) {
      final recipientUid = (b['uid'] as num?)?.toInt() ?? peerUid;
      final copy = await _encryptToDevice(
        myUid: uid,
        local: local,
        recipientUid: recipientUid,
        bundle: b,
        plaintextB64: plaintextB64,
      );
      if (copy != null) fanout.add(copy);
    }
    if (!fanout.any((c) => (c['uid'] as num?)?.toInt() == peerUid)) {
      return null;
    }

    final deviceId = local['deviceId'] as String;
    final messageLocalId = localId ?? const Uuid().v4();
    await _secure.write(
      key: _plainKey(deviceId, messageLocalId),
      value: jsonEncode({
        'kind': eventKind,
        'body_b64': base64Encode(eventBody),
        'metadata': {'1': base64Encode(utf8.encode(mime))},
      }),
    );

    final primary = fanout.firstWhere(
      (c) => (c['uid'] as num?)?.toInt() == peerUid,
      orElse: () => fanout.first,
    );

    final envelope = <String, dynamic>{
      'v': 2,
      'sender_device_id': deviceId,
      'alg': 'DR+AES-GCM',
      'fanout': fanout,
      'header': primary['header'],
      'ciphertext_b64': primary['ciphertext_b64'],
    };
    if (primary['x3dh_initial'] != null) {
      envelope['x3dh_initial'] = primary['x3dh_initial'];
    }
    if (primary['used_signed_prekey_id'] != null) {
      envelope['used_signed_prekey_id'] = primary['used_signed_prekey_id'];
    }

    final packed = base64Encode(utf8.encode(jsonEncode(envelope)));
    return (
      content: packed,
      properties: E2eV2RoutingProperties.dr(
        senderDeviceId: deviceId,
        recipientDeviceId: primary['device_id'] as String,
        localId: messageLocalId,
      ),
    );
  }

  static Map? _pickCopy(Map env, String myDeviceId) {
    final fanout = env['fanout'];
    if (fanout is List && fanout.isNotEmpty) {
      for (final c in fanout) {
        if (c is Map && c['device_id'] == myDeviceId) return c;
      }
      return null;
    }
    if (env['header'] != null && env['ciphertext_b64'] != null) {
      return {
        'device_id': myDeviceId,
        'header': env['header'],
        'ciphertext_b64': env['ciphertext_b64'],
        'x3dh_initial': env['x3dh_initial'],
        'used_signed_prekey_id': env['used_signed_prekey_id'],
      };
    }
    return null;
  }

  static Future<({int kind, Uint8List body, Map<int, Uint8List> metadata})?>
      decryptApplication({
    required int uid,

    /// Message sender uid (from_uid) — remote party for the DR session.
    required int peerUid,
    required String content,
    Object? localId,
  }) async {
    final local = await _loadLocal(uid);
    if (local == null) return null;

    final core = local['core'] as E2eV2Core;
    final deviceId = local['deviceId'] as String;
    final secret = local['secret'] as Map<String, dynamic>;
    final spk = local['spk'] as Map<String, dynamic>;

    Map env;
    try {
      env = jsonDecode(utf8.decode(base64Decode(content))) as Map;
    } catch (_) {
      return null;
    }
    if (env['v'] != 2 || env['alg'] != 'DR+AES-GCM') return null;

    final senderDevice = env['sender_device_id'] as String? ?? '';
    if (senderDevice.isEmpty) return null;

    if (senderDevice == deviceId) {
      if (localId == null) return null;
      final cached = await _secure.read(key: _plainKey(deviceId, localId));
      if (cached == null) return null;
      return _decodeCachedApplication(jsonDecode(cached) as Map);
    }

    final copy = _pickCopy(env, deviceId);
    if (copy == null) return null;

    final skKey = _sessionKey(uid, deviceId, peerUid, senderDevice);
    final existing = await _secure.read(key: skKey);

    try {
      if (copy['x3dh_initial'] != null && existing == null) {
        final r = core.call('dm_session_open_responder', {
          'bob_x25519_b64': secret['secret_x25519_b64'],
          'bob_spk_secret_b64': spk['secret_b64'],
          'x3dh_initial': copy['x3dh_initial'],
          'header': copy['header'],
          'ciphertext_b64': copy['ciphertext_b64'],
        });
        final result = Map<String, dynamic>.from(r['result'] as Map);
        await _secure.write(key: skKey, value: jsonEncode(result['state']));
        return _decodeDrPlaintext(core, result);
      }

      if (existing == null) return null;

      final r = core.call('ratchet_decrypt', {
        'state': jsonDecode(existing),
        'header': copy['header'],
        'ciphertext_b64': copy['ciphertext_b64'],
      });
      final result = Map<String, dynamic>.from(r['result'] as Map);
      await _secure.write(key: skKey, value: jsonEncode(result['state']));
      return _decodeDrPlaintext(core, result);
    } catch (_) {
      return null;
    }
  }

  static ({int kind, Uint8List body, Map<int, Uint8List> metadata})?
      _decodeDrPlaintext(E2eV2Core core, Map result) {
    final b64 = result['plaintext_b64'] as String?;
    if (b64 == null) return null;
    final decoded = core.call('mls_application_decode', {
      'plaintext_b64': b64,
    });
    return _decodeCachedApplication(decoded['result'] as Map);
  }

  static ({int kind, Uint8List body, Map<int, Uint8List> metadata})
      _decodeCachedApplication(Map value) => (
            kind: (value['kind'] as num).toInt(),
            body: base64Decode(value['body_b64'] as String),
            metadata: (value['metadata'] as Map? ?? {}).map(
              (key, encoded) => MapEntry(
                int.parse('$key'),
                base64Decode('$encoded'),
              ),
            ),
          );

  static Future<String?> decryptText({
    required int uid,
    required int peerUid,
    required String content,
    Object? localId,
  }) async {
    final event = await decryptApplication(
      uid: uid,
      peerUid: peerUid,
      content: content,
      localId: localId,
    );
    if (event == null || (event.kind != 1 && event.kind != 8)) return null;
    return utf8.decode(event.body);
  }

  static bool isV2DrEnvelope(String content) {
    try {
      final env = jsonDecode(utf8.decode(base64Decode(content)));
      return env is Map && env['v'] == 2 && env['alg'] == 'DR+AES-GCM';
    } catch (_) {
      return false;
    }
  }

  /// True for a `dr-pending` envelope: sender had no usable recipient bundle
  /// yet and encrypted with a deferred content key (server
  /// `algorithm=DEFERRED+AES-GCM`, wire class `dr_envelope`).
  static bool isDrPendingEnvelope(String content) {
    try {
      final env = jsonDecode(utf8.decode(base64Decode(content)));
      return env is Map && env['v'] == 2 && env['alg'] == 'DEFERRED+AES-GCM';
    } catch (_) {
      return false;
    }
  }

  /// Sender side of the deferred-DM path (server contract: `protocol=
  /// dr-pending`, `algorithm=DEFERRED+AES-GCM`, wire class `dr_envelope`, DM
  /// target only, no `recipient_device_id`).
  ///
  /// Used when the peer currently has no usable E2EE v2 device key at all
  /// (never fetched/rotated) — the message is still end-to-end encrypted
  /// (content key never leaves the device), it just cannot be wrapped for a
  /// specific recipient device until one is published. Returns the wire
  /// content/properties plus the base64 content key the caller's outbox
  /// (see `E2eOutboxDao`) must retain until every recipient device has a
  /// completed envelope.
  static Future<
      ({
        String content,
        E2eV2RoutingProperties properties,
        String contentKeyB64
      })?> encryptTextDeferred({
    required int uid,
    required String plaintext,
    required String localId,
    String mime = 'text/plain',
    int? kind,
    Uint8List? body,
    E2eV2Deferred? deferred,
  }) async {
    final local = await _loadLocal(uid);
    if (local == null) return null;
    final core = local['core'] as E2eV2Core;
    final deviceId = local['deviceId'] as String;
    final eventKind = kind ?? (mime == 'text/markdown' ? 8 : 1);
    final eventBody = body ?? Uint8List.fromList(utf8.encode(plaintext));
    final encoded = core.call('mls_application_encode', {
      'kind': eventKind,
      'body_b64': base64Encode(eventBody),
      'metadata': {'1': base64Encode(utf8.encode(mime))},
    });
    final plaintextBytes =
        base64Decode(encoded['result']['plaintext_b64'] as String);

    final engine = deferred ?? E2eV2Deferred();
    // Metadata is bound as AAD by the deferred_encrypt contract; binding the
    // sender device id here means a wrapped envelope can never be replayed
    // as if it came from a different device.
    final pending = engine.encryptPending(
      body: plaintextBytes,
      metadata: Uint8List.fromList(utf8.encode(deviceId)),
    );

    await _secure.write(
      key: _plainKey(deviceId, localId),
      value: jsonEncode({
        'kind': eventKind,
        'body_b64': base64Encode(eventBody),
        'metadata': {'1': base64Encode(utf8.encode(mime))},
      }),
    );

    final envelope = <String, dynamic>{
      'v': 2,
      'sender_device_id': deviceId,
      'alg': 'DEFERRED+AES-GCM',
      'nonce_b64': pending['nonce_b64'],
      'ciphertext_b64': pending['ciphertext_b64'],
      'sha256_b64': pending['sha256_b64'],
    };
    final packed = base64Encode(utf8.encode(jsonEncode(envelope)));
    return (
      content: packed,
      properties: E2eV2RoutingProperties.drPending(
        senderDeviceId: deviceId,
        localId: localId,
      ),
      contentKeyB64: pending['content_key_b64']!,
    );
  }

  /// Wraps a retained content key for one newly-available recipient device.
  /// The resulting envelope base64 is POSTed by the caller to
  /// `/api/user/e2e/pending/:mid/envelope`.
  static String completeEnvelopeForDevice({
    required String contentKeyB64,
    required Map recipientBundle,
    E2eV2Deferred? deferred,
  }) {
    final engine = deferred ?? E2eV2Deferred();
    return engine.wrapKeyForRecipient(
      contentKeyB64: contentKeyB64,
      recipientBundle: Map<String, dynamic>.from(recipientBundle),
    );
  }

  /// Recipient side: once a completed envelope for *this* device arrives
  /// (via the `e2e_pending_envelope_added` SSE event), unwrap it and decrypt
  /// the `dr-pending` envelope [content] originally received for [mid].
  ///
  /// *** Task 9 integration point (recipient path) ***: the exact shape of
  /// `local_identity` for `deferred_unwrap_key` is defined by shared-core
  /// Task 3; this passes device id + local DH/sig secret material, mirroring
  /// what `dm_session_open_responder` already consumes above. Adjust here if
  /// Task 3 finalizes a different shape.
  static Future<({int kind, Uint8List body, Map<int, Uint8List> metadata})?>
      decryptDrPendingEnvelope({
    required int uid,
    required String content,
    required String wrapEnvelopeB64,
    E2eV2Deferred? deferred,
  }) async {
    final local = await _loadLocal(uid);
    if (local == null) return null;
    final core = local['core'] as E2eV2Core;
    final deviceId = local['deviceId'] as String;
    final secret = local['secret'] as Map<String, dynamic>;

    Map env;
    try {
      env = jsonDecode(utf8.decode(base64Decode(content))) as Map;
    } catch (_) {
      return null;
    }
    if (env['v'] != 2 || env['alg'] != 'DEFERRED+AES-GCM') return null;

    final engine = deferred ?? E2eV2Deferred();
    try {
      final plaintextBytes = engine.unwrapAndDecrypt(
        envelopeB64: wrapEnvelopeB64,
        localIdentity: {'device_id': deviceId, ...secret},
        ciphertextB64: env['ciphertext_b64'] as String,
        nonceB64: env['nonce_b64'] as String,
        sha256B64: env['sha256_b64'] as String,
      );
      final decoded = core.call('mls_application_decode', {
        'plaintext_b64': base64Encode(plaintextBytes),
      });
      return _decodeCachedApplication(decoded['result'] as Map);
    } catch (_) {
      // Fail closed: never fall back to plaintext / a partially-decrypted
      // body on tamper or a mismatched envelope.
      return null;
    }
  }
}
