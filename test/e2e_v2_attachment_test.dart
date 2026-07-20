import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2e_v2_attachment.dart';

void main() {
  test('attachment encryption round-trips and rejects tampering', () async {
    final plaintext =
        Uint8List.fromList(List<int>.generate(513, (i) => i & 0xff));
    final encrypted = await E2eV2Attachment.encryptBytes(plaintext);

    expect(await E2eV2Attachment.decryptBytes(encrypted), plaintext);

    final tampered = encrypted.copyWith(
      ciphertext: Uint8List.fromList(encrypted.ciphertext)..[0] ^= 1,
    );
    await expectLater(
      E2eV2Attachment.decryptBytes(tampered),
      throwsA(isA<FormatException>()),
    );
  });
}
