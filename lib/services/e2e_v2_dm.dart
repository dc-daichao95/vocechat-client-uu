import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vocechat_client/services/e2e_pad.dart';
import 'package:vocechat_client/services/e2e_v2_core.dart';
import 'package:vocechat_client/services/e2e_v2_identity.dart';

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
    required String plaintext,
    String mime = 'text/plain',
  }) async {
    if (!peerSupportsV2(bundle)) return null;
    final deviceId = local['deviceId'] as String;
    final peerDevice = bundle['device_id'] as String;
    if (peerDevice == deviceId) return null;

    final core = local['core'] as E2eV2Core;
    final secret = local['secret'] as Map<String, dynamic>;
    final identity = _parseIdentityPublic(bundle['identity_key_pub'] as String);
    if (identity == null) return null;

    final paddedB64 = E2ePad.padMessageB64(mime, plaintext);
    final skKey = _sessionKey(myUid, deviceId, recipientUid, peerDevice);
    final existing = await _secure.read(key: skKey);

    late Map result;
    if (existing != null) {
      final r = core.call('ratchet_encrypt', {
        'state': jsonDecode(existing),
        'plaintext_b64': paddedB64,
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
        'plaintext_b64': paddedB64,
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
  static Future<({String content, Map<String, dynamic> properties})?>
      encryptText({
    required int uid,
    required int peerUid,
    required String plaintext,
    Map? bundle,
    List<Map>? bundles,
    String mime = 'text/plain',
  }) async {
    final local = await _loadLocal(uid);
    if (local == null) return null;

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
        plaintext: plaintext,
        mime: mime,
      );
      if (copy != null) fanout.add(copy);
    }
    if (!fanout.any((c) => (c['uid'] as num?)?.toInt() == peerUid)) {
      return null;
    }

    final deviceId = local['deviceId'] as String;
    final localId = DateTime.now().millisecondsSinceEpoch;
    await _secure.write(key: _plainKey(deviceId, localId), value: plaintext);

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
      properties: E2ePad.minimalProps(
        e2eVer: 2,
        senderDeviceId: deviceId,
        localId: localId,
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

  static Future<String?> decryptText({
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
      return _secure.read(key: _plainKey(deviceId, localId));
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
        return _decodeDrPlaintext(result);
      }

      if (existing == null) return null;

      final r = core.call('ratchet_decrypt', {
        'state': jsonDecode(existing),
        'header': copy['header'],
        'ciphertext_b64': copy['ciphertext_b64'],
      });
      final result = Map<String, dynamic>.from(r['result'] as Map);
      await _secure.write(key: skKey, value: jsonEncode(result['state']));
      return _decodeDrPlaintext(result);
    } catch (_) {
      return null;
    }
  }

  static String? _decodeDrPlaintext(Map result) {
    final b64 = result['plaintext_b64'] as String?;
    if (b64 != null) return E2ePad.unpadMessageB64(b64).text;
    return result['plaintext'] as String?;
  }

  static bool isV2DrEnvelope(String content) {
    try {
      final env = jsonDecode(utf8.decode(base64Decode(content)));
      return env is Map && env['v'] == 2 && env['alg'] == 'DR+AES-GCM';
    } catch (_) {
      return false;
    }
  }
}
