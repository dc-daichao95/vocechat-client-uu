import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vocechat_client/api/lib/e2e_api.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';

class E2eV2Backup {
  static const _iterations = 600000;
  static const _storage = FlutterSecureStorage(wOptions: WindowsOptions());
  static final _random = Random.secure();
  static final _cipher = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  );

  static Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

  static String generateRecoveryCode() =>
      base64UrlEncode(_randomBytes(24)).replaceAll('=', '');

  static Future<Uint8List> encryptPayload(
      Map<String, dynamic> payload, String recoveryCode) async {
    if (recoveryCode.trim().length < 20) {
      throw const FormatException('recovery code is too short');
    }
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _kdf.deriveKeyFromPassword(
      password: recoveryCode.trim(),
      nonce: salt,
    );
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: key,
      nonce: nonce,
    );
    final ciphertext =
        Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'version': 2,
      'kdf': 'PBKDF2-SHA256-600000',
      'cipher': 'AES-256-GCM',
      'salt_b64': base64Encode(salt),
      'nonce_b64': base64Encode(nonce),
      'ciphertext_b64': base64Encode(ciphertext),
    })));
  }

  static Future<Map<String, dynamic>> decryptPayload(
      Uint8List container, String recoveryCode) async {
    final envelope = jsonDecode(utf8.decode(container)) as Map;
    if (envelope['version'] != 2 ||
        envelope['kdf'] != 'PBKDF2-SHA256-600000' ||
        envelope['cipher'] != 'AES-256-GCM') {
      throw const FormatException('unsupported encrypted backup');
    }
    final salt = base64Decode(envelope['salt_b64'] as String);
    final nonce = base64Decode(envelope['nonce_b64'] as String);
    final combined = base64Decode(envelope['ciphertext_b64'] as String);
    if (combined.length < 16) throw const FormatException('invalid backup');
    final split = combined.length - 16;
    final key = await _kdf.deriveKeyFromPassword(
      password: recoveryCode.trim(),
      nonce: salt,
    );
    final clear = await _cipher.decrypt(
      SecretBox(
        combined.sublist(0, split),
        nonce: nonce,
        mac: Mac(combined.sublist(split)),
      ),
      secretKey: key,
    );
    final payload =
        Map<String, dynamic>.from(jsonDecode(utf8.decode(clear)) as Map);
    if (payload['version'] != 2 ||
        payload['e2e_state'] is! Map ||
        payload['mls_state'] is! Map) {
      throw const FormatException('invalid backup payload');
    }
    return payload;
  }

  static Future<({String recoveryCode, Uint8List encrypted})> create({
    List<Map<String, dynamic>> history = const [],
  }) async {
    final all = await _storage.readAll();
    final e2eState = <String, String>{};
    final mlsState = <String, String>{};
    for (final entry in all.entries) {
      if (entry.key.startsWith('e2e_v2_secret:')) {
        e2eState[entry.key.replaceFirst('e2e_v2_secret:', 'identity:')] =
            entry.value;
      } else if (entry.key.startsWith('e2e_v2_spk:')) {
        e2eState[entry.key.replaceFirst('e2e_v2_spk:', 'spk:')] = entry.value;
      } else if (entry.key.startsWith('e2e_v2_dm:')) {
        e2eState[entry.key.replaceFirst('e2e_v2_dm:', 'dm:')] = entry.value;
      } else if (entry.key.startsWith('e2e_v2_plain:')) {
        e2eState[entry.key.replaceFirst('e2e_v2_plain:', 'dm_plain:')] =
            entry.value;
      } else if (entry.key.startsWith('mls:')) {
        mlsState[entry.key.substring(4)] = entry.value;
      }
    }
    final code = generateRecoveryCode();
    final encrypted = await encryptPayload({
      'version': 2,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'e2e_state': e2eState,
      'mls_state': mlsState,
      'history': history,
    }, code);
    return (recoveryCode: code, encrypted: encrypted);
  }

  static Future<Map<String, dynamic>> restore(
      Uint8List encrypted, String recoveryCode) async {
    final payload = await decryptPayload(encrypted, recoveryCode);
    final e2eState = Map<String, dynamic>.from(payload['e2e_state'] as Map);
    for (final entry in e2eState.entries) {
      if (entry.value is! String) continue;
      final key = entry.key
          .replaceFirst(RegExp(r'^identity:'), 'e2e_v2_secret:')
          .replaceFirst(RegExp(r'^spk:'), 'e2e_v2_spk:')
          .replaceFirst(RegExp(r'^dm:'), 'e2e_v2_dm:')
          .replaceFirst(RegExp(r'^dm_plain:'), 'e2e_v2_plain:');
      await _storage.write(key: key, value: entry.value as String);
    }
    final mlsState = Map<String, dynamic>.from(payload['mls_state'] as Map);
    for (final entry in mlsState.entries) {
      if (entry.value is String) {
        await _storage.write(
            key: 'mls:${entry.key}', value: entry.value as String);
      }
    }
    final history = payload['history'];
    if (history is List) {
      final dao = ChatMsgDao();
      for (final row in history) {
        if (row is Map) {
          await dao.addOrUpdate(
            ChatMsgM.fromMap(Map<String, dynamic>.from(row)),
          );
        }
      }
    }
    return payload;
  }

  static Future<String> createAndUpload(E2eApi api) async {
    final rows = await ChatMsgDao().list(orderBy: '${ChatMsgM.F_mid} ASC');
    final backup = await create(
      history: rows
          .map((message) => Map<String, dynamic>.from(message.values))
          .toList(),
    );
    await api.putBackup(base64Encode(backup.encrypted));
    return backup.recoveryCode;
  }

  static Future<void> downloadAndRestore(
      E2eApi api, String recoveryCode) async {
    final response = await api.getBackup();
    final data = response.data as Map;
    await restore(base64Decode(data['blob_base64'] as String), recoveryCode);
  }
}
