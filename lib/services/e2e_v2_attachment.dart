import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:vocechat_client/services/e2e_v2_core.dart';

class E2eV2AttachmentDescriptor {
  final String path;
  final Uint8List key;
  final Uint8List nonce;
  final Uint8List sha256;
  final String mime;
  final String name;
  final int size;

  const E2eV2AttachmentDescriptor({
    required this.path,
    required this.key,
    required this.nonce,
    required this.sha256,
    required this.mime,
    required this.name,
    required this.size,
  });
}

class E2eV2EncryptedAttachment {
  final Uint8List key;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List sha256;

  const E2eV2EncryptedAttachment({
    required this.key,
    required this.nonce,
    required this.ciphertext,
    required this.sha256,
  });

  E2eV2EncryptedAttachment copyWith({
    Uint8List? key,
    Uint8List? nonce,
    Uint8List? ciphertext,
    Uint8List? sha256,
  }) =>
      E2eV2EncryptedAttachment(
        key: key ?? this.key,
        nonce: nonce ?? this.nonce,
        ciphertext: ciphertext ?? this.ciphertext,
        sha256: sha256 ?? this.sha256,
      );
}

class E2eV2Attachment {
  static final AesGcm _cipher = AesGcm.with256bits();
  static final Sha256 _hash = Sha256();

  static Future<Uint8List> encodeDescriptor(
      E2eV2AttachmentDescriptor descriptor) async {
    final core = E2eV2Core.instance;
    if (!await core.ensureLoaded()) {
      throw StateError(core.loadError ?? 'E2EE v2 core unavailable');
    }
    final result = core.call('e2ee_attachment_encode', {
      'path': descriptor.path,
      'key_b64': base64Encode(descriptor.key),
      'nonce_b64': base64Encode(descriptor.nonce),
      'sha256_b64': base64Encode(descriptor.sha256),
      'mime': descriptor.mime,
      'name': descriptor.name,
      'size': descriptor.size,
    });
    return base64Decode(result['result']['descriptor_b64'] as String);
  }

  static Future<E2eV2AttachmentDescriptor> decodeDescriptor(
      Uint8List encoded) async {
    final core = E2eV2Core.instance;
    if (!await core.ensureLoaded()) {
      throw StateError(core.loadError ?? 'E2EE v2 core unavailable');
    }
    final result = Map<String, dynamic>.from(
      core.call('e2ee_attachment_decode', {
        'descriptor_b64': base64Encode(encoded),
      })['result'] as Map,
    );
    return E2eV2AttachmentDescriptor(
      path: result['path'] as String,
      key: base64Decode(result['key_b64'] as String),
      nonce: base64Decode(result['nonce_b64'] as String),
      sha256: base64Decode(result['sha256_b64'] as String),
      mime: result['mime'] as String,
      name: result['name'] as String,
      size: (result['size'] as num).toInt(),
    );
  }

  static Future<E2eV2EncryptedAttachment> encryptBytes(
      Uint8List plaintext) async {
    final secretKey = await _cipher.newSecretKey();
    final key = Uint8List.fromList(await secretKey.extractBytes());
    final nonce = Uint8List.fromList(_cipher.newNonce());
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    final ciphertext =
        Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    final digest = Uint8List.fromList((await _hash.hash(ciphertext)).bytes);
    return E2eV2EncryptedAttachment(
      key: key,
      nonce: nonce,
      ciphertext: ciphertext,
      sha256: digest,
    );
  }

  static Future<Uint8List> decryptBytes(
      E2eV2EncryptedAttachment encrypted) async {
    if (encrypted.key.length != 32 ||
        encrypted.nonce.length != 12 ||
        encrypted.sha256.length != 32 ||
        encrypted.ciphertext.length < 16) {
      throw const FormatException('invalid encrypted attachment descriptor');
    }
    final digest = (await _hash.hash(encrypted.ciphertext)).bytes;
    var mismatch = 0;
    for (var i = 0; i < digest.length; i++) {
      mismatch |= digest[i] ^ encrypted.sha256[i];
    }
    if (mismatch != 0) {
      throw const FormatException('encrypted attachment hash mismatch');
    }
    final split = encrypted.ciphertext.length - 16;
    try {
      return Uint8List.fromList(await _cipher.decrypt(
        SecretBox(
          encrypted.ciphertext.sublist(0, split),
          nonce: encrypted.nonce,
          mac: Mac(encrypted.ciphertext.sublist(split)),
        ),
        secretKey: SecretKey(encrypted.key),
      ));
    } on SecretBoxAuthenticationError {
      throw const FormatException('encrypted attachment authentication failed');
    }
  }
}
