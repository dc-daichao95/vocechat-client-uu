import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vocechat_client/api/lib/e2e_api.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/services/e2e_v2_core.dart';

/// Publishes E2EE v2 identity (X25519 + Ed25519 + signed prekey) via Rust core.
class E2eV2Identity {
  static final _secure = FlutterSecureStorage(wOptions: WindowsOptions());

  static Future<String> deviceId({
    Future<String> Function()? resolveAuthenticatedDevice,
  }) async {
    final id =
        await (resolveAuthenticatedDevice ?? SharedFuncs.prepareDeviceInfo)();
    if (id.isEmpty) {
      throw StateError('authenticated device id is empty');
    }
    return id;
  }

  static String _secKey(int uid, String deviceId) =>
      'e2e_v2_secret:$uid:$deviceId';

  /// Ensure v2 identity exists locally and is published to the server.
  static Future<void> bootstrapAndPublish(int uid) async {
    final core = E2eV2Core.instance;
    if (!await core.ensureLoaded()) {
      throw StateError(core.loadError ?? 'E2E v2 core unavailable');
    }

    final did = await deviceId();
    final storeKey = _secKey(uid, did);
    String? raw = await _secure.read(key: storeKey);
    Map<String, dynamic> secret;
    Map<String, dynamic> public;
    if (raw == null) {
      final gen = core.generateIdentity();
      secret = {
        'secret_x25519_b64': gen['secret_x25519_b64'],
        'secret_ed25519_b64': gen['secret_ed25519_b64'],
      };
      public = Map<String, dynamic>.from(gen['public'] as Map);
      await _secure.write(
          key: storeKey,
          value: jsonEncode({
            ...secret,
            'public': public,
          }));
    } else {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      secret = {
        'secret_x25519_b64': map['secret_x25519_b64'],
        'secret_ed25519_b64': map['secret_ed25519_b64'],
      };
      public = Map<String, dynamic>.from(map['public'] as Map);
    }

    Map<String, dynamic> spkPublic;
    String spkSecretB64;
    final existingSpk = await _secure.read(key: 'e2e_v2_spk:$uid:$did');
    if (existingSpk != null) {
      final map = jsonDecode(existingSpk) as Map<String, dynamic>;
      spkSecretB64 = map['secret_b64'] as String;
      spkPublic = Map<String, dynamic>.from(map['public'] as Map);
    } else {
      final spk = core.generateSignedPrekey(
        secretX25519B64: secret['secret_x25519_b64'] as String,
        secretEd25519B64: secret['secret_ed25519_b64'] as String,
        keyId: 1,
      );
      spkPublic = Map<String, dynamic>.from(spk['public'] as Map);
      spkSecretB64 = spk['secret_b64'] as String;
      await _secure.write(
        key: 'e2e_v2_spk:$uid:$did',
        value: jsonEncode({
          'secret_b64': spkSecretB64,
          'public': spkPublic,
        }),
      );
    }

    // Server identity_key_pub: JSON of DH+sig pubs (v2 wire).
    final identityKeyPub = jsonEncode(public);
    final api = E2eApi(App.app.chatServerM.fullUrl);
    await api.putIdentity(
      deviceId: did,
      identityKeyPub: identityKeyPub,
      signedPrekeyPub: spkPublic['dh_pub_b64'] as String?,
      signedPrekeySig: spkPublic['signature_b64'] as String?,
    );

    App.logger.info(
      'E2E v2 identity published uid=$uid device=$did core=${core.version()}',
    );
  }
}
