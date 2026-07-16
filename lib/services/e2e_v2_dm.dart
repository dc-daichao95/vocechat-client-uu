import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vocechat_client/services/e2e_v2_core.dart';
import 'package:vocechat_client/services/e2e_v2_identity.dart';

/// DM Double Ratchet encrypt/decrypt via FFI core.
class E2eV2Dm {
  static final _secure = FlutterSecureStorage(wOptions: WindowsOptions());

  static String _sessionKey(
    int myUid,
    String myDevice,
    int peerUid,
    String peerDevice,
  ) =>
      'e2e_v2_dm:$myUid:$myDevice:$peerUid:$peerDevice';

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
    return spk is String &&
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

  /// Returns wire content + properties, or null to fall back to v1.
  static Future<({String content, Map<String, dynamic> properties})?>
      encryptText({
    required int uid,
    required int peerUid,
    required String plaintext,
    required Map bundle,
  }) async {
    if (!peerSupportsV2(bundle)) return null;
    final local = await _loadLocal(uid);
    if (local == null) return null;

    final core = local['core'] as E2eV2Core;
    final deviceId = local['deviceId'] as String;
    final secret = local['secret'] as Map<String, dynamic>;
    final identity = _parseIdentityPublic(bundle['identity_key_pub'] as String);
    if (identity == null) return null;

    final peerDevice = bundle['device_id'] as String? ?? '';
    if (peerDevice.isEmpty) return null;

    final skKey = _sessionKey(uid, deviceId, peerUid, peerDevice);
    final existing = await _secure.read(key: skKey);

    late Map result;
    if (existing != null) {
      final state = jsonDecode(existing);
      final r = core.call('ratchet_encrypt', {
        'state': state,
        'plaintext': plaintext,
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
        'plaintext': plaintext,
      });
      result = Map<String, dynamic>.from(r['result'] as Map);
    }

    await _secure.write(key: skKey, value: jsonEncode(result['state']));

    final localId = DateTime.now().millisecondsSinceEpoch;
    await _secure.write(key: _plainKey(deviceId, localId), value: plaintext);

    final envelope = <String, dynamic>{
      'v': 2,
      'sender_device_id': deviceId,
      'alg': 'DR+AES-GCM',
      'header': result['header'],
      'ciphertext_b64': result['ciphertext_b64'],
    };
    if (result['x3dh_initial'] != null) {
      envelope['x3dh_initial'] = result['x3dh_initial'];
    }
    if (result['used_signed_prekey_id'] != null) {
      envelope['used_signed_prekey_id'] = result['used_signed_prekey_id'];
    }

    final packed = base64Encode(utf8.encode(jsonEncode(envelope)));
    return (
      content: packed,
      properties: <String, dynamic>{
        'e2e': true,
        'e2e_ver': 2,
        'sender_device_id': deviceId,
        'peer_device_id': peerDevice,
        'local_id': localId,
        'inner_content_type': 'text/plain',
      },
    );
  }

  static Future<String?> decryptText({
    required int uid,
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

    final skKey = _sessionKey(uid, deviceId, peerUid, senderDevice);
    final existing = await _secure.read(key: skKey);

    try {
      if (env['x3dh_initial'] != null && existing == null) {
        final r = core.call('dm_session_open_responder', {
          'bob_x25519_b64': secret['secret_x25519_b64'],
          'bob_spk_secret_b64': spk['secret_b64'],
          'x3dh_initial': env['x3dh_initial'],
          'header': env['header'],
          'ciphertext_b64': env['ciphertext_b64'],
        });
        final result = Map<String, dynamic>.from(r['result'] as Map);
        await _secure.write(key: skKey, value: jsonEncode(result['state']));
        return result['plaintext'] as String?;
      }

      if (existing == null) return null;

      final r = core.call('ratchet_decrypt', {
        'state': jsonDecode(existing),
        'header': env['header'],
        'ciphertext_b64': env['ciphertext_b64'],
      });
      final result = Map<String, dynamic>.from(r['result'] as Map);
      await _secure.write(key: skKey, value: jsonEncode(result['state']));
      return result['plaintext'] as String?;
    } catch (_) {
      return null;
    }
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
