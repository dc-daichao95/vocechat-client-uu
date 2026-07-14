import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2e_crypto.dart';

void main() {
  test('decryptFileBytes round-trips AES-GCM file blob', () async {
    final mk = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final fiv = Uint8List.fromList(List<int>.generate(12, (i) => i + 3));
    final plain = Uint8List.fromList(utf8.encode('vocechat-e2e-file'));
    final box = await AesGcm.with256bits().encrypt(
      plain,
      secretKey: SecretKey(mk),
      nonce: fiv,
    );
    final cipher =
        Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);

    final out = await E2eCrypto.decryptFileBytes(
      cipherWithTag: cipher,
      mk: mk,
      fiv: fiv,
    );
    expect(utf8.decode(out), 'vocechat-e2e-file');
  });
}
