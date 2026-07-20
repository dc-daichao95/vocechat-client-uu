import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2e_v2_backup.dart';

void main() {
  const recoveryCode = 'correct-recovery-code-1234567890';

  test('backup roundtrip rejects wrong code and tampering', () async {
    final encrypted = await E2eV2Backup.encryptPayload({
      'version': 2,
      'e2e_state': {'identity:1:device': 'opaque'},
      'mls_state': {'device:1:device': 'opaque-mls'},
      'history': [
        {'mid': 7, 'content': 'locally decrypted'}
      ],
    }, recoveryCode);

    final clear = await E2eV2Backup.decryptPayload(encrypted, recoveryCode);
    expect(clear['version'], 2);
    expect((clear['history'] as List).single['mid'], 7);

    await expectLater(
      E2eV2Backup.decryptPayload(encrypted, 'wrong-recovery-code-1234567890'),
      throwsA(anything),
    );

    final tampered = Uint8List.fromList(encrypted);
    tampered[tampered.length - 8] ^= 1;
    await expectLater(
      E2eV2Backup.decryptPayload(tampered, recoveryCode),
      throwsA(anything),
    );
  }, timeout: const Timeout(Duration(seconds: 90)));
}
