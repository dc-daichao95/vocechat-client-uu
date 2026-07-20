import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2e_v2_identity.dart';

void main() {
  test('uses the exact authenticated login device id', () async {
    final deviceId = await E2eV2Identity.deviceId(
      resolveAuthenticatedDevice: () async => 'Android:install-123',
    );

    expect(deviceId, 'Android:install-123');
  });

  test('rejects an empty authenticated login device id', () async {
    expect(
      () => E2eV2Identity.deviceId(
        resolveAuthenticatedDevice: () async => '',
      ),
      throwsStateError,
    );
  });
}
